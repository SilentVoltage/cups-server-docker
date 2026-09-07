#!/usr/bin/env bash
# CUPS container entrypoint.
#   1. seeds /etc/cups from image defaults on first boot (PVC-friendly)
#   2. renders cupsd.conf / cups-files.conf from env
#   3. loads runtime plugins from ${CUPS_PLUGIN_DIR}
#   4. applies declarative printer definitions once cupsd is live
#   5. execs cupsd in the foreground as PID 1's child (tini reaps)
set -Eeuo pipefail
shopt -s nullglob

log() { printf '%s [entrypoint] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

: "${CUPS_HOME:=/etc/cups}"
: "${CUPS_DEFAULTS:=/usr/share/cups/templates-default}"
: "${CUPS_PROVISION_DIR:=${CUPS_HOME}/printers.d}"
: "${CUPS_PLUGIN_DIR:=/plugins.d}"
: "${CUPS_PORT:=631}"
: "${CUPS_SERVER_NAME:=cups}"
: "${CUPS_DEFAULT_SHARED:=yes}"

# Admin authentication. CUPS validates Basic auth against PAM/system users, so a
# password supplied via Secret can never satisfy it - there is no directive that
# points cupsd at a password file. When auth is enforced at the ingress instead
# (Traefik/nginx basic auth), set CUPS_REQUIRE_ADMIN_AUTH=no so cupsd does not
# demand a second, unsatisfiable login on top of it.
: "${CUPS_REQUIRE_ADMIN_AUTH:=yes}"
if [[ "${CUPS_REQUIRE_ADMIN_AUTH}" == "yes" ]]; then
  CUPS_ADMIN_AUTHTYPE="Default"
  CUPS_ADMIN_REQUIRE="Require valid-user"
else
  CUPS_ADMIN_AUTHTYPE="None"
  CUPS_ADMIN_REQUIRE=""
fi
export CUPS_SERVER_NAME CUPS_DEFAULT_SHARED CUPS_ADMIN_AUTHTYPE CUPS_ADMIN_REQUIRE

#-------------------------------------------------------------- seed config
seed_config() {
  mkdir -p "${CUPS_HOME}"
  if [[ ! -f "${CUPS_HOME}/.seeded" ]]; then
    log "seeding ${CUPS_HOME} from ${CUPS_DEFAULTS}"
    cp -an "${CUPS_DEFAULTS}/." "${CUPS_HOME}/" 2>/dev/null || true
    : > "${CUPS_HOME}/.seeded"
  fi
  mkdir -p "${CUPS_HOME}/ppd" "${CUPS_HOME}/ssl" "${CUPS_PROVISION_DIR}"
  chmod 0700 "${CUPS_HOME}/ssl"

  # Subdirectories under the writable volumes. These exist in the image, but an
  # emptyDir/tmpfs mounted at the parent hides them, so they must be recreated
  # on every start - not just on first seed.
  #
  #   /run/cups/certs    cupsd writes its per-session auth cert here (0400).
  #                      Without it cupsd exits 1 during startup, BEFORE it can
  #                      open ErrorLog, so the failure is completely silent -
  #                      nothing in `kubectl logs`, nothing in error_log.
  #   /var/spool/cups/tmp  TempDir from cups-files.conf.
  mkdir -p /run/cups/certs /var/spool/cups/tmp /var/cache/cups /var/log/cups
  chmod 0711 /run/cups/certs 2>/dev/null || true
  chmod 1770 /var/spool/cups/tmp 2>/dev/null || true
}

#-------------------------------------------------------------- render conf
render_config() {
  local tpl out
  for tpl in cupsd.conf cups-files.conf; do
    if [[ -f "${CUPS_DEFAULTS}/${tpl}.template" ]]; then
      out="${CUPS_HOME}/${tpl}"
      # Only env vars we own get substituted; anything else stays literal.
      envsubst "$(printf '${%s} ' \
          CUPS_LOGLEVEL CUPS_PORT CUPS_MAX_JOBS CUPS_MAX_JOB_TIME \
          CUPS_PRESERVE_JOB_HISTORY CUPS_PRESERVE_JOB_FILES CUPS_SERVER_ALIAS \
          CUPS_ALLOW_FROM CUPS_BROWSING CUPS_WEB_INTERFACE CUPS_HOME \
          CUPS_DEFAULT_SHARED CUPS_SERVER_NAME CUPS_ADMIN_AUTHTYPE CUPS_ADMIN_REQUIRE)" \
        < "${CUPS_DEFAULTS}/${tpl}.template" > "${out}.new"
      mv -f "${out}.new" "${out}"
      chmod 0640 "${out}"
      log "rendered ${out}"
    fi
  done
  # Operator escape hatch: drop-in fragments appended verbatim.
  local frag
  for frag in "${CUPS_HOME}/cupsd.conf.d"/*.conf; do
    log "appending drop-in ${frag}"
    printf '\n# --- %s ---\n' "$(basename "$frag")" >> "${CUPS_HOME}/cupsd.conf"
    cat "$frag" >> "${CUPS_HOME}/cupsd.conf"
  done
}

#-------------------------------------------------------------- admin user
# Password comes from a Secret; we only ever write the hashed form CUPS needs
# for its own passwd.md5 file. If unset, admin auth falls back to PAM/none per
# cupsd.conf policy (chart defaults to deny-all on the admin paths).
configure_admin() {
  local pw_file="${CUPS_ADMIN_PASSWORD_FILE:-}"
  local pw="${CUPS_ADMIN_PASSWORD:-}"
  [[ -n "$pw_file" && -r "$pw_file" ]] && pw="$(<"$pw_file")"

  if [[ -z "$pw" ]]; then
    log "no admin password supplied; admin operations will be denied"
    rm -f "${CUPS_HOME}/admin.passwd" 2>/dev/null || true
    return 0
  fi

  # htpasswd-format file consumed by pam_pwdfile (see /etc/pam.d/cups). This is
  # what makes Secret-supplied credentials usable: CUPS authenticates through
  # PAM, and the stock stack reads /etc/shadow, which this container cannot
  # write. openssl's apr1 hash is the format pam_pwdfile expects.
  local hash
  if hash="$(openssl passwd -apr1 "$pw" 2>/dev/null)"; then
    printf '%s:%s\n' "${CUPS_ADMIN_USER}" "$hash" > "${CUPS_HOME}/admin.passwd"
    chmod 0600 "${CUPS_HOME}/admin.passwd"
    log "admin credentials written for user ${CUPS_ADMIN_USER}"
  else
    log "WARN: openssl unavailable, cannot hash admin password - admin auth will fail"
    rm -f "${CUPS_HOME}/admin.passwd" 2>/dev/null || true
  fi
  unset pw
}

#-------------------------------------------------------------- plugins
load_plugins() {
  [[ -d "${CUPS_PLUGIN_DIR}" ]] || return 0
  local p
  for p in "${CUPS_PLUGIN_DIR}"/*.deb; do
    log "extracting plugin $(basename "$p")"
    dpkg-deb -x "$p" / 2>/dev/null || log "WARN: could not extract $p (read-only rootfs?)"
  done
  for p in "${CUPS_PLUGIN_DIR}"/*.ppd "${CUPS_PLUGIN_DIR}"/*.ppd.gz; do
    log "installing PPD $(basename "$p")"
    cp -f "$p" "${CUPS_HOME}/ppd/"
  done
  for p in "${CUPS_PLUGIN_DIR}"/*.sh; do
    log "running plugin hook $(basename "$p")"
    bash "$p" || die "plugin hook $p failed"
  done
}

#-------------------------------------------------------------- provisioning
# Declarative printers. Each file in ${CUPS_PROVISION_DIR} is KEY=VALUE:
#   NAME=office
#   URI=ipp://192.0.2.20/ipp/print
#   PPD=/etc/cups/ppd/office.ppd     (or MODEL=everywhere / MODEL=drv:///...)
#   INFO="Office MFP"
#   LOCATION="2nd floor"
#   SHARED=yes
#   OPTIONS="media=iso_a4_210x297mm sides=two-sided-long-edge"
#   DEFAULT=yes
provision_printers() {
  local f
  for f in "${CUPS_PROVISION_DIR}"/*.conf; do
    ( set -a; NAME=""; URI=""; PPD=""; MODEL=""; INFO=""; LOCATION=""
      SHARED="no"; OPTIONS=""; DEFAULT="no"; ENABLED="yes"
      # shellcheck disable=SC1090
      source "$f"; set +a
      [[ -n "$NAME" && -n "$URI" ]] || { log "skip $f: NAME/URI required"; exit 0; }

      local -a args=(-p "$NAME" -v "$URI" -E)
      [[ -n "$PPD"      ]] && args+=(-P "$PPD")
      [[ -z "$PPD" && -n "$MODEL" ]] && args+=(-m "$MODEL")
      [[ -n "$INFO"     ]] && args+=(-D "$INFO")
      [[ -n "$LOCATION" ]] && args+=(-L "$LOCATION")
      args+=(-o "printer-is-shared=${SHARED}")
      local opt
      for opt in $OPTIONS; do args+=(-o "$opt"); done

      log "provisioning printer ${NAME} -> ${URI}"
      lpadmin "${args[@]}" || { log "WARN: lpadmin failed for ${NAME}"; exit 0; }
      [[ "$ENABLED" == "yes" ]] && { cupsenable "$NAME" || true; cupsaccept "$NAME" || true; }
      [[ "$DEFAULT" == "yes" ]] && { lpadmin -d "$NAME" || true; }
    )
  done
}

wait_for_cupsd() {
  # Deadline-based rather than iteration-based: a slow `lpstat` under load would
  # otherwise stretch a "60 second" wait into several minutes.
  local deadline=$(( SECONDS + ${CUPS_PROVISION_TIMEOUT:-60} ))
  while (( SECONDS < deadline )); do
    lpstat -r >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

#-------------------------------------------------------------- main
main() {
  seed_config
  render_config
  configure_admin
  load_plugins

  if [[ "${1:-cupsd}" != "cupsd" ]]; then
    log "exec custom command: $*"
    exec "$@"
  fi

  if [[ "${CUPS_PROVISION_ENABLED:-yes}" == "yes" ]]; then
    ( if wait_for_cupsd; then provision_printers; log "provisioning complete";
      else log "WARN: cupsd not ready in ${CUPS_PROVISION_TIMEOUT:-60}s, skipping provisioning"; fi ) &
  fi

  log "starting cupsd on :${CUPS_PORT}"
  # cupsd links libsystemd (pulled in transitively via avahi-daemon/dbus in
  # this image) and dual-logs to the journal socket in addition to
  # ErrorLog/stderr. No systemd runs in this container, so that journal write
  # always fails - normally harmless, but it means any log line cupsd only
  # sends that way is silently lost with no trace anywhere. SD_JOURNAL_SUPPRESS
  # isn't a real libsystemd toggle; the actual guard is sd_booted(), which
  # checks for /run/systemd/system. Make sure that path is absent so cupsd
  # never attempts the journal path at all, and everything is guaranteed to
  # land on stderr where `kubectl logs` can actually see it.
  # /run itself is part of the container's root filesystem, not one of our
  # explicit writable mounts - under readOnlyRootFilesystem:true this rm can
  # fail, and with `set -e` that would silently kill the whole script before
  # ever reaching `exec cupsd`. Never let this optional cleanup step be fatal.
  rm -rf /run/systemd 2>/dev/null || true
  exec /usr/sbin/cupsd -f -c "${CUPS_HOME}/cupsd.conf" -s "${CUPS_HOME}/cups-files.conf"
}

main "$@"
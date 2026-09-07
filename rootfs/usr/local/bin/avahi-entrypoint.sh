#!/usr/bin/env bash
# Avahi sidecar: system D-Bus + avahi-daemon in one container.
#
# cups-browsed talks to Avahi over the *system* D-Bus, not over the network.
# Minimal third-party avahi images commonly build with `enable-dbus=no`, in
# which case avahi runs, cups-browsed connects to nothing, and neither process
# logs an error - discovery just silently never happens. Running it here means
# enable-dbus=yes is guaranteed and the socket path matches what the
# cups-browsed container mounts.
#
# Runs as uid 0: dbus-daemon --system and avahi-daemon both start as root and
# drop to messagebus/avahi themselves.
set -Eeuo pipefail

log() { printf '%s [avahi] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

: "${AVAHI_HOST_NAME:=${HOSTNAME:-cups}}"
: "${AVAHI_DOMAIN:=local}"
: "${AVAHI_USE_IPV4:=yes}"
: "${AVAHI_USE_IPV6:=no}"
: "${AVAHI_ALLOW_INTERFACES:=}"
: "${AVAHI_DENY_INTERFACES:=}"
: "${AVAHI_DISABLE_PUBLISHING:=yes}"
: "${AVAHI_ENABLE_REFLECTOR:=no}"
: "${DBUS_SOCKET_DIR:=/run/dbus}"

#------------------------------------------------------------------ config
conf=/tmp/avahi-daemon.conf
if [[ -r /etc/avahi/avahi-daemon.conf.override ]]; then
  log "using mounted avahi-daemon.conf.override"
  cp /etc/avahi/avahi-daemon.conf.override "$conf"
else
  cat > "$conf" <<CONF
[server]
host-name=${AVAHI_HOST_NAME}
domain-name=${AVAHI_DOMAIN}
use-ipv4=${AVAHI_USE_IPV4}
use-ipv6=${AVAHI_USE_IPV6}
$( [[ -n "$AVAHI_ALLOW_INTERFACES" ]] && echo "allow-interfaces=${AVAHI_ALLOW_INTERFACES}" )
$( [[ -n "$AVAHI_DENY_INTERFACES" ]] && echo "deny-interfaces=${AVAHI_DENY_INTERFACES}" )
ratelimit-interval-usec=1000000
ratelimit-burst=1000

[wide-area]
enable-wide-area=no

[publish]
disable-publishing=${AVAHI_DISABLE_PUBLISHING}
publish-hinfo=no
publish-workstation=no
publish-addresses=$( [[ "$AVAHI_DISABLE_PUBLISHING" == "yes" ]] && echo no || echo yes )

[reflector]
enable-reflector=${AVAHI_ENABLE_REFLECTOR}

[rlimits]
rlimit-core=0
rlimit-data=8388608
rlimit-fsize=0
rlimit-nofile=768
rlimit-stack=8388608
rlimit-nproc=3
CONF
fi

#------------------------------------------------------------------ dbus
mkdir -p "${DBUS_SOCKET_DIR}" /run/avahi-daemon
rm -f "${DBUS_SOCKET_DIR}/pid" /run/avahi-daemon/pid

if [[ ! -f /var/lib/dbus/machine-id && ! -f /etc/machine-id ]]; then
  dbus-uuidgen --ensure=/etc/machine-id
fi

# dbus-daemon setuid/setgid's itself to `messagebus` at startup, same as
# avahi-daemon does to `avahi` below. Both need SETUID/SETGID/SETPCAP on this
# container (see the Helm chart's values.yaml) for that internal capset()-based
# demotion to succeed - stock config, stock behavior, nothing patched.
#
# (Earlier attempt: stripping <user> from system.conf so dbus stayed root.
# Abandoned - avahi-daemon then failed a D-Bus ACL that grants ownership of
# org.freedesktop.Avahi to the `avahi` user specifically, checked against the
# connecting peer's *actual* UID at connect() time. That check doesn't care
# about Linux capabilities at all, so no capability grant could fix it -
# the fix is letting both daemons genuinely become their intended users.)
log "starting system dbus-daemon"
dbus-daemon --system --nopidfile --nosyslog --nofork &
DBUS_PID=$!

for _ in $(seq 1 30); do
  [[ -S "${DBUS_SOCKET_DIR}/system_bus_socket" ]] && break
  sleep 0.5
done
if [[ ! -S "${DBUS_SOCKET_DIR}/system_bus_socket" ]]; then
  log "FATAL: system bus socket never appeared at ${DBUS_SOCKET_DIR}"
  exit 1
fi
log "system bus ready at ${DBUS_SOCKET_DIR}/system_bus_socket"

#------------------------------------------------------------------ avahi
# Terminate the whole container if either process dies, so Kubernetes restarts
# it rather than leaving a half-working sidecar.
cleanup() { log "shutting down"; kill "$DBUS_PID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# Unlike dbus above, avahi-daemon MUST actually become the "avahi" user: the
# D-Bus system policy (avahi-dbus.conf) grants ownership of the
# org.freedesktop.Avahi service name specifically to that user, checked by
# the bus against the connecting peer's real UID. Staying root here doesn't
# skip a capability check, it fails a D-Bus ACL that was never told to trust
# root - "no privilege drop" is the wrong strategy for this one process.
# So: let it drop root as designed; SETUID/SETGID/SETPCAP on the container
# (see the Helm chart's values.yaml) are what let that internal capset()-based
# demotion succeed.
log "starting avahi-daemon (dbus enabled, dropping to avahi user)"
avahi-daemon --file="$conf" --no-chroot &
AVAHI_PID=$!

# Report what Avahi can actually see once, as a startup sanity signal.
( sleep 8
  if command -v avahi-browse >/dev/null; then
    n="$(avahi-browse -atp --no-db-lookup 2>/dev/null | grep -c '^+' || true)"
    log "avahi-browse sees ${n:-0} service(s) on the attached interfaces"
    [[ "${n:-0}" == "0" ]] && log "0 services: expected when the pod is not on the printers' L2 segment (hostNetwork/macvlan required)"
  fi ) &

wait -n "$DBUS_PID" "$AVAHI_PID"
log "a supervised process exited; terminating container"
exit 1

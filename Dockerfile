# syntax=docker/dockerfile:1.9
# ---------------------------------------------------------------------------
# CUPS server image
#   * Debian base: only distro with sane coverage of foomatic/gutenprint/HPLIP
#     and the ability to dpkg-install vendor blobs (cnijfilter2, epson-*).
#   * Runs fully unprivileged (uid/gid 1000), read-only-rootfs compatible.
#   * Plugins are additive at BUILD time (reproducible) or RUN time (convenient).
# ---------------------------------------------------------------------------
ARG DEBIAN_RELEASE=bookworm

########################  stage: base runtime  ##############################
FROM debian:${DEBIAN_RELEASE}-slim AS base

ARG DEBIAN_FRONTEND=noninteractive
ARG TARGETARCH

# Core CUPS + the exporter runtime. Keep this list minimal - everything
# driver-shaped belongs in the `drivers` stage so it can be toggled off.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        avahi-daemon \
        avahi-utils \
        libpam-pwdfile \
        openssl \
        cups \
        cups-browsed \
        dbus \
        cups-client \
        cups-filters \
        cups-ipp-utils \
        ghostscript \
        libcups2 \
        poppler-utils \
        python3-cups \
        python3-prometheus-client \
        tini \
        gettext-base \
        procps \
    ; \
    rm -rf /var/lib/apt/lists/*

########################  stage: drivers/plugins  ###########################
# Everything here is opt-in and cache-busted independently from `base`.
FROM base AS drivers

ARG DEBIAN_FRONTEND=noninteractive

# Space-separated apt package list, e.g.:
#   --build-arg CUPS_DRIVER_PACKAGES="printer-driver-gutenprint hplip printer-driver-escpr"
ARG CUPS_DRIVER_PACKAGES="printer-driver-cups-pdf printer-driver-gutenprint foomatic-db-compressed-ppds"

# Newline-separated .deb URLs for vendor blobs (Canon cnijfilter2, Epson, Brother).
# Checksums are enforced via CUPS_DRIVER_DEB_SHA256SUMS ("<sha256>  <basename>" per line).
ARG CUPS_DRIVER_DEB_URLS=""
ARG CUPS_DRIVER_DEB_SHA256SUMS=""

COPY plugins.d/ /tmp/plugins.d/

# pipefail so a failing producer in any pipeline below aborts the layer (DL4006)
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    set -eux; \
    apt-get update; \
    if [ -n "${CUPS_DRIVER_PACKAGES}" ]; then \
        # shellcheck disable=SC2086
        apt-get install -y --no-install-recommends ${CUPS_DRIVER_PACKAGES}; \
    fi; \
    mkdir -p /tmp/debs; \
    if [ -n "${CUPS_DRIVER_DEB_URLS}" ]; then \
        apt-get install -y --no-install-recommends curl; \
        while read -r url; do \
            [ -n "$url" ] || continue; \
            curl -fsSL --retry 3 -o "/tmp/debs/$(basename "$url")" "$url"; \
        done <<< "${CUPS_DRIVER_DEB_URLS}"; \
        if [ -n "${CUPS_DRIVER_DEB_SHA256SUMS}" ]; then \
            # absolute paths in the checksum file avoid a `cd` (DL3003)
            awk 'NF>=2 {printf "%s  /tmp/debs/%s\n", $1, $2}' \
                <<< "${CUPS_DRIVER_DEB_SHA256SUMS}" > /tmp/debs/SHA256SUMS; \
            sha256sum -c /tmp/debs/SHA256SUMS; \
        else \
            echo "REFUSING unverified vendor debs: set CUPS_DRIVER_DEB_SHA256SUMS" >&2; exit 1; \
        fi; \
        apt-get purge -y curl; apt-get autoremove -y; \
    fi; \
    # vendored debs committed to the repo (air-gapped builds)
    find /tmp/plugins.d -name '*.deb' -exec cp -t /tmp/debs {} + 2>/dev/null || true; \
    if ls /tmp/debs/*.deb >/dev/null 2>&1; then \
        apt-get install -y --no-install-recommends /tmp/debs/*.deb; \
    fi; \
    rm -rf /tmp/debs /tmp/plugins.d /var/lib/apt/lists/*

########################  stage: final  #####################################
FROM drivers AS final

ARG CUPS_UID=1000
ARG CUPS_GID=1000

# OCI labels are overwritten by the build workflow; these are sane defaults.
LABEL org.opencontainers.image.title="cups-server" \
      org.opencontainers.image.description="Unprivileged CUPS print server with plugin support and Prometheus metrics" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.source="https://github.com/SilentVoltage/cups-server-docker"

COPY --chmod=0755 rootfs/usr/local/bin/ /usr/local/bin/
COPY --chmod=0644 rootfs/etc/cups/ /usr/share/cups/templates-default/
# PAM stack must land in the real /etc/pam.d, not the CUPS template staging dir.
COPY --chmod=0644 rootfs/etc/pam.d/cups /etc/pam.d/cups
COPY --chmod=0755 rootfs/opt/cups-exporter/ /opt/cups-exporter/

RUN set -eux; \
    groupadd -g "${CUPS_GID}" cupsrun; \
    # -l: skip lastlog/faillog records - those are sparse files indexed by UID and
    # bloat the layer when CUPS_UID is high (DL3046)
    useradd -l -u "${CUPS_UID}" -g "${CUPS_GID}" -G lp,lpadmin -M -s /usr/sbin/nologin -d /var/spool/cups cupsrun; \
    # /etc/cups is the pristine defaults source; the runtime copy lives on a volume
    cp -a /etc/cups/. /usr/share/cups/templates-default/ 2>/dev/null || true; \
    # Directories that must be writable at runtime. Each of these is expected to be
    # backed by a PVC or emptyDir when readOnlyRootFilesystem=true.
    for d in /etc/cups /var/spool/cups /var/cache/cups /var/log/cups /var/run/cups /run/cups /run/avahi-daemon /run/dbus; do \
        mkdir -p "$d"; chown -R "${CUPS_UID}:${CUPS_GID}" "$d"; chmod 0750 "$d"; \
    done; \
    chown -R "${CUPS_UID}:${CUPS_GID}" /usr/share/cups/templates-default /opt/cups-exporter; \
    # strip setuid bits - nothing in this image ever needs them
    find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true

ENV CUPS_HOME=/etc/cups \
    CUPS_DEFAULTS=/usr/share/cups/templates-default \
    CUPS_LOGLEVEL=warn \
    CUPS_PORT=631 \
    CUPS_MAX_JOBS=500 \
    CUPS_MAX_JOB_TIME=10800 \
    CUPS_PRESERVE_JOB_HISTORY=yes \
    CUPS_PRESERVE_JOB_FILES=no \
    CUPS_SERVER_ALIAS="*" \
    CUPS_ADMIN_USER=cupsadmin \
    CUPS_ALLOW_FROM="all" \
    CUPS_BROWSING=off \
    CUPS_WEB_INTERFACE=yes \
    CUPS_PROVISION_DIR=/etc/cups/printers.d \
    CUPS_PLUGIN_DIR=/plugins.d \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

USER ${CUPS_UID}:${CUPS_GID}
WORKDIR /var/spool/cups
EXPOSE 631/tcp

# HEALTHCHECK is a no-op in Kubernetes but useful for compose/local runs.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["cupsd"]
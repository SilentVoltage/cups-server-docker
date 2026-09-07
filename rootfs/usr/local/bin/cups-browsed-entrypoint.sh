#!/usr/bin/env bash
# Sidecar entrypoint: mDNS/DNS-SD driverless discovery.
# Requires a reachable Avahi socket (hostNetwork or an avahi sidecar sharing
# /run/dbus) and a live cupsd at ${CUPS_SERVER}.
set -Eeuo pipefail
: "${CUPS_SERVER:=localhost:631}"
export CUPS_SERVER

# cups-browsed ships in its own Debian binary package (not in `cups` or
# `cups-filters`). Fail with a usable message rather than a bare ENOENT from exec.
BROWSED_BIN="$(command -v cups-browsed || true)"
if [ -z "${BROWSED_BIN}" ]; then
  echo "[cups-browsed] FATAL: cups-browsed not present in this image." >&2
  echo "[cups-browsed] Install the 'cups-browsed' package, or set discovery.enabled=false." >&2
  exit 127
fi

conf=/tmp/cups-browsed.conf
cat > "$conf" <<CONF
BrowseRemoteProtocols ${BROWSE_REMOTE_PROTOCOLS:-dnssd cups}
BrowseLocalProtocols  ${BROWSE_LOCAL_PROTOCOLS:-none}
BrowseInterval        ${BROWSE_INTERVAL:-60}
BrowseTimeout         ${BROWSE_TIMEOUT:-300}
CreateIPPPrinterQueues ${CREATE_IPP_PRINTER_QUEUES:-All}
CreateIPPPrinterQueuesShared ${CREATE_IPP_QUEUES_SHARED:-No}
IPPPrinterQueueType   ${IPP_PRINTER_QUEUE_TYPE:-Auto}
LocalQueueNamingRemoteCUPS ${LOCAL_QUEUE_NAMING:-DNSSD}
AutoShutdown          No
LogLevel              ${BROWSED_LOGLEVEL:-warn}
CONF

for f in ${BROWSE_ALLOW:-}; do echo "BrowseAllow $f" >> "$conf"; done
for f in ${BROWSE_DENY:-}; do  echo "BrowseDeny  $f" >> "$conf"; done
[[ -n "${BROWSE_POLL:-}" ]] && for f in ${BROWSE_POLL}; do echo "BrowsePoll $f" >> "$conf"; done

# cups-browsed queries Avahi over the system D-Bus. Without the socket it starts
# anyway and discovers nothing, silently - so require it before proceeding.
: "${DBUS_SYSTEM_BUS_ADDRESS:=unix:path=/run/dbus/system_bus_socket}"
export DBUS_SYSTEM_BUS_ADDRESS
sock="${DBUS_SYSTEM_BUS_ADDRESS#unix:path=}"

if [[ "${BROWSE_REMOTE_PROTOCOLS:-dnssd}" == *dnssd* ]]; then
  echo "[cups-browsed] waiting for the system D-Bus at ${sock}" >&2
  deadline=$(( SECONDS + ${DBUS_WAIT_TIMEOUT:-60} ))
  while (( SECONDS < deadline )); do
    [[ -S "$sock" ]] && break
    sleep 1
  done
  if [[ ! -S "$sock" ]]; then
    echo "[cups-browsed] FATAL: no D-Bus socket at ${sock}." >&2
    echo "[cups-browsed] The avahi sidecar must share this path (discovery.avahi.enabled)." >&2
    echo "[cups-browsed] For unicast-only discovery set BrowseRemoteProtocols=cups and use BROWSE_POLL." >&2
    exit 1
  fi
  if command -v avahi-browse >/dev/null 2>&1; then
    if avahi-browse -atp --no-db-lookup >/dev/null 2>&1; then
      echo "[cups-browsed] Avahi reachable over D-Bus" >&2
    else
      echo "[cups-browsed] WARN: D-Bus socket present but Avahi did not answer - check enable-dbus in the avahi image" >&2
    fi
  fi
fi

echo "[cups-browsed] waiting for cupsd at ${CUPS_SERVER}" >&2
for _ in $(seq 1 60); do lpstat -r >/dev/null 2>&1 && break; sleep 1; done

exec "${BROWSED_BIN}" -c "$conf" --debug

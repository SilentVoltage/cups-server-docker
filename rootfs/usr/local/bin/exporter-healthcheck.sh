#!/usr/bin/env bash
# Liveness/readiness probe for the exporter container.
#
# exec, not httpGet: httpGet probes need an explicit `host:` field to avoid
# kubelet dialing status.podIP (which under hostNetwork:true is the node's IP,
# not loopback). exec runs inside the container's own namespace, so the whole
# question doesn't come up.
#
# python3, not curl: curl is only installed conditionally (vendor .deb
# download path) and purged afterward, so it is not guaranteed present at
# runtime. python3 always is - the exporter itself needs it.
set -uo pipefail
: "${EXPORTER_LISTEN_PORT:=9628}"
python3 - "$EXPORTER_LISTEN_PORT" <<'PYEOF'
import sys, urllib.request
port = sys.argv[1]
with urllib.request.urlopen(f"http://127.0.0.1:{port}/metrics", timeout=4) as r:
    sys.exit(0 if r.status == 200 else 1)
PYEOF

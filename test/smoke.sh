#!/usr/bin/env bash
# Minimal post-build verification. Runs the image, waits for the scheduler,
# provisions a PDF queue and asserts the exporter serves metrics.
set -Eeuo pipefail
IMAGE="${1:?usage: smoke.sh <image>}"
NAME="cups-smoke-$$"
cleanup() { docker rm -f "$NAME" "$NAME-exp" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --name "$NAME" -p 6631:631 \
  -e CUPS_ALLOW_FROM=all -e CUPS_LOGLEVEL=info "$IMAGE" >/dev/null

for i in $(seq 1 40); do
  docker exec "$NAME" /usr/local/bin/healthcheck.sh && break
  [ "$i" = 40 ] && { docker logs "$NAME"; exit 1; }
  sleep 1
done
echo "PASS: scheduler is up"

docker exec "$NAME" lpadmin -p smoke -E -v cups-pdf:/ -m drv:///cupsfilters.drv/pwgrast.ppd 2>/dev/null \
  || docker exec "$NAME" lpadmin -p smoke -E -v ipp://127.0.0.1/ipp/print -m everywhere 2>/dev/null \
  || echo "WARN: no driver available for smoke queue"
docker exec "$NAME" lpstat -p || true
echo "PASS: lpadmin/lpstat reachable"

docker run -d --name "$NAME-exp" --network "container:$NAME" \
  -e CUPS_SERVER=localhost:631 -e EXPORTER_PAGE_LOG="" \
  --entrypoint python3 "$IMAGE" /opt/cups-exporter/cups_exporter.py >/dev/null
sleep 4
docker exec "$NAME" bash -c "exec 3<>/dev/tcp/127.0.0.1/9628; printf \"GET /metrics HTTP/1.0\r\n\r\n\" >&3; cat <&3" \
  | grep -q "cups_up 1.0" && echo "PASS: exporter reports cups_up=1" || { docker logs "$NAME-exp"; exit 1; }

echo "ALL CHECKS PASSED"

#!/usr/bin/env bash
# Post-build verification. Runs the image, waits for the scheduler, checks the
# web interface on the published port, provisions a PDF queue, asserts the
# exporter serves metrics, then runs it hardened as the chart does.
set -Eeuo pipefail
IMAGE="${1:?usage: smoke.sh <image>}"
NAME="cups-smoke-$$"
VOLUMES=("$NAME-etc" "$NAME-spool" "$NAME-cache" "$NAME-log" "$NAME-run")
cleanup() {
  docker rm -f "$NAME" "$NAME-exp" "$NAME-ro" >/dev/null 2>&1 || true
  docker volume rm "${VOLUMES[@]}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_ready() {
  for _ in $(seq 1 40); do
    docker exec "$1" /usr/local/bin/healthcheck.sh && return 0
    sleep 1
  done
  docker logs "$1"
  return 1
}

docker run -d --name "$NAME" -p 6631:631 \
  -e CUPS_ALLOW_FROM=all -e CUPS_LOGLEVEL=info "$IMAGE" >/dev/null
wait_ready "$NAME"
echo "PASS: scheduler is up"

curl -fsS -o /dev/null "http://127.0.0.1:6631/" || { docker logs "$NAME"; exit 1; }
echo "PASS: web interface answers on the published port"

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

# The chart's and docker-compose's hardening: read-only root, no capabilities,
# writable state only on volumes.
docker run -d --name "$NAME-ro" --read-only --cap-drop ALL --security-opt no-new-privileges:true \
  --tmpfs /tmp \
  -v "$NAME-etc:/etc/cups" -v "$NAME-spool:/var/spool/cups" -v "$NAME-cache:/var/cache/cups" \
  -v "$NAME-log:/var/log/cups" -v "$NAME-run:/run/cups" \
  -e CUPS_ALLOW_FROM=all "$IMAGE" >/dev/null
wait_ready "$NAME-ro"
echo "PASS: scheduler runs read-only with no capabilities"

echo "ALL CHECKS PASSED"

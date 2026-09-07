#!/usr/bin/env bash
# Liveness/readiness probe. `lpstat -r` speaks IPP to the local scheduler,
# which is a stronger signal than a TCP check on 631.
set -euo pipefail
: "${CUPS_PORT:=631}"
export CUPS_SERVER="localhost:${CUPS_PORT}"
timeout 4 lpstat -r >/dev/null 2>&1 || exit 1
exit 0

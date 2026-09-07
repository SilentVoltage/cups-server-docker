# cups-server

Unprivileged [CUPS][cups] 2.4 print server container image. Runs as uid/gid 1000
with a read-only root filesystem, no setuid binaries and no Linux capabilities.
The same image ships three entrypoints — the scheduler, a Prometheus exporter and
a `cups-browsed` discovery sidecar — so one image covers every role in a
deployment.

Published to:

- `ghcr.io/SilentVoltage/cups-server`
- `docker.io/SilentVoltage/cups-server`

Multi-arch (`linux/amd64`, `linux/arm64`), cosign-signed, with an SPDX SBOM and
build provenance attached to every pushed tag.

A companion Helm chart for Kubernetes lives at
[SilentVoltage/cups-server-helm][chart].

## Quick start

```sh
docker run -d --name cups -p 631:631 \
  -e CUPS_ALLOW_FROM=all \
  ghcr.io/SilentVoltage/cups-server:latest
```

Open <http://localhost:631> for the web UI, then add a driverless network
printer:

```sh
docker exec cups lpadmin -p office -E -v ipp://192.0.2.10/ipp/print -m everywhere
docker exec cups lpstat -p office
```

For a full local stack (scheduler + exporter + discovery, host networking) use
the bundled compose file — see [Local development](#local-development).

## Layout

```
Dockerfile                              base -> drivers -> final
rootfs/etc/cups/*.template              cupsd.conf / cups-files.conf, envsubst-rendered
rootfs/usr/local/bin/entrypoint.sh      seed, render, plugins, provision, exec cupsd
rootfs/usr/local/bin/healthcheck.sh     IPP-level probe (lpstat -r)
rootfs/usr/local/bin/cups-browsed-*.sh  DNS-SD discovery sidecar entrypoint
rootfs/usr/local/bin/avahi-entrypoint.sh  system D-Bus + avahi-daemon sidecar
rootfs/opt/cups-exporter/               Prometheus exporter (pycups + prometheus_client)
plugins.d/                              vendored .deb files for air-gapped builds
```

## Roles

| Role | Command |
|---|---|
| scheduler | default entrypoint (`cupsd`) |
| exporter | `python3 /opt/cups-exporter/cups_exporter.py` |
| discovery | `/usr/local/bin/cups-browsed-entrypoint.sh` |
| avahi | `/usr/local/bin/avahi-entrypoint.sh` |

## Drivers / plugins

Three tiers, in descending order of reliability:

1. **Build-time apt** (preferred, reproducible, scannable):
   ```
   docker build --build-arg CUPS_DRIVER_PACKAGES="printer-driver-gutenprint hplip printer-driver-escpr" .
   ```
2. **Build-time vendor blobs** — Canon `cnijfilter2`, Epson, Brother. URLs plus a
   mandatory sha256 list; the build fails if checksums are absent:
   ```
   --build-arg CUPS_DRIVER_DEB_URLS=$'https://.../cnijfilter2_6.20-1_amd64.deb'
   --build-arg CUPS_DRIVER_DEB_SHA256SUMS=$'<sha256>  cnijfilter2_6.20-1_amd64.deb'
   ```
   Or drop the `.deb` into `plugins.d/` for air-gapped builds. Note most vendor
   filters are amd64-only; build those tags single-arch.
3. **Runtime**, via the [companion chart][chart]'s `plugins.enabled=true` init
   container. Convenient for iteration; it needs cluster egress to a Debian
   mirror and re-downloads on every pod start. Do not use it as a permanent
   state.

Prefer driverless IPP Everywhere (`lpadmin -m everywhere`) wherever the printer
supports it — no vendor filter, no PPD, no maintenance.

## Environment

| Var | Default | Notes |
|---|---|---|
| `CUPS_LOGLEVEL` | `warn` | cupsd `LogLevel` |
| `CUPS_ALLOW_FROM` | `all` | `<Location />` allow rule |
| `CUPS_SERVER_ALIAS` | `*` | **required behind an Ingress** — cupsd returns HTTP 400 for unrecognised `Host` headers |
| `CUPS_SERVER_NAME` | `cups` | |
| `CUPS_MAX_JOBS` | `500` | |
| `CUPS_MAX_JOB_TIME` | `10800` | |
| `CUPS_PRESERVE_JOB_HISTORY` | `yes` | |
| `CUPS_PRESERVE_JOB_FILES` | `no` | `yes` keeps document data on the spool volume |
| `CUPS_DEFAULT_SHARED` | `yes` | |
| `CUPS_REQUIRE_ADMIN_AUTH` | `yes` | set `no` when auth is enforced at the ingress instead |
| `CUPS_ADMIN_USER` | `cupsadmin` | user recorded in the generated password file |
| `CUPS_ADMIN_PASSWORD` | – | admin password (prefer `CUPS_ADMIN_PASSWORD_FILE`) |
| `CUPS_ADMIN_PASSWORD_FILE` | – | path to a mounted secret holding the admin password |
| `CUPS_PROVISION_DIR` | `/etc/cups/printers.d` | declarative queues |
| `CUPS_PLUGIN_DIR` | `/plugins.d` | `.deb` / `.ppd` / `.sh` hooks applied at start |

Exporter: `CUPS_SERVER`, `EXPORTER_LISTEN_PORT` (9628), `EXPORTER_PAGE_LOG`,
`EXPORTER_PAGE_LOG_USERS`, `EXPORTER_JOB_LIMIT`. See the module docstring in
[`cups_exporter.py`](rootfs/opt/cups-exporter/cups_exporter.py) for the full list.

## Admin authentication

CUPS validates Basic auth through PAM, and the stock Debian stack reads
`/etc/shadow` — which this container cannot write. The entrypoint instead writes
an htpasswd-format file that `pam_pwdfile` reads (see
[`rootfs/etc/pam.d/cups`](rootfs/etc/pam.d/cups)), populated from
`CUPS_ADMIN_PASSWORD` / `CUPS_ADMIN_PASSWORD_FILE` at startup.

With no password supplied, admin operations are denied. When TLS and auth
terminate at an ingress in front of the pod, set `CUPS_REQUIRE_ADMIN_AUTH=no` so
cupsd does not demand a second, unsatisfiable login.

## Declarative queues

Each file in `${CUPS_PROVISION_DIR}` is sourced and applied with `lpadmin` once
the scheduler is live. Re-applied on every start, so it converges after a
restart or a manual change:

```sh
NAME="office"
URI="ipp://192.0.2.31/ipp/print"
MODEL="everywhere"
INFO="Office MFP"
SHARED="yes"
DEFAULT="yes"
OPTIONS="media=iso_a4_210x297mm sides=two-sided-long-edge"
```

## Writable paths

With `readOnlyRootFilesystem: true` these must be volumes:
`/etc/cups` (PVC), `/var/spool/cups` (PVC), `/var/cache/cups`, `/var/log/cups`,
`/run/cups`, `/tmp`.

## Metrics

`cups_up`, `cups_printer_info`, `cups_printer_state`, `cups_printer_state_info`,
`cups_printer_accepting_jobs`, `cups_printer_shared`, `cups_printer_enabled`,
`cups_jobs{printer,state}`, `cups_job_oldest_age_seconds`,
`cups_queue_size_bytes`, `cups_pages_printed_total`, `cups_jobs_printed_total`,
`cups_scrape_duration_seconds`, `cups_exporter_scrape_errors_total`.

Job-state series are emitted as explicit zeros for every known queue, so alert
expressions do not have to handle disappearing series.

## Kubernetes

Deploy with the companion Helm chart, which wires up the scheduler, exporter and
discovery sidecars, PVCs for the writable paths, the admin-password Secret and
the runtime plugin init container:

<https://github.com/SilentVoltage/cups-server-helm>

## Local development

```
make build           # single-arch
make test            # smoke test: scheduler up, lpadmin works, exporter serves
make lint            # hadolint + shellcheck
docker compose up    # cupsd + exporter + cups-browsed, host networking
```

`docker-compose.yaml` uses host networking for mDNS printer discovery. On macOS
and Windows Docker Desktop that will **not** see LAN printers — use a Linux host
or provision queues explicitly.

## Security notes

- No setuid binaries; `find / -perm /6000` is stripped at build.
- cupsd's `User`/`Group` match the container uid, so no privilege transition
  happens when filters run.
- TLS is expected to terminate at the ingress (`Encryption Never` in-cluster).
  Set `Encryption Required` via a `cupsd.conf.d` drop-in if you need in-pod TLS.
- USB printing requires `/dev/bus/usb` and, on most nodes, elevated privileges.
  Network/IPP printers need none of that — prefer them.

## License

[Apache-2.0](LICENSE). Applies to this repository's own sources: Dockerfile,
entrypoint scripts, config templates and the metrics exporter.

The **built image** is a different matter — it bundles CUPS, cups-filters,
Ghostscript (AGPL-3.0), Gutenprint and foomatic-db under GPL/AGPL terms.
Publishing it makes you a redistributor of those components; the SPDX SBOM
attached to every pushed tag (`syft` / buildx attestation) is the authoritative
component and license inventory.

Vendor driver blobs (Canon `cnijfilter2`, Epson, Brother) are covered by
proprietary EULAs that generally forbid redistribution. Do **not** bake them in
via `CUPS_DRIVER_DEB_URLS` for images you publish — install them at deploy time
through the chart's `plugins.debs` instead, so each operator obtains them under
their own acceptance of the vendor terms.

Not legal advice; get a review before distributing publicly or to customers.

[cups]: https://openprinting.github.io/cups/
[chart]: https://github.com/SilentVoltage/cups-server-helm

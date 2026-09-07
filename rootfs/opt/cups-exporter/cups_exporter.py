#!/usr/bin/env python3
"""
Prometheus exporter for CUPS.

Scrapes the local scheduler over IPP (pycups) on every /metrics request, so
there is no background state to go stale. Optionally tails the CUPS page_log
for cumulative page counters.

Env:
  CUPS_SERVER              host:port or unix socket path (default localhost:631)
  EXPORTER_LISTEN_ADDRESS  default 0.0.0.0
  EXPORTER_LISTEN_PORT     default 9628
  EXPORTER_PAGE_LOG        default /var/log/cups/page_log ("" disables)
  EXPORTER_PAGE_LOG_USERS  "true" adds a per-user label (cardinality risk)
  EXPORTER_TIMEOUT         IPP timeout seconds, default 5
"""

from __future__ import annotations

import logging
import os
import re
import sys
import threading
import time
from http.server import ThreadingHTTPServer

import cups
from prometheus_client import REGISTRY, MetricsHandler
from prometheus_client.core import CounterMetricFamily, GaugeMetricFamily

LOG = logging.getLogger("cups_exporter")

PRINTER_STATES = {3: "idle", 4: "processing", 5: "stopped"}
JOB_STATES = {
    3: "pending",
    4: "held",
    5: "processing",
    6: "stopped",
    7: "canceled",
    8: "aborted",
    9: "completed",
}


def _env_bool(name: str, default: bool = False) -> bool:
    return os.environ.get(name, str(default)).strip().lower() in ("1", "true", "yes", "on")


class PageLogReader:
    """Incremental tail of the CUPS page_log producing per-printer page counters.

    Handles truncation/rotation by resetting the offset when the file shrinks.
    Counters are process-lifetime cumulative, which is exactly what Prometheus
    wants as long as the exporter shares a lifecycle with cupsd (same pod).
    """

    # <printer> <user> <job> <date> <page> <copies> ...
    LINE = re.compile(
        r"^(?P<printer>\S+)\s+(?P<user>\S+)\s+(?P<job>\d+)\s+"
        r"\[[^\]]+\]\s+(?P<page>\S+)\s+(?P<copies>\d+)"
    )

    def __init__(self, path: str, with_users: bool = False) -> None:
        self.path = path
        self.with_users = with_users
        self.offset = 0
        self.inode = None
        self.pages: dict[tuple[str, str], int] = {}
        self.jobs: dict[tuple[str, str], set] = {}
        self.lock = threading.Lock()

    def refresh(self) -> None:
        if not self.path:
            return
        try:
            st = os.stat(self.path)
        except FileNotFoundError:
            return
        with self.lock:
            if self.inode is not None and (st.st_ino != self.inode or st.st_size < self.offset):
                LOG.info("page_log rotated, resetting offset")
                self.offset = 0
            self.inode = st.st_ino
            if st.st_size == self.offset:
                return
            with open(self.path, errors="replace") as fh:
                fh.seek(self.offset)
                for line in fh:
                    self._consume(line)
                self.offset = fh.tell()

    def _consume(self, line: str) -> None:
        m = self.LINE.match(line.strip())
        if not m:
            return
        printer = m.group("printer")
        user = m.group("user") if self.with_users else ""
        page = m.group("page")
        try:
            copies = int(m.group("copies"))
        except ValueError:
            copies = 1
        key = (printer, user)
        if page == "total":
            # cups-pdf and some backends emit a "total" summary line; skip to
            # avoid double counting.
            return
        self.pages[key] = self.pages.get(key, 0) + copies
        self.jobs.setdefault(key, set()).add(m.group("job"))


class CupsCollector:
    def __init__(self, page_log: PageLogReader | None, timeout: float) -> None:
        self.page_log = page_log
        self.timeout = timeout
        self.scrape_errors = 0

    def _connect(self) -> cups.Connection:
        server = os.environ.get("CUPS_SERVER", "localhost:631")
        if "/" in server:
            cups.setServer(server)
        else:
            host, _, port = server.partition(":")
            cups.setServer(host)
            if port:
                cups.setPort(int(port))
        return cups.Connection()

    # Flat metric assembly - intentionally linear rather than factored, so the
    # emitted set is readable top to bottom.
    def collect(self):
        start = time.monotonic()
        up = GaugeMetricFamily("cups_up", "1 if the CUPS scheduler answered this scrape")
        errors = CounterMetricFamily("cups_exporter_scrape_errors_total", "Failed scrapes")
        duration = GaugeMetricFamily("cups_scrape_duration_seconds", "Scrape duration")

        info = GaugeMetricFamily(
            "cups_printer_info",
            "Static printer metadata",
            labels=["printer", "uri", "make_model", "state_message"],
        )
        state = GaugeMetricFamily(
            "cups_printer_state", "Printer state (3=idle 4=processing 5=stopped)", labels=["printer"]
        )
        state_enum = GaugeMetricFamily(
            "cups_printer_state_info", "Printer state as an enum", labels=["printer", "state"]
        )
        accepting = GaugeMetricFamily(
            "cups_printer_accepting_jobs", "1 if the queue accepts jobs", labels=["printer"]
        )
        shared = GaugeMetricFamily("cups_printer_shared", "1 if the queue is shared", labels=["printer"])
        enabled = GaugeMetricFamily("cups_printer_enabled", "1 if the queue is enabled", labels=["printer"])
        jobs_g = GaugeMetricFamily("cups_jobs", "Jobs currently known, by state", labels=["printer", "state"])
        oldest = GaugeMetricFamily(
            "cups_job_oldest_age_seconds", "Age of the oldest pending job", labels=["printer"]
        )
        queue_bytes = GaugeMetricFamily(
            "cups_queue_size_bytes", "Sum of job-k-octets for queued jobs", labels=["printer"]
        )

        try:
            conn = self._connect()
            printers = conn.getPrinters()
            up.add_metric([], 1)

            for name, attrs in printers.items():
                pstate = int(attrs.get("printer-state", 0))
                info.add_metric(
                    [
                        name,
                        str(attrs.get("device-uri", "")),
                        str(attrs.get("printer-make-and-model", "")),
                        str(attrs.get("printer-state-message", ""))[:120],
                    ],
                    1,
                )
                state.add_metric([name], pstate)
                for code, label in PRINTER_STATES.items():
                    state_enum.add_metric([name, label], 1 if code == pstate else 0)
                accepting.add_metric([name], 1 if attrs.get("printer-is-accepting-jobs") else 0)
                shared.add_metric([name], 1 if attrs.get("printer-is-shared") else 0)
                enabled.add_metric([name], 0 if pstate == 5 else 1)

            counts: dict[tuple[str, str], int] = {}
            oldest_seen: dict[str, float] = {}
            sizes: dict[str, int] = {}
            now = time.time()

            for which in ("not-completed", "completed"):
                jobs = conn.getJobs(
                    which_jobs=which,
                    my_jobs=False,
                    limit=int(os.environ.get("EXPORTER_JOB_LIMIT", "1000")),
                    requested_attributes=[
                        "job-id",
                        "job-state",
                        "job-printer-uri",
                        "job-k-octets",
                        "time-at-creation",
                    ],
                )
                for jattrs in jobs.values():
                    uri = str(jattrs.get("job-printer-uri", ""))
                    printer = uri.rstrip("/").rsplit("/", 1)[-1] or "unknown"
                    jstate = JOB_STATES.get(int(jattrs.get("job-state", 0)), "unknown")
                    counts[(printer, jstate)] = counts.get((printer, jstate), 0) + 1
                    if which == "not-completed":
                        created = float(jattrs.get("time-at-creation", now))
                        age = max(0.0, now - created)
                        oldest_seen[printer] = max(oldest_seen.get(printer, 0.0), age)
                        sizes[printer] = sizes.get(printer, 0) + int(jattrs.get("job-k-octets", 0)) * 1024

            # Emit an explicit zero for every printer/state pair so alerting
            # rules do not have to cope with disappearing series.
            for name in printers:
                for label in JOB_STATES.values():
                    jobs_g.add_metric([name, label], counts.get((name, label), 0))
                oldest.add_metric([name], oldest_seen.get(name, 0.0))
                queue_bytes.add_metric([name], sizes.get(name, 0))

        # Broad by design: a scrape failure must degrade to cups_up=0, never take
        # the pod down.
        except Exception as exc:
            LOG.warning("scrape failed: %s", exc)
            self.scrape_errors += 1
            up.add_metric([], 0)

        errors.add_metric([], self.scrape_errors)
        duration.add_metric([], time.monotonic() - start)

        yield from (
            up,
            errors,
            duration,
            info,
            state,
            state_enum,
            accepting,
            shared,
            enabled,
            jobs_g,
            oldest,
            queue_bytes,
        )

        if self.page_log:
            self.page_log.refresh()
            labels = ["printer", "user"] if self.page_log.with_users else ["printer"]
            pages = CounterMetricFamily("cups_pages_printed_total", "Pages printed", labels=labels)
            pjobs = CounterMetricFamily("cups_jobs_printed_total", "Jobs that produced pages", labels=labels)
            with self.page_log.lock:
                for (printer, user), count in self.page_log.pages.items():
                    lv = [printer, user] if self.page_log.with_users else [printer]
                    pages.add_metric(lv, count)
                for (printer, user), jset in self.page_log.jobs.items():
                    lv = [printer, user] if self.page_log.with_users else [printer]
                    pjobs.add_metric(lv, len(jset))
            yield pages
            yield pjobs


def main() -> int:
    logging.basicConfig(
        level=os.environ.get("EXPORTER_LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    page_log_path = os.environ.get("EXPORTER_PAGE_LOG", "/var/log/cups/page_log")
    reader = PageLogReader(page_log_path, _env_bool("EXPORTER_PAGE_LOG_USERS")) if page_log_path else None

    REGISTRY.register(CupsCollector(reader, float(os.environ.get("EXPORTER_TIMEOUT", "5"))))

    addr = os.environ.get("EXPORTER_LISTEN_ADDRESS", "0.0.0.0")
    port = int(os.environ.get("EXPORTER_LISTEN_PORT", "9628"))
    httpd = ThreadingHTTPServer((addr, port), MetricsHandler)
    httpd.daemon_threads = True
    LOG.info("listening on %s:%s (cups=%s)", addr, port, os.environ.get("CUPS_SERVER", "localhost:631"))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        LOG.info("shutting down")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Post-deploy probe for clickhouse-logs.

kix.healthCheck runs this as a Job in the package's namespace once the
agents are ready. kix deploy waits for the Job and keeps the old activation
live when the probe fails.

The agent's own counters answer the question that matters: did ClickHouse
accept rows. Vector counts an event as sent only after the insert was
acknowledged, so the probe needs no database credentials and cannot be
fooled by rows some earlier deploy wrote. The metrics Service is headless,
so one request reaches one agent; any agent that has shipped is proof that
the URL, the user, the grant and the table all line up.

Environment, set by the package from out.* values, and RETRY_FOR by
kix.healthCheck:
  VECTOR_METRICS_URL  an agent's Prometheus endpoint, ".../metrics"
  RETRY_FOR           seconds to keep re-checking before giving up. A new
                      agent has shipped nothing for its first batch window.

Checks, both of which must pass in the same round:
  1. the clickhouse sink has sent at least one event
  2. the clickhouse sink reports no errors

One round must finish inside kix.healthCheck's round budget (90 s): one
request at a 10 s timeout, then the 10 s pause.

Runs with the standard library only. To try it from a laptop, run
`kubectl port-forward ds/<name> 9598`, point VECTOR_METRICS_URL at
http://localhost:9598/metrics and run `python3 health-check.py`.
"""

from __future__ import annotations

import os
import signal
import sys
import time
from dataclasses import dataclass
from urllib.request import urlopen

VECTOR_METRICS_URL = os.environ["VECTOR_METRICS_URL"]
RETRY_FOR = int(os.environ["RETRY_FOR"])
SINK = 'component_id="clickhouse"'


@dataclass
class Check:
    ok: bool
    message: str


def sink_total(exposition: str, metric: str) -> float | None:
    """Sum of a counter's series for the clickhouse sink, None if absent."""
    values = [
        float(line.rsplit(" ", 2)[1] if line.count(" ") > 1 else line.rsplit(" ", 1)[1])
        for line in exposition.splitlines()
        if line.startswith(metric + "{") and SINK in line
    ]
    return sum(values) if values else None


def checks() -> list[Check]:
    try:
        with urlopen(VECTOR_METRICS_URL, timeout=10) as response:
            exposition = response.read().decode()
    except Exception as error:  # noqa: BLE001
        return [Check(False, f"metrics endpoint: {error}")]
    sent = sink_total(exposition, "vector_component_sent_events_total")
    errors = sink_total(exposition, "vector_component_errors_total") or 0.0
    return [
        Check(
            bool(sent),
            f"clickhouse sink has sent {sent:.0f} event(s)"
            if sent is not None
            else "clickhouse sink has sent nothing yet",
        ),
        Check(errors == 0, f"clickhouse sink errors: {errors:.0f}"),
    ]


def on_sigterm(_signum: int, _frame: object) -> None:
    """The Job deadline deletes the pod; say so before the log is gone."""
    print(
        "killed before the retry window ended: a round took longer than the round budget"
    )
    sys.stdout.flush()
    sys.exit(1)


def main() -> int:
    signal.signal(signal.SIGTERM, on_sigterm)
    deadline = time.time() + RETRY_FOR
    while True:
        results = checks()
        for result in results:
            print(("ok    " if result.ok else "FAIL  ") + result.message)
        failed = sum(not result.ok for result in results)
        if failed == 0:
            print("all checks passed")
            return 0
        remaining = int(deadline - time.time())
        if remaining <= 0:
            print(f"{failed} check(s) still failing after {RETRY_FOR}s")
            return 1
        print(f"retrying in 10s ({remaining}s left)")
        sys.stdout.flush()
        time.sleep(10)


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Post-deploy probe for victoria-metrics-agent.

kix.healthCheck runs this as a Job in the package's namespace once the
VMAgent CR is ready. kix deploy waits for the Job and keeps the old
activation live when the probe fails.

Every question is a PromQL query against vmselect. The agent scrapes its
own metrics into the store, so the store already knows whether remote
writes fail and how fresh the agent's data is. The probe therefore needs
one address: the cluster's read path. Every query is scoped to this
agent's own scrape job: another scraper's fresh samples must not vouch
for this one, and another package's dead exporter is an alert, not a
reason to hold this deploy.

Environment, set by the package from out.* values and options, and
RETRY_FOR by kix.healthCheck:
  VMSELECT_URL    read path, ".../select/0/prometheus"
  AGENT_JOB       job label of the agent's own scrape target
  AGENT_REPLICAS  agent pods that must be scraped and up
  MAX_SAMPLE_AGE  seconds; the agent's newest sample older than this fails
  RETRY_FOR       seconds to keep re-checking before giving up. A rollout
                  leaves a target down for a scrape or two, and the first
                  deploy of a stack has no samples yet.

Checks, all of which must pass in the same round:
  1. the agent's newest `up` sample is at most MAX_SAMPLE_AGE seconds old
  2. every agent replica is scraped and reports up
  3. no remote-write errors or dropped packets in the last five minutes

One round must finish inside kix.healthCheck's round budget (90 s): four
requests at a 10 s timeout each, then the 10 s pause.

Runs with the standard library only. To try it from a laptop, run
`kubectl proxy`, point VMSELECT_URL at the proxy's path to the vmselect
Service (".../services/vmselect-<name>:8481/proxy/select/0/prometheus"),
set the other variables and run `python3 health-check.py`.
"""

from __future__ import annotations

import json
import os
import signal
import sys
import time
from collections.abc import Callable
from dataclasses import dataclass
from urllib.parse import urlencode
from urllib.request import urlopen

VMSELECT_URL = os.environ["VMSELECT_URL"]
AGENT_JOB = os.environ["AGENT_JOB"]
AGENT_REPLICAS = int(os.environ["AGENT_REPLICAS"])
MAX_SAMPLE_AGE = int(os.environ["MAX_SAMPLE_AGE"])
RETRY_FOR = int(os.environ["RETRY_FOR"])


@dataclass
class Check:
    ok: bool
    message: str


def query(expr: str) -> list[dict]:
    """The series of an instant query."""
    url = f"{VMSELECT_URL}/api/v1/query?{urlencode({'query': expr})}"
    with urlopen(url, timeout=10) as response:
        return json.load(response)["data"]["result"]


def scalar(expr: str) -> float | None:
    """The value of the first series, or None when the result is empty."""
    rows = query(expr)
    return float(rows[0]["value"][1]) if rows else None


def check_fresh() -> Check:
    newest = scalar(f'max(timestamp(up{{job="{AGENT_JOB}"}}))')
    if newest is None:
        return Check(False, "no samples from this agent in the store")
    age = int(time.time() - newest)
    return Check(
        age <= MAX_SAMPLE_AGE,
        f"newest sample is {age}s old (limit {MAX_SAMPLE_AGE}s)",
    )


def check_agents() -> Check:
    up = int(scalar(f'count(up{{job="{AGENT_JOB}"}} == 1)') or 0)
    return Check(
        up == AGENT_REPLICAS,
        f"{up} of {AGENT_REPLICAS} agent replicas scraped and up",
    )


def increase_5m(metric: str) -> float:
    """How much one of this agent's counters grew in the last five minutes.

    The counter must exist: `or vector(0)` on a renamed metric would read as
    "no errors" forever, so an absent series is an error, not a zero.
    """
    selector = f'{{job="{AGENT_JOB}"}}'
    # One request: the increase when the counter has enough history, zero
    # when it exists but is new, empty (so None) when it is not there.
    value = scalar(
        f"sum(increase({metric}{selector}[5m])) or (count({metric}{selector}) * 0)"
    )
    if value is None:
        raise RuntimeError(f"{metric}{selector} is not in the store")
    return value


def check_remote_write() -> Check:
    errors = increase_5m("vmagent_remotewrite_errors_total")
    dropped = increase_5m("vmagent_remotewrite_packets_dropped_total")
    return Check(
        errors + dropped == 0,
        f"remote-write errors={errors:.0f} dropped packets={dropped:.0f} "
        "in the last 5m",
    )


CHECKS: list[Callable[[], Check]] = [
    check_fresh,
    check_agents,
    check_remote_write,
]


def run(check: Callable[[], Check]) -> Check:
    """A check that raises is a failed check, not a crashed probe."""
    try:
        return check()
    except Exception as error:  # noqa: BLE001
        return Check(False, f"{check.__name__}: {error}")


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
        results = [run(check) for check in CHECKS]
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

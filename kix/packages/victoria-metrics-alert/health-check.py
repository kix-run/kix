#!/usr/bin/env python3
"""Post-deploy probe for victoria-metrics-alert.

kix.healthCheck runs this as a Job in the package's namespace once the
VMAlert CR is ready. kix deploy waits for the Job and keeps the old
activation live when the probe fails.

vmalert and alertmanager are scraped by the cluster's agent, so their own
counters answer every question here through one address: the cluster's
read path.

Environment, set by the package from out.* values and options:
  VMSELECT_URL            read path, ".../select/0/prometheus"
  ALERT_JOB               job label of vmalert's scrape target
  ALERT_REPLICAS          vmalert pods that must be scraped and up
  ALERTMANAGER_JOB        job label of alertmanager's scrape target
  ALERTMANAGER_REPLICAS   alertmanager pods that must be scraped and up
  RETRY_FOR               seconds to keep re-checking before giving up
                          (set by kix.healthCheck)

Checks, all of which must pass in the same round (six requests at a 10 s
timeout each, then the 10 s pause: inside kix.healthCheck's 90 s round
budget):
  1. every vmalert replica is scraped, up, and its last rule reload
     succeeded
  2. every alertmanager replica is scraped and up
  3. in the last five minutes: no failed alert deliveries, no failed
     datasource dials, no remote-write errors

Runs with the standard library only. See the agent package's probe for
how to run it from a laptop through `kubectl proxy`.
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
ALERT_JOB = os.environ["ALERT_JOB"]
ALERT_REPLICAS = int(os.environ["ALERT_REPLICAS"])
ALERTMANAGER_JOB = os.environ["ALERTMANAGER_JOB"]
ALERTMANAGER_REPLICAS = int(os.environ["ALERTMANAGER_REPLICAS"])
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


def count(expr: str) -> int:
    """How many series match, 0 when none do."""
    return int(scalar(f"count({expr})") or 0)


def increase_5m(metric: str) -> float:
    """How much a vmalert counter grew in the last five minutes.

    The counter must exist: `or vector(0)` on a renamed metric would read as
    "no errors" forever, so an absent series is an error, not a zero.
    """
    selector = f'{{job="{ALERT_JOB}"}}'
    # One request: the increase when the counter has enough history, zero
    # when it exists but is new, empty (so None) when it is not there.
    value = scalar(
        f"sum(increase({metric}{selector}[5m])) or (count({metric}{selector}) * 0)"
    )
    if value is None:
        raise RuntimeError(f"{metric}{selector} is not in the store")
    return value


def check_vmalert() -> Check:
    selector = f'{{job="{ALERT_JOB}"}}'
    up = count(f"up{selector} == 1")
    reloaded = count(f"vmalert_config_last_reload_successful{selector} == 1")
    if up == ALERT_REPLICAS and reloaded == ALERT_REPLICAS:
        return Check(
            True, f"{up} of {ALERT_REPLICAS} vmalert replicas up with rules loaded"
        )
    return Check(
        False,
        f"{up} of {ALERT_REPLICAS} vmalert replicas up, {reloaded} with rules loaded",
    )


def check_alertmanager() -> Check:
    up = count(f'up{{job="{ALERTMANAGER_JOB}"}} == 1')
    return Check(
        up == ALERTMANAGER_REPLICAS,
        f"{up} of {ALERTMANAGER_REPLICAS} alertmanager replicas scraped and up",
    )


def check_errors() -> Check:
    send = increase_5m("vmalert_alerts_send_errors_total")
    dial = increase_5m("vmalert_datasource_dial_errors_total")
    write = increase_5m("vmalert_remotewrite_errors_total")
    if send + dial + write == 0:
        return Check(
            True, "no alert-send, datasource or remote-write errors in the last 5m"
        )
    return Check(
        False,
        f"errors in the last 5m: alert-send={send:.0f} datasource-dial={dial:.0f} "
        f"remote-write={write:.0f}",
    )


CHECKS: list[Callable[[], Check]] = [check_vmalert, check_alertmanager, check_errors]


def run(check: Callable[[], Check]) -> Check:
    """A check that raises is a failed check, not a crashed probe."""
    try:
        return check()
    except Exception as error:  # noqa: BLE001
        return Check(False, f"{check.__name__}: {error}")


def on_sigterm(_signum: int, _frame: object) -> None:
    """The Job deadline deletes the pod; say so before the log is gone."""
    print("killed before the retry window ended: a round took longer than the round budget")
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

#!/usr/bin/env python3
"""Post-deploy probe for loki.

kix.healthCheck runs this as a Job in the package's namespace once Loki is
ready. kix deploy waits for the Job and keeps the old activation live when
the probe fails.

The probe only reads. It writes no log line, so it leaves nothing in the
store and needs no tenant or label of its own.

Environment, set by the package from out.* values, and RETRY_FOR by
kix.healthCheck:
  LOKI_URL   base of Loki's HTTP API, "http://<service>:3100"
  RETRY_FOR  seconds to keep re-checking before giving up. Loki answers 503
             on /ready while it replays its write-ahead log.

Checks, both of which must pass in the same round:
  1. GET /ready answers 200 with "ready"
  2. GET /loki/api/v1/labels answers 200 with status "success", which takes
     the query path through the index on the volume

One round must finish inside kix.healthCheck's round budget (90 s): two
requests at a 10 s timeout, then the 10 s pause.

Runs with the standard library only. To try it from a laptop, run
`kubectl port-forward svc/<name> 3100`, point LOKI_URL at
http://localhost:3100 and run `python3 health-check.py`.
"""

from __future__ import annotations

import json
import os
import signal
import sys
import time
from dataclasses import dataclass
from urllib.error import HTTPError
from urllib.request import urlopen

LOKI_URL = os.environ["LOKI_URL"].rstrip("/")
RETRY_FOR = int(os.environ["RETRY_FOR"])


@dataclass
class Check:
    ok: bool
    message: str


def get(path: str) -> tuple[int, str]:
    """Status and body of a GET; an HTTP error status is returned, not raised."""
    try:
        with urlopen(LOKI_URL + path, timeout=10) as response:
            return response.status, response.read().decode()
    except HTTPError as error:
        return error.code, error.read().decode(errors="replace")


def check_ready() -> Check:
    try:
        status, body = get("/ready")
    except Exception as error:  # noqa: BLE001
        return Check(False, f"/ready: {error}")
    text = body.strip()
    return Check(status == 200 and text == "ready", f"/ready: {status} {text[:120]}")


def check_labels() -> Check:
    try:
        status, body = get("/loki/api/v1/labels")
    except Exception as error:  # noqa: BLE001
        return Check(False, f"labels query: {error}")
    if status != 200:
        return Check(False, f"labels query: {status} {body.strip()[:120]}")
    try:
        result = json.loads(body)
    except ValueError:
        return Check(False, f"labels query: not JSON: {body.strip()[:120]}")
    labels = result.get("data") or []
    return Check(
        result.get("status") == "success",
        f"labels query: status {result.get('status')}, {len(labels)} label(s)",
    )


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
        results = [check_ready(), check_labels()]
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

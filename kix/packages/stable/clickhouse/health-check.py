#!/usr/bin/env python3
"""Post-deploy probe for clickhouse.

kix.healthCheck runs this as a Job in the package's namespace once the
server is ready. kix deploy waits for the Job and keeps the old activation
live when the probe fails.

The probe asks the questions a consumer's first query would: can I log in
over the Service, and will replicated DDL work. It only reads. It never
creates a table, because a probe that writes to a database it does not own
has to be trusted to clean up after a failure.

Environment, set by the package from out.* values, and RETRY_FOR by
kix.healthCheck:
  CLICKHOUSE_URL       HTTP interface, "http://<service>:8123"
  CLICKHOUSE_USER      user to log in as
  CLICKHOUSE_PASSWORD  its password, from the credentials Secret
  CLICKHOUSE_CLUSTER   the cluster name consumers get from out.clusterName
  CLICKHOUSE_REPLICAS  replicas the cluster must list; unset means one (the
                       clickhouse-cluster package sets it, this probe is
                       shared by both implementations of the contract)
  CLICKHOUSE_REPLICA_URLS
                       space-separated HTTP interfaces of every replica,
                       each addressed directly and not through the Service
  RETRY_FOR            seconds to keep re-checking before giving up

Checks, all of which must pass in the same round:
  1. a query over the Service with the credentials returns
  2. the same user with no password is refused. A from_env substitution
     that silently does not happen leaves the user with an empty password
     and a server that looks healthy (hide_in_preprocessed does this on
     26.3), so this is checked and not assumed. A server deliberately
     configured with no password fails this check for good; turn the probe
     off for it
  3. the {cluster} macro is CLICKHOUSE_CLUSTER and system.clusters lists it,
     which is what `ON CLUSTER '{cluster}'` resolves against
  4. Keeper's root is readable, which is what ReplicatedMergeTree and the
     distributed DDL queue need
  5. no replica in CLICKHOUSE_REPLICA_URLS has a read-only replicated
     table. A table goes read-only when it loses its Keeper session or
     cannot find its metadata there, and then refuses inserts while reads
     still work

One round must finish inside kix.healthCheck's round budget (90 s): five
requests in turn and then the replicas in parallel, at a 10 s timeout
each, then the 10 s pause.

Runs with the standard library only. To try it from a laptop, run
`kubectl port-forward svc/<name> 8123`, point CLICKHOUSE_URL at
http://localhost:8123, set the other variables and run
`python3 health-check.py`.
"""

from __future__ import annotations

import os
import signal
import sys
import time
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from urllib.error import HTTPError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen

CLICKHOUSE_URL = os.environ["CLICKHOUSE_URL"]
CLICKHOUSE_USER = os.environ["CLICKHOUSE_USER"]
CLICKHOUSE_PASSWORD = os.environ["CLICKHOUSE_PASSWORD"]
CLICKHOUSE_CLUSTER = os.environ["CLICKHOUSE_CLUSTER"]
CLICKHOUSE_REPLICAS = int(os.environ.get("CLICKHOUSE_REPLICAS", "1"))
CLICKHOUSE_REPLICA_URLS = os.environ["CLICKHOUSE_REPLICA_URLS"].split()
RETRY_FOR = int(os.environ["RETRY_FOR"])


@dataclass
class Check:
    ok: bool
    message: str


def query(
    sql: str,
    password: str = CLICKHOUSE_PASSWORD,
    params: dict[str, str] | None = None,
    url: str = CLICKHOUSE_URL,
) -> str:
    """The result in TabSeparated format, with surrounding whitespace stripped.

    A one-row, one-column result is its value. `params` are bound by the
    server ({name:Type} in the SQL), never spliced into the text.
    """
    bound = urlencode({f"param_{key}": value for key, value in (params or {}).items()})
    request = Request(
        f"{url}/?{bound}",
        data=sql.encode(),
        headers={
            "X-ClickHouse-User": CLICKHOUSE_USER,
            "X-ClickHouse-Key": password,
            "X-ClickHouse-Format": "TabSeparated",
        },
    )
    try:
        with urlopen(request, timeout=10) as response:
            return response.read().decode().strip()
    except HTTPError as error:
        # ClickHouse puts the reason in the body, and it is the useful part.
        detail = error.read().decode(errors="replace").strip().splitlines()
        raise RuntimeError(detail[0] if detail else str(error)) from error


def check_login() -> Check:
    version = query("SELECT version()")
    return Check(True, f"logged in as {CLICKHOUSE_USER}, server {version}")


def check_password_required() -> Check:
    try:
        query("SELECT 1", password="")
    except RuntimeError as error:
        # 194 REQUIRED_PASSWORD / wrong password, 516 AUTHENTICATION_FAILED.
        refused = "Code: 194" in str(error) or "Code: 516" in str(error)
        return Check(refused, f"login with no password: {error}"[:160])
    return Check(False, f"{CLICKHOUSE_USER} can log in with NO password")


def check_cluster() -> Check:
    macro = query("SELECT getMacro('cluster')")
    if macro != CLICKHOUSE_CLUSTER:
        return Check(
            False,
            f"{{cluster}} expands to {macro!r}, expected {CLICKHOUSE_CLUSTER!r}",
        )
    replicas = int(
        query(
            "SELECT count() FROM system.clusters WHERE cluster = {cluster:String}",
            params={"cluster": macro},
        )
    )
    return Check(
        replicas >= CLICKHOUSE_REPLICAS,
        f"cluster {macro!r} has {replicas} of {CLICKHOUSE_REPLICAS} replica(s) "
        "in system.clusters",
    )


def check_keeper() -> Check:
    nodes = int(query("SELECT count() FROM system.zookeeper WHERE path = '/'"))
    return Check(True, f"Keeper answers, {nodes} node(s) under /")


def replica_problem(url: str) -> str:
    """What is wrong with the replica at `url`, or "" when nothing is."""
    try:
        tables = query(
            "SELECT arrayStringConcat(groupArray(database || '.' || table), ', ') "
            "FROM system.replicas WHERE is_readonly",
            url=url,
        )
    except Exception as error:  # noqa: BLE001
        return f"not answering: {error}"
    return f"read-only tables {tables}" if tables else ""


def check_readonly_replicas() -> Check:
    with ThreadPoolExecutor(max_workers=len(CLICKHOUSE_REPLICA_URLS)) as pool:
        problems = list(pool.map(replica_problem, CLICKHOUSE_REPLICA_URLS))
    bad = [
        f"{urlsplit(url).hostname}: {problem}"
        for url, problem in zip(CLICKHOUSE_REPLICA_URLS, problems)
        if problem
    ]
    if bad:
        return Check(False, "; ".join(bad)[:400])
    return Check(
        True,
        f"no read-only replicated tables on {len(CLICKHOUSE_REPLICA_URLS)} replica(s)",
    )


CHECKS: list[Callable[[], Check]] = [
    check_login,
    check_password_required,
    check_cluster,
    check_keeper,
    check_readonly_replicas,
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

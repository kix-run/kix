#!/usr/bin/env python3
"""Post-deploy probe for the Vector log agents (clickhouse-logs, loki-logs).

kix.healthCheck runs this as a Job in the package's namespace once the
agents are ready. kix deploy waits for the Job and keeps the old activation
live when the probe fails.

The agents' own counters answer the question that matters: did the backend
accept events. Vector counts an event as sent only after the backend
acknowledged it, so the probe needs no backend credentials. The metrics
Service is headless, so its name resolves to every agent's address.

Environment, set by the package from out.* values, and RETRY_FOR by
kix.healthCheck:
  VECTOR_METRICS_URL  the metrics Service's Prometheus endpoint,
                      "http://<service>:<port>/metrics"
  VECTOR_SINK         component id of the backend sink ("loki", "clickhouse")
  RETRY_FOR           seconds to keep re-checking before giving up

Each round resolves the Service, takes the first MAX_AGENTS addresses in
sorted order, and scrapes them concurrently. The first round is a baseline.
A later round passes when, over the agents sampled in both rounds:
  1. every sampled agent answered,
  2. the sink's sent-events counter rose on at least one agent, and
  3. the sink's error counter rose on none.
Errors from before the probe started therefore do not fail it. On a quiet
cluster where no agent ships anything between two rounds, raise
healthCheck.retryFor.

One round must finish inside kix.healthCheck's round budget (90 s): one DNS
lookup, one batch of requests at a 5 s timeout, then the 10 s pause.

Runs with the standard library only. To try it from a laptop, run
`kubectl port-forward ds/<name> 9598`, point VECTOR_METRICS_URL at
http://localhost:9598/metrics, set VECTOR_SINK and RETRY_FOR, and run
`python3 health-check.py`.
"""

from __future__ import annotations

import ipaddress
import os
import signal
import socket
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from urllib.parse import urlsplit
from urllib.request import urlopen

MAX_AGENTS = 16
TIMEOUT = 5
PAUSE = 10

SENT = "vector_component_sent_events_total"
ERRORS = "vector_component_errors_total"


@dataclass
class Sample:
    """One agent's sink counters, or the error that stopped the scrape."""

    sent: float = 0.0
    errors: float = 0.0
    error: str | None = None


def sink_total(exposition: str, metric: str, sink: str) -> float:
    """Sum of a counter's series for one sink; 0 when it has none yet."""
    label = f'component_id="{sink}"'
    total = 0.0
    for line in exposition.splitlines():
        if line.startswith(metric + "{") and label in line:
            # `name{labels} value [timestamp]`; label values may hold spaces.
            fields = line[line.rindex("}") + 1 :].split()
            total += float(fields[0])
    return total


def agent_urls(url: str) -> list[str]:
    """The metrics URL for each address the Service name resolves to."""
    parts = urlsplit(url)
    port = parts.port or 80
    infos = socket.getaddrinfo(parts.hostname, port, type=socket.SOCK_STREAM)
    addresses = sorted(
        {info[4][0] for info in infos},
        key=lambda a: (ipaddress.ip_address(a).version, ipaddress.ip_address(a)),
    )
    urls = []
    for address in addresses:
        host = f"[{address}]" if ":" in address else address
        urls.append(f"{parts.scheme}://{host}:{port}{parts.path}")
    return urls


def scrape(url: str, sink: str) -> Sample:
    try:
        with urlopen(url, timeout=TIMEOUT) as response:
            exposition = response.read().decode()
    except Exception as error:  # noqa: BLE001
        return Sample(error=str(error))
    return Sample(
        sent=sink_total(exposition, SENT, sink),
        errors=sink_total(exposition, ERRORS, sink),
    )


def increase(previous: float, current: float) -> float:
    """Counter increase; a lower value means the agent restarted."""
    return current - previous if current >= previous else current


def collect(urls: list[str], sink: str) -> dict[str, Sample]:
    with ThreadPoolExecutor(max_workers=MAX_AGENTS) as pool:
        return dict(zip(urls, pool.map(lambda u: scrape(u, sink), urls)))


def judge(
    sink: str, previous: dict[str, Sample], current: dict[str, Sample]
) -> tuple[bool, list[str]]:
    """Apply the pass rule to two consecutive rounds."""
    lines = []
    unreachable = [url for url, s in current.items() if s.error is not None]
    for url in unreachable:
        lines.append(f"FAIL  agent {url}: {current[url].error}")
    both = [
        url
        for url in current
        if url in previous
        and current[url].error is None
        and previous[url].error is None
    ]
    if not both:
        lines.append("FAIL  no agent answered in two consecutive rounds")
        return False, lines
    rose = [u for u in both if increase(previous[u].sent, current[u].sent) > 0]
    erred = {
        u: increase(previous[u].errors, current[u].errors)
        for u in both
        if increase(previous[u].errors, current[u].errors) > 0
    }
    for url, count in erred.items():
        lines.append(f"FAIL  {sink} sink: errors rose by {count:.0f} on agent {url}")
    if rose:
        lines.append(f"ok    {sink} sink: sent rose on {len(rose)} agent(s)")
    else:
        lines.append(
            f"FAIL  {sink} sink: sent did not rise on any of {len(both)} agent(s)"
        )
    if not erred:
        lines.append(f"ok    {sink} sink: errors flat on {len(both)} agent(s)")
    return bool(rose) and not erred and not unreachable, lines


def on_sigterm(_signum: int, _frame: object) -> None:
    """The Job deadline deletes the pod; say so before the log is gone."""
    print(
        "killed before the retry window ended: a round took longer than the round budget"
    )
    sys.stdout.flush()
    sys.exit(1)


def main() -> int:
    url = os.environ["VECTOR_METRICS_URL"]
    sink = os.environ["VECTOR_SINK"]
    retry_for = int(os.environ["RETRY_FOR"])
    signal.signal(signal.SIGTERM, on_sigterm)
    deadline = time.time() + retry_for
    previous: dict[str, Sample] | None = None
    judged = False
    while True:
        try:
            urls = agent_urls(url)
        except OSError as error:
            print(f"FAIL  resolving {url}: {error}")
            urls = []
        sampled = urls[:MAX_AGENTS]
        if len(urls) > MAX_AGENTS:
            print(f"sampling {MAX_AGENTS} of {len(urls)} agents")
        current = collect(sampled, sink) if sampled else {}
        if previous is None:
            reached = sum(s.error is None for s in current.values())
            print(f"baseline: {reached} of {len(current)} agent(s) answered")
        else:
            passed, lines = judge(sink, previous, current)
            for line in lines:
                print(line)
            if passed:
                print("all checks passed")
                return 0
            judged = True
        previous = current
        remaining = int(deadline - time.time())
        # The Job deadline leaves room for one round after the retry window,
        # so a baseline taken late still gets compared once.
        if remaining <= 0 and judged:
            print(f"checks still failing after {retry_for}s")
            return 1
        print(f"next round in {PAUSE}s ({max(remaining, 0)}s left)")
        sys.stdout.flush()
        time.sleep(PAUSE)


if __name__ == "__main__":
    sys.exit(main())

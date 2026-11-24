#!/usr/bin/env python3
"""Post-deploy probe for nats.

kix.healthCheck runs this as a Job in the package's namespace once the
servers are ready. kix deploy waits for the Job and keeps the old
activation live when the probe fails.

The probe does what a client does first, over the client Service and the
NATS protocol: connect, subscribe to a subject, publish to it, and read the
message back. With JetStream on, it also asks the JetStream API for the
account's limits, which a clustered server answers only once its metadata
group has a leader. It never creates a stream, so it leaves nothing behind.

Environment, set by the package from out.* values, and RETRY_FOR by
kix.healthCheck:
  NATS_HOST       the client Service's FQDN
  NATS_PORT       the client port
  NATS_JETSTREAM  "true" when JetStream is on
  NATS_USER       with auth on, the user name from the natsAuth Secret
  NATS_PASSWORD   with auth on, the password from the natsAuth Secret
  RETRY_FOR       seconds to keep re-checking before giving up

Checks, all of which must pass in the same round:
  1. a client with the credentials, if any, connects, and a message it
     publishes comes back on its own subscription
  2. with JetStream on, $JS.API.INFO answers without an error
  3. with auth on, a client without credentials is refused. If the server
     did not read the credentials from its environment, it would accept
     anyone, so this is checked and not assumed

Runs with the standard library only. To try it from a laptop, run
`kubectl port-forward svc/<name> 4222`, set NATS_HOST=localhost and the
other variables, and run `python3 health-check.py`.
"""

from __future__ import annotations

import json
import os
import socket
import sys
import time

TIMEOUT = 10
PAUSE = 10


class Refused(Exception):
    pass


def connect(host: str, port: int, user: str | None, password: str | None):
    sock = socket.create_connection((host, port), timeout=TIMEOUT)
    stream = sock.makefile("rwb")
    info = stream.readline()
    if not info.startswith(b"INFO "):
        raise RuntimeError(f"expected INFO from the server, got {info[:80]!r}")
    options = {
        "verbose": False,
        "pedantic": False,
        "lang": "python",
        "version": "0",
        "protocol": 1,
        "name": "kix-health-check",
    }
    if user is not None:
        options["user"] = user
        options["pass"] = password
    stream.write(b"CONNECT " + json.dumps(options).encode() + b"\r\nPING\r\n")
    stream.flush()
    line = stream.readline()
    if line.startswith(b"-ERR"):
        sock.close()
        raise Refused(line.decode(errors="replace").strip())
    if not line.startswith(b"PONG"):
        sock.close()
        raise RuntimeError(f"expected PONG after CONNECT, got {line[:80]!r}")
    return sock, stream


def read_message(stream) -> bytes:
    """Return the payload of the next MSG, skipping PING, PONG, and INFO."""
    while True:
        line = stream.readline()
        if not line:
            raise RuntimeError("the server closed the connection")
        if line.startswith(b"PING"):
            stream.write(b"PONG\r\n")
            stream.flush()
            continue
        # A server sends INFO again when the cluster changes.
        if line.startswith((b"PONG", b"+OK", b"INFO ")):
            continue
        if line.startswith(b"-ERR"):
            raise RuntimeError(line.decode(errors="replace").strip())
        if line.startswith(b"MSG "):
            size = int(line.split()[-1])
            payload = stream.read(size + 2)[:-2]
            return payload
        raise RuntimeError(f"unexpected line from the server: {line[:80]!r}")


def round_trip(host, port, user, password, jetstream):
    sock, stream = connect(host, port, user, password)
    try:
        subject = f"_KIX_HEALTH.{os.getpid()}.{int(time.time())}"
        stream.write(f"SUB {subject} 1\r\nPUB {subject} 2\r\nok\r\n".encode())
        stream.flush()
        payload = read_message(stream)
        if payload != b"ok":
            raise RuntimeError(f"published 'ok' and read back {payload!r}")
        if jetstream:
            inbox = subject + ".js"
            stream.write(
                f"SUB {inbox} 2\r\nPUB $JS.API.INFO {inbox} 0\r\n\r\n".encode()
            )
            stream.flush()
            reply = json.loads(read_message(stream))
            if "error" in reply:
                raise RuntimeError(
                    f"JetStream answered with an error: {reply['error']}"
                )
    finally:
        sock.close()


def anonymous_refused(host, port):
    try:
        sock, _ = connect(host, port, None, None)
    except Refused:
        return
    sock.close()
    raise RuntimeError(
        "a client without credentials was accepted, so auth is not in force"
    )


def check_once():
    host = os.environ["NATS_HOST"]
    port = int(os.environ["NATS_PORT"])
    user = os.environ.get("NATS_USER")
    password = os.environ.get("NATS_PASSWORD")
    jetstream = os.environ.get("NATS_JETSTREAM") == "true"
    round_trip(host, port, user, password, jetstream)
    if user is not None:
        anonymous_refused(host, port)


def main() -> int:
    deadline = time.monotonic() + int(os.environ.get("RETRY_FOR", "90"))
    while True:
        try:
            check_once()
            print("nats health check passed")
            return 0
        except Exception as error:  # noqa: BLE001
            if time.monotonic() + PAUSE > deadline:
                print(f"nats health check failed: {error}", file=sys.stderr)
                return 1
            print(f"not yet: {error}", file=sys.stderr)
            time.sleep(PAUSE)


if __name__ == "__main__":
    sys.exit(main())

#!/bin/sh
# Container probes. $1 is the mode:
#   liveness   valkey-server answers PONG, or is loading its dataset
#              (LOADING) or is a replica without a primary (MASTERDOWN)
#   readiness  valkey-server answers PONG
#   sentinel   Sentinel answers PONG
set -u

case "$1" in
sentinel)
    reply=$(env -u REDISCLI_AUTH timeout 3 valkey-cli -p "$SENTINEL_PORT" ping 2>&1)
    ;;
*)
    reply=$(timeout 3 valkey-cli -p "$VALKEY_PORT" ping 2>&1)
    ;;
esac

case "$1:$reply" in
*:PONG) exit 0 ;;
liveness:*LOADING* | liveness:*MASTERDOWN*) exit 0 ;;
esac
echo "$reply"
exit 1

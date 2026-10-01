#!/bin/sh
# preStop hooks of the Sentinel topology. $1 is the container:
#   valkey    when this pod is the primary, pause writes and ask Sentinel to
#             fail over, then wait up to 20s for another pod to take over
#   sentinel  wait for the same condition, so the local Sentinel outlives
#             the valkey hook
# Both stay under the pod's 30s termination grace period.
set -u
. /opt/valkey/lib.sh

case "$1" in
valkey)
    role=$(timeout 3 valkey-cli -p "$VALKEY_PORT" ROLE 2>/dev/null | head -n 1)
    [ "$role" = master ] || exit 0
    echo "prestop: this pod is the primary; failing over" >&2
    timeout 3 valkey-cli -p "$VALKEY_PORT" CLIENT PAUSE 22000 WRITE >/dev/null
    reply=$(timeout 5 valkey-cli -p "$SENTINEL_PORT" --user sentinel-admin \
        SENTINEL FAILOVER "$PRIMARY_SET" 2>&1)
    if [ "$reply" != OK ]; then
        echo "prestop: Sentinel did not start a failover: $reply" >&2
        timeout 3 valkey-cli -p "$VALKEY_PORT" CLIENT UNPAUSE >/dev/null
    elif wait_primary_moved 20; then
        echo "prestop: $(local_sentinel_primary) is the primary" >&2
    else
        echo "prestop: no other pod became the primary within 20s" >&2
    fi
    ;;
sentinel)
    [ "$(local_sentinel_primary)" = "$SELF" ] || exit 0
    wait_primary_moved 20 || true
    ;;
esac
exit 0

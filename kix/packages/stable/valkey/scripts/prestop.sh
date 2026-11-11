#!/bin/sh
# preStop hooks of the Sentinel topology. $1 is the container:
#   valkey    when this pod is the primary, pause writes and ask Sentinel to
#             fail over, then wait for another pod to take over
#   sentinel  wait for the same condition, so the local Sentinel outlives
#             the valkey hook
# Both stop waiting 25s after the hook starts. The kubelet stops a hook
# that is still running when the pod's termination grace period ends.
set -u
. /opt/valkey/lib.sh

deadline=$(($(date +%s) + 25))

# The kubelet records a hook's own output only when the hook fails, so the
# messages go to the stderr of the container's main process, which is the
# container log.
log() {
    echo "prestop: $*" 2>/dev/null >/proc/1/fd/2
}

case "$1" in
valkey)
    role=$(timeout 3 valkey-cli -p "$VALKEY_PORT" ROLE 2>/dev/null | head -n 1)
    [ "$role" = master ] || exit 0
    log "this pod is the primary; failing over"
    timeout 3 valkey-cli -p "$VALKEY_PORT" CLIENT PAUSE 22000 WRITE >/dev/null
    reply=$(timeout 5 valkey-cli -p "$SENTINEL_PORT" --user sentinel-admin \
        SENTINEL FAILOVER "$PRIMARY_SET" 2>&1)
    if [ "$reply" != OK ]; then
        log "Sentinel did not start a failover: $reply"
        timeout 3 valkey-cli -p "$VALKEY_PORT" CLIENT UNPAUSE >/dev/null
    elif wait_primary_moved "$deadline"; then
        log "$(local_sentinel_primary) is the primary"
    else
        log "no other pod became the primary in time"
    fi
    ;;
sentinel)
    [ "$(local_sentinel_primary)" = "$SELF" ] || exit 0
    wait_primary_moved "$deadline" || true
    ;;
esac
exit 0

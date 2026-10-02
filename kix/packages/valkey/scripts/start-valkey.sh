#!/bin/sh
# Writes the runtime valkey.conf and starts valkey-server on it. The
# password goes into the file, not argv, because /proc/<pid>/cmdline is
# readable by every process in the container. REDISCLI_AUTH holds it.
set -eu
. /opt/valkey/lib.sh

if [ -z "$REDISCLI_AUTH" ]; then
    echo "valkey: key password of the valkeyPassword secret is empty, and requirepass \"\" would turn authentication off; set a password" >&2
    exit 1
fi
password=$(conf_quote "$REDISCLI_AUTH")
conf=/run/valkey/valkey.conf
umask 077
{
    echo "include /opt/valkey/valkey.conf"
    echo "port $VALKEY_PORT"
    echo "dir /data"
    printf 'requirepass %s\nprimaryauth %s\n' "$password" "$password"
    if [ "$SENTINEL_ENABLED" = yes ]; then
        echo "replica-announce-ip $SELF"
        echo "replica-announce-port $VALKEY_PORT"
        # shellcheck disable=SC2046 # split "host port"
        set -- $(find_primary)
        if [ "$1" = "$SELF" ]; then
            echo "valkey: starting as the primary" >&2
        else
            echo "valkey: starting as a replica of $1:$2" >&2
            echo "replicaof $1 $2"
        fi
    fi
} >"$conf.tmp"
mv "$conf.tmp" "$conf"
exec valkey-server "$conf"

#!/bin/sh
# Writes sentinel.conf into the writable /sentinel volume (Sentinel rewrites
# its own config as state changes) and starts Sentinel on it.
#
# Sentinel's default user may only discover the primary, so a client that
# reaches port 26379 without the password cannot reconfigure it. The
# sentinel-admin user, with the instance password, runs every command; the
# Sentinels use it with each other and the preStop hook uses it to fail
# over.
set -eu
. /opt/valkey/lib.sh

# shellcheck disable=SC2046 # split "host port"
set -- $(find_primary)
primary_host=$1
primary_port=$2
echo "sentinel: monitoring $primary_host:$primary_port" >&2

password=$(conf_quote "$VALKEY_PASSWORD")
password_hash=$(printf '%s' "$VALKEY_PASSWORD" | sha256sum | cut -d ' ' -f 1)
# A restarted pod keeps its Sentinel identity, so its peers do not count it
# twice.
myid=$(printf '%s' "$POD_NAME" | sha1sum | cut -d ' ' -f 1)

conf=/sentinel/sentinel.conf
umask 077
{
    echo "port $SENTINEL_PORT"
    echo "dir /sentinel"
    echo "sentinel resolve-hostnames yes"
    echo "sentinel announce-hostnames yes"
    echo "sentinel announce-ip $SELF"
    echo "sentinel announce-port $SENTINEL_PORT"
    echo "sentinel myid $myid"
    echo "user default on nopass allchannels -@all +ping +auth +hello +client|setname +client|getname +client|setinfo +role +info +subscribe +psubscribe +unsubscribe +punsubscribe +sentinel|get-primary-addr-by-name +sentinel|get-master-addr-by-name +sentinel|sentinels +sentinel|replicas +sentinel|slaves"
    echo "user sentinel-admin on #$password_hash ~* &* +@all"
    echo "sentinel sentinel-user sentinel-admin"
    printf 'sentinel sentinel-pass %s\n' "$password"
    echo "sentinel monitor $PRIMARY_SET $primary_host $primary_port $SENTINEL_QUORUM"
    printf 'sentinel auth-pass %s %s\n' "$PRIMARY_SET" "$password"
    cat /opt/valkey/sentinel.conf
} >"$conf.tmp"
mv "$conf.tmp" "$conf"
exec valkey-sentinel "$conf"

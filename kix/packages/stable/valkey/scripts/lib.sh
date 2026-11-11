# Shared by the start and preStop scripts. Every value comes from the
# container's environment, which the package sets:
#   VALKEY_PORT, SENTINEL_PORT   ports of valkey-server and Sentinel
#   HEADLESS_FQDN                the headless Service (Sentinel only)
#   VALKEY_REPLICAS              StatefulSet replicas (Sentinel only)
#   PRIMARY_SET                  the name Sentinel monitors (Sentinel only)
#   POD_NAME                     this pod's name, <statefulset>-<ordinal>

# Pod ordinal and the stable DNS name of pod N. The headless Service
# publishes unready addresses, so a peer resolves before it is Ready.
ordinal=${POD_NAME##*-}
peer() {
    echo "${POD_NAME%-*}-$1.$HEADLESS_FQDN"
}
SELF=${HEADLESS_FQDN:+$(peer "$ordinal")}

# A config-file string holding $1 byte for byte: double quotes around a
# \xHH escape per byte, which valkey.conf and sentinel.conf decode. Line
# breaks, quotes, and a trailing newline from a Secret written with echo
# stay part of the value, as they do for clients reading the same Secret.
# Write it with printf: dash's echo expands backslash escapes.
conf_quote() {
    printf '"%s"' "$(printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n' | sed 's/../\\x&/g')"
}

# Prints "host port" of the primary as the first Sentinel of another pod
# reports it, or fails when none answers. Sentinel's default user takes no
# password, and an AUTH with one is an error, so the password variable is
# dropped for these calls.
ask_sentinels() {
    i=0
    while [ "$i" -lt "$VALKEY_REPLICAS" ]; do
        if [ "$i" != "$ordinal" ]; then
            answer=$(env -u REDISCLI_AUTH timeout 5 valkey-cli -h "$(peer "$i")" -p "$SENTINEL_PORT" \
                SENTINEL get-primary-addr-by-name "$PRIMARY_SET" 2>/dev/null | tr '\n' ' ')
            # shellcheck disable=SC2086 # split the reply into host and port
            set -- $answer
            if [ "$#" -eq 2 ]; then
                echo "$1 $2"
                return 0
            fi
        fi
        i=$((i + 1))
    done
    return 1
}

# Prints "host port" of the primary. When no other Sentinel answers within
# three tries, this is a first start or a restart after every pod stopped,
# and pod 0 is the primary.
find_primary() {
    for _ in 1 2 3; do
        if ask_sentinels; then
            return 0
        fi
        sleep 2
    done
    echo "$(peer 0) $VALKEY_PORT"
}

# The primary the local Sentinel reports, host only.
local_sentinel_primary() {
    env -u REDISCLI_AUTH timeout 3 valkey-cli -p "$SENTINEL_PORT" \
        SENTINEL get-primary-addr-by-name "$PRIMARY_SET" 2>/dev/null | head -n 1
}

# Waits until the local Sentinel reports a primary other than this pod.
# Gives up once the clock passes $1 (seconds since the epoch); the last
# check can end up to 4s later.
wait_primary_moved() {
    while [ "$(date +%s)" -lt "$1" ]; do
        current=$(local_sentinel_primary)
        if [ -n "$current" ] && [ "$current" != "$SELF" ]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

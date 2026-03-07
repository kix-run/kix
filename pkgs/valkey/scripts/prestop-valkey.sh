#!/bin/bash

. /opt/bitnami/scripts/libvalidations.sh
. /opt/bitnami/scripts/libos.sh

run_valkey_command() {
    if is_boolean_yes "$VALKEY_TLS_ENABLED"; then
        valkey-cli -h 127.0.0.1 -p "$VALKEY_TLS_PORT" --tls --cert "$VALKEY_TLS_CERT_FILE" --key "$VALKEY_TLS_KEY_FILE" --cacert "$VALKEY_TLS_CA_FILE" "$@"
    else
        valkey-cli -h 127.0.0.1 -p "$VALKEY_PORT" "$@"
    fi
}
is_primary() {
    VALKEY_ROLE=$(run_valkey_command role | head -1)
    [[ "$VALKEY_ROLE" == "master" ]]
}

HEADLESS_SERVICE="@HEADLESS_SERVICE_FQDN@"

get_full_hostname() {
    hostname="$1"
    full_hostname="${hostname}.${HEADLESS_SERVICE}"
    echo "${full_hostname}"
}

run_sentinel_command() {
    if is_boolean_yes "$VALKEY_SENTINEL_TLS_ENABLED"; then
        env -u REDISCLI_AUTH valkey-cli -h "$VALKEY_SERVICE" -p "$VALKEY_SENTINEL_TLS_PORT_NUMBER" --tls --cert "$VALKEY_SENTINEL_TLS_CERT_FILE" --key "$VALKEY_SENTINEL_TLS_KEY_FILE" --cacert "$VALKEY_SENTINEL_TLS_CA_FILE" sentinel "$@"
    else
        env -u REDISCLI_AUTH valkey-cli -h "$VALKEY_SERVICE" -p "$VALKEY_SENTINEL_PORT" sentinel "$@"
    fi
}
sentinel_failover_finished() {
    VALKEY_SENTINEL_INFO=($(run_sentinel_command get-primary-addr-by-name "@PRIMARY_SET@"))
    VALKEY_PRIMARY_HOST="${VALKEY_SENTINEL_INFO[0]}"
    [[ "$VALKEY_PRIMARY_HOST" != "$(get_full_hostname $HOSTNAME)" ]]
}

VALKEY_SERVICE="@SENTINEL_SERVICE_FQDN@"

# valkey-cli automatically consumes credentials from the REDISCLI_AUTH variable
[[ -n "$VALKEY_PASSWORD" ]] && export REDISCLI_AUTH="$VALKEY_PASSWORD"
[[ -f "$VALKEY_PASSWORD_FILE" ]] && export REDISCLI_AUTH="$(< "${VALKEY_PASSWORD_FILE}")"


if is_primary && ! sentinel_failover_finished; then
    echo "I am the primary pod and you are stopping me. Pausing client connections."
    # Pausing client write connections to avoid data loss
    run_valkey_command CLIENT PAUSE "22000" WRITE

    echo "Issuing failover"
    # if I am the primary, issue a command to failover once
    run_sentinel_command failover "@PRIMARY_SET@"
    echo "Waiting for sentinel to complete failover for up to 20s"
    retry_while "sentinel_failover_finished" "20" 1
else
    exit 0
fi

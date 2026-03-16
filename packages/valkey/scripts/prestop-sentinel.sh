#!/bin/bash

. /opt/bitnami/scripts/libvalidations.sh
. /opt/bitnami/scripts/libos.sh

HEADLESS_SERVICE="@HEADLESS_SERVICE_FQDN@"

get_full_hostname() {
    hostname="$1"
    full_hostname="${hostname}.${HEADLESS_SERVICE}"
    echo "${full_hostname}"
}

run_sentinel_command() {
    if is_boolean_yes "$VALKEY_SENTINEL_TLS_ENABLED"; then
        valkey-cli -h "$VALKEY_SERVICE" -p "$VALKEY_SENTINEL_TLS_PORT_NUMBER" --tls --cert "$VALKEY_SENTINEL_TLS_CERT_FILE" --key "$VALKEY_SENTINEL_TLS_KEY_FILE" --cacert "$VALKEY_SENTINEL_TLS_CA_FILE" sentinel "$@"
    else
        valkey-cli -h "$VALKEY_SERVICE" -p "$VALKEY_SENTINEL_PORT" sentinel "$@"
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

if ! sentinel_failover_finished; then
    echo "I am the primary pod and you are stopping me. Starting sentinel failover"
    if retry_while "sentinel_failover_finished" "20" 1; then
        echo "Primary has been successfuly failed over to a different pod."
        exit 0
    else
        echo "Primary failover failed"
        exit 1
    fi
else
    exit 0
fi

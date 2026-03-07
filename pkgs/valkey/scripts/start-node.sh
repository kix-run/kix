#!/bin/bash

. /opt/bitnami/scripts/libos.sh
. /opt/bitnami/scripts/liblog.sh
. /opt/bitnami/scripts/libvalidations.sh

get_port() {
    hostname="$1"
    type="$2"

    port_var=$(echo "${hostname^^}_SERVICE_PORT_$type" | sed "s/-/_/g")
    port=${!port_var}

    if [ -z "$port" ]; then
        case $type in
            "SENTINEL")
                echo 26379
                ;;
            "VALKEY")
                echo 6379
                ;;
        esac
    else
        echo $port
    fi
}

get_full_hostname() {
    hostname="$1"
    full_hostname="${hostname}.${HEADLESS_SERVICE}"
    echo "${full_hostname}"
}

VALKEYPORT=$(get_port "$HOSTNAME" "VALKEY")

HEADLESS_SERVICE="@HEADLESS_SERVICE_FQDN@"

if [ -n "$VALKEY_EXTERNAL_PRIMARY_HOST" ]; then
    VALKEY_SERVICE="$VALKEY_EXTERNAL_PRIMARY_HOST"
else
    VALKEY_SERVICE="@SENTINEL_SERVICE_FQDN@"
fi

SENTINEL_SERVICE_PORT=$(get_port "@FULLNAME@" "SENTINEL")
validate_quorum() {
    if is_boolean_yes "$VALKEY_TLS_ENABLED"; then
        quorum_info_command="valkey-cli -h $VALKEY_SERVICE -p $SENTINEL_SERVICE_PORT --tls --cert ${VALKEY_TLS_CERT_FILE} --key ${VALKEY_TLS_KEY_FILE} --cacert ${VALKEY_TLS_CA_FILE} sentinel primary @PRIMARY_SET@"
    else
        quorum_info_command="valkey-cli -h $VALKEY_SERVICE -p $SENTINEL_SERVICE_PORT sentinel primary @PRIMARY_SET@"
    fi
    info "about to run the command: $quorum_info_command"
    eval $quorum_info_command | grep -Fq "s_down"
}

trigger_manual_failover() {
    if is_boolean_yes "$VALKEY_TLS_ENABLED"; then
        failover_command="valkey-cli -h $VALKEY_SERVICE -p $SENTINEL_SERVICE_PORT --tls --cert ${VALKEY_TLS_CERT_FILE} --key ${VALKEY_TLS_KEY_FILE} --cacert ${VALKEY_TLS_CA_FILE} sentinel failover @PRIMARY_SET@"
    else
        failover_command="valkey-cli -h $VALKEY_SERVICE -p $SENTINEL_SERVICE_PORT sentinel failover @PRIMARY_SET@"
    fi

    info "about to run the command: $failover_command"
    eval $failover_command
}

get_sentinel_primary_info() {
    if is_boolean_yes "$VALKEY_TLS_ENABLED"; then
        sentinel_info_command="timeout 90 valkey-cli -h $VALKEY_SERVICE -p $SENTINEL_SERVICE_PORT --tls --cert ${VALKEY_TLS_CERT_FILE} --key ${VALKEY_TLS_KEY_FILE} --cacert ${VALKEY_TLS_CA_FILE} sentinel get-primary-addr-by-name @PRIMARY_SET@"
    else
        sentinel_info_command="timeout 90 valkey-cli -h $VALKEY_SERVICE -p $SENTINEL_SERVICE_PORT sentinel get-primary-addr-by-name @PRIMARY_SET@"
    fi

    info "about to run the command: $sentinel_info_command"
    retry_while "eval $sentinel_info_command" 2 5
}

[[ -f $VALKEY_PASSWORD_FILE ]] && export VALKEY_PASSWORD="$(< "${VALKEY_PASSWORD_FILE}")"
[[ -f $VALKEY_PRIMARY_PASSWORD_FILE ]] && export VALKEY_PRIMARY_PASSWORD="$(< "${VALKEY_PRIMARY_PASSWORD_FILE}")"

# check if there is a primary
primary_in_persisted_conf="$(get_full_hostname "$HOSTNAME")"
primary_port_in_persisted_conf="$VALKEY_PRIMARY_PORT_NUMBER"
primary_in_sentinel="$(get_sentinel_primary_info)"
valkeyRetVal=$?

if [[ -f /opt/bitnami/valkey-sentinel/etc/sentinel.conf ]]; then
    primary_in_persisted_conf="$(awk '/monitor/ {print $4}' /opt/bitnami/valkey-sentinel/etc/sentinel.conf)"
    primary_port_in_persisted_conf="$(awk '/monitor/ {print $5}' /opt/bitnami/valkey-sentinel/etc/sentinel.conf)"
    info "Found previous primary ${primary_in_persisted_conf}:${primary_port_in_persisted_conf} in /opt/bitnami/valkey-sentinel/etc/sentinel.conf"
    debug "$(cat /opt/bitnami/valkey-sentinel/etc/sentinel.conf | grep monitor)"
fi

if [[ $valkeyRetVal -ne 0 ]]; then
    if [[ "$primary_in_persisted_conf" == "$(get_full_hostname "$HOSTNAME")" ]]; then
        # Case 1: No active sentinel and in previous sentinel.conf we were the primary --> PRIMARY
        info "Configuring the node as primary"
        export VALKEY_REPLICATION_MODE="primary"
    else
        # Case 2: No active sentinel and in previous sentinel.conf we were not primary --> REPLICA
        info "Configuring the node as replica"
        export VALKEY_REPLICATION_MODE="replica"
        VALKEY_PRIMARY_HOST=${primary_in_persisted_conf}
        VALKEY_PRIMARY_PORT_NUMBER=${primary_port_in_persisted_conf}
    fi
else
    # Fetches current primary's host and port
    VALKEY_SENTINEL_INFO=($(get_sentinel_primary_info))
    info "Current primary: VALKEY_SENTINEL_INFO=(${VALKEY_SENTINEL_INFO[0]},${VALKEY_SENTINEL_INFO[1]})"
    VALKEY_PRIMARY_HOST=${VALKEY_SENTINEL_INFO[0]}
    VALKEY_PRIMARY_PORT_NUMBER=${VALKEY_SENTINEL_INFO[1]}

    if [[ "$VALKEY_PRIMARY_HOST" == "$(get_full_hostname "$HOSTNAME")" ]]; then
        # Case 3: Active sentinel and primary it is this node --> PRIMARY
        info "Configuring the node as primary"
        export VALKEY_REPLICATION_MODE="primary"
    else
        # Case 4: Active sentinel and primary is not this node --> REPLICA
        info "Configuring the node as replica"
        export VALKEY_REPLICATION_MODE="replica"
    fi
fi

if [[ -n "$VALKEY_EXTERNAL_PRIMARY_HOST" ]]; then
  VALKEY_PRIMARY_HOST="$VALKEY_EXTERNAL_PRIMARY_HOST"
  VALKEY_PRIMARY_PORT_NUMBER="${VALKEY_EXTERNAL_PRIMARY_PORT}"
fi

if [[ -f /opt/bitnami/valkey/mounted-etc/replica.conf ]];then
    cp /opt/bitnami/valkey/mounted-etc/replica.conf /opt/bitnami/valkey/etc/replica.conf
fi

if [[ -f /opt/bitnami/valkey/mounted-etc/valkey.conf ]];then
    cp /opt/bitnami/valkey/mounted-etc/valkey.conf /opt/bitnami/valkey/etc/valkey.conf
fi

echo "" >> /opt/bitnami/valkey/etc/replica.conf
echo "replica-announce-port $VALKEYPORT" >> /opt/bitnami/valkey/etc/replica.conf
echo "replica-announce-ip $(get_full_hostname "$HOSTNAME")" >> /opt/bitnami/valkey/etc/replica.conf
ARGS=("--port" "${VALKEY_PORT}")

if [[ "$VALKEY_REPLICATION_MODE" = "replica" ]]; then
    ARGS+=("--replicaof" "${VALKEY_PRIMARY_HOST}" "${VALKEY_PRIMARY_PORT_NUMBER}")
fi
ARGS+=("--requirepass" "${VALKEY_PASSWORD}")
ARGS+=("--primaryauth" "${VALKEY_PRIMARY_PASSWORD}")
ARGS+=("--include" "/opt/bitnami/valkey/etc/replica.conf")
ARGS+=("--include" "/opt/bitnami/valkey/etc/valkey.conf")
exec valkey-server "${ARGS[@]}"

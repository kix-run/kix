#!/bin/bash

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

[[ -f $VALKEY_PASSWORD_FILE ]] && export VALKEY_PASSWORD="$(< "${VALKEY_PASSWORD_FILE}")"
[[ -f $VALKEY_PRIMARY_PASSWORD_FILE ]] && export VALKEY_PRIMARY_PASSWORD="$(< "${VALKEY_PRIMARY_PASSWORD_FILE}")"
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
ARGS+=("--replicaof" "${VALKEY_PRIMARY_HOST}" "${VALKEY_PRIMARY_PORT_NUMBER}")
ARGS+=("--requirepass" "${VALKEY_PASSWORD}")
ARGS+=("--primaryauth" "${VALKEY_PRIMARY_PASSWORD}")
ARGS+=("--include" "/opt/bitnami/valkey/etc/valkey.conf")
ARGS+=("--include" "/opt/bitnami/valkey/etc/replica.conf")
exec valkey-server "${ARGS[@]}"

#!/bin/bash

. /opt/bitnami/scripts/libos.sh
. /opt/bitnami/scripts/libvalidations.sh
. /opt/bitnami/scripts/libfile.sh

HEADLESS_SERVICE="@HEADLESS_SERVICE_FQDN@"
VALKEY_SERVICE="@SENTINEL_SERVICE_FQDN@"

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

SERVPORT=$(get_port "$HOSTNAME" "SENTINEL")
VALKEYPORT=$(get_port "$HOSTNAME" "VALKEY")
SENTINEL_SERVICE_PORT=$(get_port "@FULLNAME@" "SENTINEL")

sentinel_conf_set() {
    local -r key="${1:?missing key}"
    local value="${2:-}"

    # Sanitize inputs
    value="${value//\\/\\\\}"
    value="${value//&/\\&}"
    value="${value//\?/\\?}"
    [[ "$value" = "" ]] && value="\"$value\""

    replace_in_file "/opt/bitnami/valkey-sentinel/etc/prepare-sentinel.conf" "^#*\s*${key} .*" "${key} ${value}" false
}
sentinel_conf_add() {
    echo $'\n'"$@" >> "/opt/bitnami/valkey-sentinel/etc/prepare-sentinel.conf"
}
host_id() {
    echo "$1" | openssl sha1 | awk '{print $2}'
}
get_sentinel_primary_info() {
    if is_boolean_yes "$VALKEY_SENTINEL_TLS_ENABLED"; then
        sentinel_info_command="timeout 90 valkey-cli -h $VALKEY_SERVICE -p $SENTINEL_SERVICE_PORT --tls --cert ${VALKEY_SENTINEL_TLS_CERT_FILE} --key ${VALKEY_SENTINEL_TLS_KEY_FILE} --cacert ${VALKEY_SENTINEL_TLS_CA_FILE} sentinel get-primary-addr-by-name @PRIMARY_SET@"
    else
        sentinel_info_command="timeout 90 valkey-cli -h $VALKEY_SERVICE -p $SENTINEL_SERVICE_PORT sentinel get-primary-addr-by-name @PRIMARY_SET@"
    fi
    info "about to run the command: $sentinel_info_command"
    retry_while "eval $sentinel_info_command" 2 5
}

[[ -f $VALKEY_PASSWORD_FILE ]] && export VALKEY_PASSWORD="$(< "${VALKEY_PASSWORD_FILE}")"

primary_in_persisted_conf="$(get_full_hostname "$HOSTNAME")"

if [[ -f /opt/bitnami/valkey-sentinel/etc/sentinel.conf ]]; then
    primary_in_persisted_conf="$(awk '/monitor/ {print $4}' /opt/bitnami/valkey-sentinel/etc/sentinel.conf)"
    info "Found previous primary $primary_in_persisted_conf in /opt/bitnami/valkey-sentinel/etc/sentinel.conf"
    debug "$(cat /opt/bitnami/valkey-sentinel/etc/sentinel.conf | grep monitor)"
fi
VALKEY_SENTINEL_INFO=($(get_sentinel_primary_info))
if [ "$?" -eq "0" ]; then
    # current primary's host and port obtained from other Sentinel
    info "printing VALKEY_SENTINEL_INFO=(${VALKEY_SENTINEL_INFO[0]},${VALKEY_SENTINEL_INFO[1]})"
    VALKEY_PRIMARY_HOST=${VALKEY_SENTINEL_INFO[0]}
    VALKEY_PRIMARY_PORT_NUMBER=${VALKEY_SENTINEL_INFO[1]}
else
    VALKEY_PRIMARY_HOST="$primary_in_persisted_conf"
    VALKEY_PRIMARY_PORT_NUMBER="$VALKEYPORT"
fi
if [[ "$VALKEY_PRIMARY_HOST" == "$(get_full_hostname "$HOSTNAME")" ]]; then
    export VALKEY_REPLICATION_MODE="primary"
else
    export VALKEY_REPLICATION_MODE="replica"
fi

if [[ -n "$VALKEY_EXTERNAL_PRIMARY_HOST" ]]; then
  VALKEY_PRIMARY_HOST="$VALKEY_EXTERNAL_PRIMARY_HOST"
  VALKEY_PRIMARY_PORT_NUMBER="${VALKEY_EXTERNAL_PRIMARY_PORT}"
fi

# To prevent incomplete configuration and as the valkey container accesses /opt/bitnami/valkey-sentinel/etc/sentinel.conf
# as well, prepare the new config in `prepare-sentinel.conf` and move it atomically to the ultimate destination when it is complete.
cp /opt/bitnami/valkey-sentinel/mounted-etc/sentinel.conf /opt/bitnami/valkey-sentinel/etc/prepare-sentinel.conf
printf "\nsentinel auth-pass %s %s" "@PRIMARY_SET@" "$VALKEY_PASSWORD" >> /opt/bitnami/valkey-sentinel/etc/prepare-sentinel.conf
printf "\nsentinel myid %s" "$(host_id "$HOSTNAME")" >> /opt/bitnami/valkey-sentinel/etc/prepare-sentinel.conf

if [[ -z "$VALKEY_PRIMARY_HOST" ]] || [[ -z "$VALKEY_PRIMARY_PORT_NUMBER" ]]
then
    # Prevent incorrect configuration to be written to sentinel.conf
    error "Valkey primary host is configured incorrectly (host: $VALKEY_PRIMARY_HOST, port: $VALKEY_PRIMARY_PORT_NUMBER)"
    exit 1
fi

sentinel_conf_set "sentinel monitor" "@PRIMARY_SET@ "$VALKEY_PRIMARY_HOST" "$VALKEY_PRIMARY_PORT_NUMBER" @SENTINEL_QUORUM@"

add_known_sentinel() {
    hostname="$1"
    ip="$2"

    if [[ -n "$hostname" && -n "$ip" && "$hostname" != "$HOSTNAME" ]]; then
        sentinel_conf_add "sentinel known-sentinel @PRIMARY_SET@ $(get_full_hostname "$hostname") $(get_port "$hostname" "SENTINEL") $(host_id "$hostname")"
    fi
}
add_known_replica() {
    hostname="$1"
    ip="$2"

    if [[ -n "$ip" && "$(get_full_hostname "$hostname")" != "$VALKEY_PRIMARY_HOST" ]]; then
        sentinel_conf_add "sentinel known-replica @PRIMARY_SET@ $(get_full_hostname "$hostname") $(get_port "$hostname" "VALKEY")"
    fi
}

# Add available hosts on the network as known replicas & sentinels
for node in $(seq 0 $((@REPLICA_COUNT@-1))); do
    hostname="@FULLNAME@-node-$node"
    ip="$(getent hosts "$hostname.$HEADLESS_SERVICE" | awk '{ print $1 }')"
    add_known_sentinel "$hostname" "$ip"
    add_known_replica "$hostname" "$ip"
done

echo "" >> /opt/bitnami/valkey-sentinel/etc/prepare-sentinel.conf
echo "sentinel announce-hostnames yes" >> /opt/bitnami/valkey-sentinel/etc/prepare-sentinel.conf
echo "sentinel resolve-hostnames yes" >> /opt/bitnami/valkey-sentinel/etc/prepare-sentinel.conf
echo "sentinel announce-port $SERVPORT" >> /opt/bitnami/valkey-sentinel/etc/prepare-sentinel.conf
echo "sentinel announce-ip $(get_full_hostname "$HOSTNAME")" >> /opt/bitnami/valkey-sentinel/etc/prepare-sentinel.conf
mv /opt/bitnami/valkey-sentinel/etc/prepare-sentinel.conf /opt/bitnami/valkey-sentinel/etc/sentinel.conf
exec valkey-server /opt/bitnami/valkey-sentinel/etc/sentinel.conf --sentinel

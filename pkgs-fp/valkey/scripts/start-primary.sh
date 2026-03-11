#!/bin/bash

[[ -f $VALKEY_PASSWORD_FILE ]] && export VALKEY_PASSWORD="$(< "${VALKEY_PASSWORD_FILE}")"
if [[ -f /opt/bitnami/valkey/mounted-etc/primary.conf ]];then
    cp /opt/bitnami/valkey/mounted-etc/primary.conf /opt/bitnami/valkey/etc/primary.conf
fi
if [[ -f /opt/bitnami/valkey/mounted-etc/valkey.conf ]];then
    cp /opt/bitnami/valkey/mounted-etc/valkey.conf /opt/bitnami/valkey/etc/valkey.conf
fi
ARGS=("--port" "${VALKEY_PORT}")
ARGS+=("--requirepass" "${VALKEY_PASSWORD}")
ARGS+=("--primaryauth" "${VALKEY_PASSWORD}")
ARGS+=("--include" "/opt/bitnami/valkey/etc/valkey.conf")
ARGS+=("--include" "/opt/bitnami/valkey/etc/primary.conf")
exec valkey-server "${ARGS[@]}"

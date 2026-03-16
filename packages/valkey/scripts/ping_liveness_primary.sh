#!/bin/bash

[[ -f $VALKEY_PRIMARY_PASSWORD_FILE ]] && export VALKEY_PRIMARY_PASSWORD="$(< "${VALKEY_PRIMARY_PASSWORD_FILE}")"
[[ -n "$VALKEY_PRIMARY_PASSWORD" ]] && export REDISCLI_AUTH="$VALKEY_PRIMARY_PASSWORD"
response=$(
  timeout -s 15 $1 \
  valkey-cli \
    -h $VALKEY_PRIMARY_HOST \
    -p $VALKEY_PRIMARY_PORT_NUMBER \
    ping
)
if [ "$?" -eq "124" ]; then
  echo "Timed out"
  exit 1
fi
responseFirstWord=$(echo $response | head -n1 | awk '{print $1;}')
if [ "$response" != "PONG" ] && [ "$responseFirstWord" != "LOADING" ]; then
  echo "$response"
  exit 1
fi

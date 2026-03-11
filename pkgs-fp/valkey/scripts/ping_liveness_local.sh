#!/bin/bash

[[ -f $VALKEY_PASSWORD_FILE ]] && export VALKEY_PASSWORD="$(< "${VALKEY_PASSWORD_FILE}")"
[[ -n "$VALKEY_PASSWORD" ]] && export REDISCLI_AUTH="$VALKEY_PASSWORD"
response=$(
  timeout -s 15 $1 \
  valkey-cli \
    -h localhost \
    -p $VALKEY_PORT \
    ping
)
if [ "$?" -eq "124" ]; then
  echo "Timed out"
  exit 1
fi
responseFirstWord=$(echo $response | head -n1 | awk '{print $1;}')
if [ "$response" != "PONG" ] && [ "$responseFirstWord" != "LOADING" ] && [ "$responseFirstWord" != "MASTERDOWN" ]; then
  echo "$response"
  exit 1
fi

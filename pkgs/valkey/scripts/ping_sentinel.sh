#!/bin/bash
response=$(
  timeout -s 15 $1 \
  valkey-cli \
    -h localhost \
    -p $VALKEY_SENTINEL_PORT \
    ping
)
if [ "$?" -eq "124" ]; then
  echo "Timed out"
  exit 1
fi
if [ "$response" != "PONG" ]; then
  echo "$response"
  exit 1
fi

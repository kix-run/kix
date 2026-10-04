#!/bin/sh
# Starts `bao server`. With self-initialization on, pod 0 also loads the
# initialize stanza, unless a peer already reports an initialized cluster:
# pod 0 with an empty volume would otherwise initialize a second, separate
# cluster beside its peers instead of joining them.
set -eu

set -- -config="$CONFIG_DIR/server.json"

if [ "$SELF_INIT" = "true" ] && [ "${POD_NAME##*-}" = "0" ]; then
  initialized=""
  for peer in $PEER_ADDRS; do
    if BAO_CLIENT_TIMEOUT=5s bao status -address="$peer" -ca-cert="$TLS_DIR/ca.crt" -format=json 2>/dev/null \
      | grep -q '"initialized": *true'; then
      initialized="$peer"
      break
    fi
  done
  if [ -n "$initialized" ]; then
    echo "start: $initialized is initialized; joining it without self-initialization"
  else
    set -- "$@" -config="$INIT_DIR/init.json"
  fi
fi

exec bao server "$@"

# Valkey (Redis-compatible) kix package with Sentinel support.
#
# Deploys a Valkey cluster using StatefulSet with sentinel sidecar for
# automatic failover. Mirrors the Bitnami Valkey Helm chart topology.
#
# Resources: ServiceAccount, ConfigMap (scripts + health + configuration),
# StatefulSet (valkey + sentinel + optional metrics containers),
# Service (main), Service (headless), and optionally: Service (metrics),
# Secret (credentials).
#
# main = main Service (exposes both redis and sentinel ports).

{
  scope,
  config,
  lib,
}:

let
  name = scope.instanceName;

  cfg = scope.defaults config {
    image = {
      repository = "docker.io/bitnamilegacy/valkey";
      tag = "8.1.1-debian-12-r0";
      pullPolicy = "IfNotPresent";
    };
    replicaCount = 3;
    podManagementPolicy = "OrderedReady";
    auth = {
      enabled = true;
      existingSecret = null;
      existingSecretPasswordKey = "valkey-password";
      password = null;
    };
    sentinel = {
      enabled = true;
      image = {
        repository = "docker.io/bitnamilegacy/valkey-sentinel";
        tag = "8.1.1-debian-12-r0";
        pullPolicy = "IfNotPresent";
      };
      quorum = 2;
      downAfterMilliseconds = 3000;
      failoverTimeout = 10000;
      parallelSyncs = 1;
      primarySet = "primary";
      resources = {
        requests = {
          cpu = "100m";
          memory = "256Mi";
        };
        limits = {
          cpu = "500m";
          memory = "512Mi";
        };
      };
    };
    persistence = {
      enabled = true;
      size = "8Gi";
      storageClass = null;
    };
    resources = {
      requests = {
        cpu = "250m";
        memory = "512Mi";
      };
      limits = {
        cpu = "1";
        memory = "512Mi";
      };
    };
    metrics = {
      enabled = false;
      image = {
        repository = "docker.io/bitnamilegacy/redis-exporter";
        tag = "1.70.0-debian-12-r2";
        pullPolicy = "IfNotPresent";
      };
      resources = {
        requests = {
          cpu = "100m";
          memory = "128Mi";
        };
        limits = {
          cpu = "500m";
          memory = "256Mi";
        };
      };
    };
    priorityClassName = null;
    # Extra valkey configuration lines appended to valkey.conf
    extraConfig = "";
    # Extra primary-only configuration
    extraPrimaryConfig = "";
    # Extra replica-only configuration
    extraReplicaConfig = "";
  };

  selectorLabels = {
    "app.kubernetes.io/name" = "valkey";
    "app.kubernetes.io/instance" = name;
  };

  commonLabels = selectorLabels // {
    "app.kubernetes.io/component" = "node";
  };

  # Auth-related helpers.
  credentialsSecretName =
    if cfg.auth.existingSecret != null then cfg.auth.existingSecret else "${name}-credentials";

  authPasswordKey = cfg.auth.existingSecretPasswordKey;

  # ── ConfigMap data (scripts) ──────────────────────────────────

  headlessServiceFqdn = "${name}-headless.${scope.namespaceName}.svc.cluster.local";
  mainServiceFqdn = "${name}.${scope.namespaceName}.svc.cluster.local";

  startNodeScript = ''
    #!/bin/bash
    . /opt/bitnami/scripts/libos.sh
    . /opt/bitnami/scripts/liblog.sh
    . /opt/bitnami/scripts/libvalidations.sh
    get_port() {
        hostname="$1"
        type="$2"
        port_var=$(echo "''${hostname^^}_SERVICE_PORT_$type" | sed "s/-/_/g")
        port=''${!port_var}
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
        full_hostname="''${hostname}.''${HEADLESS_SERVICE}"
        echo "''${full_hostname}"
    }
    VALKEYPORT=$(get_port "$HOSTNAME" "VALKEY")
    HEADLESS_SERVICE="${headlessServiceFqdn}"
    if [ -n "$VALKEY_EXTERNAL_PRIMARY_HOST" ]; then
        VALKEY_SERVICE="$VALKEY_EXTERNAL_PRIMARY_HOST"
    else
        VALKEY_SERVICE="${mainServiceFqdn}"
    fi
    SENTINEL_SERVICE_PORT=$(get_port "${name}" "SENTINEL")
    validate_quorum() {
        if is_boolean_yes "$VALKEY_TLS_ENABLED"; then
            quorum_info_command="valkey-cli -h $VALKEY_SERVICE -p $SENTINEL_SERVICE_PORT --tls --cert ''${VALKEY_TLS_CERT_FILE} --key ''${VALKEY_TLS_KEY_FILE} --cacert ''${VALKEY_TLS_CA_FILE} sentinel primary ${cfg.sentinel.primarySet}"
        else
            quorum_info_command="valkey-cli -h $VALKEY_SERVICE -p $SENTINEL_SERVICE_PORT sentinel primary ${cfg.sentinel.primarySet}"
        fi
        info "about to run the command: $quorum_info_command"
        eval $quorum_info_command | grep -Fq "s_down"
    }
    trigger_manual_failover() {
        if is_boolean_yes "$VALKEY_TLS_ENABLED"; then
            failover_command="valkey-cli -h $VALKEY_SERVICE -p $SENTINEL_SERVICE_PORT --tls --cert ''${VALKEY_TLS_CERT_FILE} --key ''${VALKEY_TLS_KEY_FILE} --cacert ''${VALKEY_TLS_CA_FILE} sentinel failover ${cfg.sentinel.primarySet}"
        else
            failover_command="valkey-cli -h $VALKEY_SERVICE -p $SENTINEL_SERVICE_PORT sentinel failover ${cfg.sentinel.primarySet}"
        fi
        info "about to run the command: $failover_command"
        eval $failover_command
    }
    get_sentinel_primary_info() {
        if is_boolean_yes "$VALKEY_TLS_ENABLED"; then
            sentinel_info_command="timeout 90 valkey-cli -h $VALKEY_SERVICE -p $SENTINEL_SERVICE_PORT --tls --cert ''${VALKEY_TLS_CERT_FILE} --key ''${VALKEY_TLS_KEY_FILE} --cacert ''${VALKEY_TLS_CA_FILE} sentinel get-primary-addr-by-name ${cfg.sentinel.primarySet}"
        else
            sentinel_info_command="timeout 90 valkey-cli -h $VALKEY_SERVICE -p $SENTINEL_SERVICE_PORT sentinel get-primary-addr-by-name ${cfg.sentinel.primarySet}"
        fi
        info "about to run the command: $sentinel_info_command"
        retry_while "eval $sentinel_info_command" 2 5
    }
    [[ -f $VALKEY_PASSWORD_FILE ]] && export VALKEY_PASSWORD="$(< "''${VALKEY_PASSWORD_FILE}")"
    [[ -f $VALKEY_PRIMARY_PASSWORD_FILE ]] && export VALKEY_PRIMARY_PASSWORD="$(< "''${VALKEY_PRIMARY_PASSWORD_FILE}")"
    # check if there is a primary
    primary_in_persisted_conf="$(get_full_hostname "$HOSTNAME")"
    primary_port_in_persisted_conf="$VALKEY_PRIMARY_PORT_NUMBER"
    primary_in_sentinel="$(get_sentinel_primary_info)"
    valkeyRetVal=$?
    if [[ -f /opt/bitnami/valkey-sentinel/etc/sentinel.conf ]]; then
        primary_in_persisted_conf="$(awk '/monitor/ {print $4}' /opt/bitnami/valkey-sentinel/etc/sentinel.conf)"
        primary_port_in_persisted_conf="$(awk '/monitor/ {print $5}' /opt/bitnami/valkey-sentinel/etc/sentinel.conf)"
        info "Found previous primary ''${primary_in_persisted_conf}:''${primary_port_in_persisted_conf} in /opt/bitnami/valkey-sentinel/etc/sentinel.conf"
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
            VALKEY_PRIMARY_HOST=''${primary_in_persisted_conf}
            VALKEY_PRIMARY_PORT_NUMBER=''${primary_port_in_persisted_conf}
        fi
    else
        # Fetches current primary's host and port
        VALKEY_SENTINEL_INFO=($(get_sentinel_primary_info))
        info "Current primary: VALKEY_SENTINEL_INFO=(''${VALKEY_SENTINEL_INFO[0]},''${VALKEY_SENTINEL_INFO[1]})"
        VALKEY_PRIMARY_HOST=''${VALKEY_SENTINEL_INFO[0]}
        VALKEY_PRIMARY_PORT_NUMBER=''${VALKEY_SENTINEL_INFO[1]}
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
      VALKEY_PRIMARY_PORT_NUMBER="''${VALKEY_EXTERNAL_PRIMARY_PORT}"
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
    ARGS=("--port" "''${VALKEY_PORT}")
    if [[ "$VALKEY_REPLICATION_MODE" = "replica" ]]; then
        ARGS+=("--replicaof" "''${VALKEY_PRIMARY_HOST}" "''${VALKEY_PRIMARY_PORT_NUMBER}")
    fi
    ARGS+=("--requirepass" "''${VALKEY_PASSWORD}")
    ARGS+=("--primaryauth" "''${VALKEY_PRIMARY_PASSWORD}")
    ARGS+=("--include" "/opt/bitnami/valkey/etc/replica.conf")
    ARGS+=("--include" "/opt/bitnami/valkey/etc/valkey.conf")
    exec valkey-server "''${ARGS[@]}"
  '';

  startSentinelScript = ''
    #!/bin/bash
    . /opt/bitnami/scripts/libos.sh
    . /opt/bitnami/scripts/libvalidations.sh
    . /opt/bitnami/scripts/libfile.sh
    HEADLESS_SERVICE="${headlessServiceFqdn}"
    VALKEY_SERVICE="${mainServiceFqdn}"
    get_port() {
        hostname="$1"
        type="$2"
        port_var=$(echo "''${hostname^^}_SERVICE_PORT_$type" | sed "s/-/_/g")
        port=''${!port_var}
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
        full_hostname="''${hostname}.''${HEADLESS_SERVICE}"
        echo "''${full_hostname}"
    }
    SERVPORT=$(get_port "$HOSTNAME" "SENTINEL")
    VALKEYPORT=$(get_port "$HOSTNAME" "VALKEY")
    SENTINEL_SERVICE_PORT=$(get_port "${name}" "SENTINEL")
    sentinel_conf_set() {
        local -r key="''${1:?missing key}"
        local value="''${2:-}"
        # Sanitize inputs
        value="''${value//\\/\\\\}"
        value="''${value//&/\\&}"
        value="''${value//\?/\\?}"
        [[ "$value" = "" ]] && value="\"$value\""
        replace_in_file "/opt/bitnami/valkey-sentinel/etc/prepare-sentinel.conf" "^#*\s*''${key} .*" "''${key} ''${value}" false
    }
    sentinel_conf_add() {
        echo $'\n'"$@" >> "/opt/bitnami/valkey-sentinel/etc/prepare-sentinel.conf"
    }
    host_id() {
        echo "$1" | openssl sha1 | awk '{print $2}'
    }
    get_sentinel_primary_info() {
        if is_boolean_yes "$VALKEY_SENTINEL_TLS_ENABLED"; then
            sentinel_info_command="timeout 90 valkey-cli -h $VALKEY_SERVICE -p $SENTINEL_SERVICE_PORT --tls --cert ''${VALKEY_SENTINEL_TLS_CERT_FILE} --key ''${VALKEY_SENTINEL_TLS_KEY_FILE} --cacert ''${VALKEY_SENTINEL_TLS_CA_FILE} sentinel get-primary-addr-by-name ${cfg.sentinel.primarySet}"
        else
            sentinel_info_command="timeout 90 valkey-cli -h $VALKEY_SERVICE -p $SENTINEL_SERVICE_PORT sentinel get-primary-addr-by-name ${cfg.sentinel.primarySet}"
        fi
        info "about to run the command: $sentinel_info_command"
        retry_while "eval $sentinel_info_command" 2 5
    }
    [[ -f $VALKEY_PASSWORD_FILE ]] && export VALKEY_PASSWORD="$(< "''${VALKEY_PASSWORD_FILE}")"
    primary_in_persisted_conf="$(get_full_hostname "$HOSTNAME")"
    if [[ -f /opt/bitnami/valkey-sentinel/etc/sentinel.conf ]]; then
        primary_in_persisted_conf="$(awk '/monitor/ {print $4}' /opt/bitnami/valkey-sentinel/etc/sentinel.conf)"
        info "Found previous primary $primary_in_persisted_conf in /opt/bitnami/valkey-sentinel/etc/sentinel.conf"
        debug "$(cat /opt/bitnami/valkey-sentinel/etc/sentinel.conf | grep monitor)"
    fi
    VALKEY_SENTINEL_INFO=($(get_sentinel_primary_info))
    if [ "$?" -eq "0" ]; then
        # current primary's host and port obtained from other Sentinel
        info "printing VALKEY_SENTINEL_INFO=(''${VALKEY_SENTINEL_INFO[0]},''${VALKEY_SENTINEL_INFO[1]})"
        VALKEY_PRIMARY_HOST=''${VALKEY_SENTINEL_INFO[0]}
        VALKEY_PRIMARY_PORT_NUMBER=''${VALKEY_SENTINEL_INFO[1]}
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
      VALKEY_PRIMARY_PORT_NUMBER="''${VALKEY_EXTERNAL_PRIMARY_PORT}"
    fi
    # To prevent incomplete configuration and as the valkey container accesses /opt/bitnami/valkey-sentinel/etc/sentinel.conf
    # as well, prepare the new config in `prepare-sentinel.conf` and move it atomically to the ultimate destination when it is complete.
    cp /opt/bitnami/valkey-sentinel/mounted-etc/sentinel.conf /opt/bitnami/valkey-sentinel/etc/prepare-sentinel.conf
    printf "\nsentinel auth-pass %s %s" "${cfg.sentinel.primarySet}" "$VALKEY_PASSWORD" >> /opt/bitnami/valkey-sentinel/etc/prepare-sentinel.conf
    printf "\nsentinel myid %s" "$(host_id "$HOSTNAME")" >> /opt/bitnami/valkey-sentinel/etc/prepare-sentinel.conf
    if [[ -z "$VALKEY_PRIMARY_HOST" ]] || [[ -z "$VALKEY_PRIMARY_PORT_NUMBER" ]]
    then
        # Prevent incorrect configuration to be written to sentinel.conf
        error "Valkey primary host is configured incorrectly (host: $VALKEY_PRIMARY_HOST, port: $VALKEY_PRIMARY_PORT_NUMBER)"
        exit 1
    fi
    sentinel_conf_set "sentinel monitor" "${cfg.sentinel.primarySet} "$VALKEY_PRIMARY_HOST" "$VALKEY_PRIMARY_PORT_NUMBER" ${toString cfg.sentinel.quorum}"
    add_known_sentinel() {
        hostname="$1"
        ip="$2"
        if [[ -n "$hostname" && -n "$ip" && "$hostname" != "$HOSTNAME" ]]; then
            sentinel_conf_add "sentinel known-sentinel ${cfg.sentinel.primarySet} $(get_full_hostname "$hostname") $(get_port "$hostname" "SENTINEL") $(host_id "$hostname")"
        fi
    }
    add_known_replica() {
        hostname="$1"
        ip="$2"
        if [[ -n "$ip" && "$(get_full_hostname "$hostname")" != "$VALKEY_PRIMARY_HOST" ]]; then
            sentinel_conf_add "sentinel known-replica ${cfg.sentinel.primarySet} $(get_full_hostname "$hostname") $(get_port "$hostname" "VALKEY")"
        fi
    }
    # Add available hosts on the network as known replicas & sentinels
    for node in $(seq 0 $((${toString cfg.replicaCount}-1))); do
        hostname="${name}-node-$node"
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
  '';

  prestopSentinelScript = ''
    #!/bin/bash
    . /opt/bitnami/scripts/libvalidations.sh
    . /opt/bitnami/scripts/libos.sh
    HEADLESS_SERVICE="${headlessServiceFqdn}"
    get_full_hostname() {
        hostname="$1"
        full_hostname="''${hostname}.''${HEADLESS_SERVICE}"
        echo "''${full_hostname}"
    }
    run_sentinel_command() {
        if is_boolean_yes "$VALKEY_SENTINEL_TLS_ENABLED"; then
            valkey-cli -h "$VALKEY_SERVICE" -p "$VALKEY_SENTINEL_TLS_PORT_NUMBER" --tls --cert "$VALKEY_SENTINEL_TLS_CERT_FILE" --key "$VALKEY_SENTINEL_TLS_KEY_FILE" --cacert "$VALKEY_SENTINEL_TLS_CA_FILE" sentinel "$@"
        else
            valkey-cli -h "$VALKEY_SERVICE" -p "$VALKEY_SENTINEL_PORT" sentinel "$@"
        fi
    }
    sentinel_failover_finished() {
      VALKEY_SENTINEL_INFO=($(run_sentinel_command get-primary-addr-by-name "${cfg.sentinel.primarySet}"))
      VALKEY_PRIMARY_HOST="''${VALKEY_SENTINEL_INFO[0]}"
      [[ "$VALKEY_PRIMARY_HOST" != "$(get_full_hostname $HOSTNAME)" ]]
    }
    VALKEY_SERVICE="${mainServiceFqdn}"
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
  '';

  prestopValkeyScript = ''
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
    HEADLESS_SERVICE="${headlessServiceFqdn}"
    get_full_hostname() {
        hostname="$1"
        full_hostname="''${hostname}.''${HEADLESS_SERVICE}"
        echo "''${full_hostname}"
    }
    run_sentinel_command() {
        if is_boolean_yes "$VALKEY_SENTINEL_TLS_ENABLED"; then
            env -u REDISCLI_AUTH valkey-cli -h "$VALKEY_SERVICE" -p "$VALKEY_SENTINEL_TLS_PORT_NUMBER" --tls --cert "$VALKEY_SENTINEL_TLS_CERT_FILE" --key "$VALKEY_SENTINEL_TLS_KEY_FILE" --cacert "$VALKEY_SENTINEL_TLS_CA_FILE" sentinel "$@"
        else
            env -u REDISCLI_AUTH valkey-cli -h "$VALKEY_SERVICE" -p "$VALKEY_SENTINEL_PORT" sentinel "$@"
        fi
    }
    sentinel_failover_finished() {
        VALKEY_SENTINEL_INFO=($(run_sentinel_command get-primary-addr-by-name "${cfg.sentinel.primarySet}"))
        VALKEY_PRIMARY_HOST="''${VALKEY_SENTINEL_INFO[0]}"
        [[ "$VALKEY_PRIMARY_HOST" != "$(get_full_hostname $HOSTNAME)" ]]
    }
    VALKEY_SERVICE="${mainServiceFqdn}"
    # valkey-cli automatically consumes credentials from the REDISCLI_AUTH variable
    [[ -n "$VALKEY_PASSWORD" ]] && export REDISCLI_AUTH="$VALKEY_PASSWORD"
    [[ -f "$VALKEY_PASSWORD_FILE" ]] && export REDISCLI_AUTH="$(< "''${VALKEY_PASSWORD_FILE}")"
    if is_primary && ! sentinel_failover_finished; then
        echo "I am the primary pod and you are stopping me. Pausing client connections."
        # Pausing client write connections to avoid data loss
        run_valkey_command CLIENT PAUSE "22000" WRITE
        echo "Issuing failover"
        # if I am the primary, issue a command to failover once
        run_sentinel_command failover "${cfg.sentinel.primarySet}"
        echo "Waiting for sentinel to complete failover for up to 20s"
        retry_while "sentinel_failover_finished" "20" 1
    else
        exit 0
    fi
  '';

  # Health check scripts (in health configmap)
  pingLivenessLocalScript = ''
    #!/bin/bash
    [[ -f $VALKEY_PASSWORD_FILE ]] && export VALKEY_PASSWORD="$(< "''${VALKEY_PASSWORD_FILE}")"
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
  '';

  pingReadinessLocalScript = ''
    #!/bin/bash
    [[ -f $VALKEY_PASSWORD_FILE ]] && export VALKEY_PASSWORD="$(< "''${VALKEY_PASSWORD_FILE}")"
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
    if [ "$response" != "PONG" ]; then
      echo "$response"
      exit 1
    fi
  '';

  pingSentinelScript = ''
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
  '';

  # ── Configuration ConfigMap ─────────────────────────────────
  sentinelConf = ''
    dir "/tmp"
    port 26379
    sentinel monitor ${cfg.sentinel.primarySet} ${name}-node-0.${headlessServiceFqdn} 6379 ${toString cfg.sentinel.quorum}
    sentinel down-after-milliseconds ${cfg.sentinel.primarySet} ${toString cfg.sentinel.downAfterMilliseconds}
    sentinel failover-timeout ${cfg.sentinel.primarySet} ${toString cfg.sentinel.failoverTimeout}
    sentinel parallel-syncs ${cfg.sentinel.primarySet} ${toString cfg.sentinel.parallelSyncs}
    # User-supplied sentinel configuration:
    # End of sentinel configuration
  '';

  primaryConf = ''
    dir /data
    # User-supplied primary configuration:
    ${cfg.extraPrimaryConfig}# End of primary configuration
  '';

  replicaConf = ''
    dir /data
    # User-supplied replica configuration:
    ${cfg.extraReplicaConfig}# End of replica configuration
  '';

  valkeyConf = ''
    # User-supplied common configuration:
    ${cfg.extraConfig}# End of common configuration
  '';

  # ── Containers ──────────────────────────────────────────────────

  valkeyContainer = {
    name = "valkey";
    image = "${cfg.image.repository}:${cfg.image.tag}";
    imagePullPolicy = cfg.image.pullPolicy;
    command = [ "/bin/bash" ];
    args = [
      "-c"
      "/opt/bitnami/scripts/start-scripts/start-node.sh"
    ];
    env = [
      {
        name = "ALLOW_EMPTY_PASSWORD";
        value = "no";
      }
      {
        name = "BITNAMI_DEBUG";
        value = "false";
      }
      {
        name = "VALKEY_DATA_DIR";
        value = "/data";
      }
      {
        name = "VALKEY_PORT";
        value = "6379";
      }
      {
        name = "VALKEY_SENTINEL_PORT";
        value = "26379";
      }
      {
        name = "VALKEY_SENTINEL_TLS_ENABLED";
        value = "no";
      }
      {
        name = "VALKEY_TLS_ENABLED";
        value = "no";
      }
      {
        name = "VALKEY_PRIMARY_PORT_NUMBER";
        value = "6379";
      }
    ]
    ++ lib.optionals cfg.auth.enabled [
      {
        name = "VALKEY_PASSWORD_FILE";
        value = "/opt/bitnami/valkey/secrets/${authPasswordKey}";
      }
      {
        name = "VALKEY_PRIMARY_PASSWORD_FILE";
        value = "/opt/bitnami/valkey/secrets/${authPasswordKey}";
      }
    ];
    ports = [
      {
        name = "valkey";
        containerPort = 6379;
        protocol = "TCP";
      }
    ];
    livenessProbe = {
      exec.command = [
        "sh"
        "-c"
        "/health/ping_liveness_local.sh 5"
      ];
      initialDelaySeconds = 20;
      periodSeconds = 5;
      timeoutSeconds = 5;
      successThreshold = 1;
      failureThreshold = 5;
    };
    readinessProbe = {
      exec.command = [
        "sh"
        "-c"
        "/health/ping_readiness_local.sh 1"
      ];
      initialDelaySeconds = 20;
      periodSeconds = 5;
      timeoutSeconds = 1;
      successThreshold = 1;
      failureThreshold = 5;
    };
    startupProbe = {
      exec.command = [
        "sh"
        "-c"
        "/health/ping_liveness_local.sh 5"
      ];
      initialDelaySeconds = 10;
      periodSeconds = 10;
      timeoutSeconds = 5;
      successThreshold = 1;
      failureThreshold = 22;
    };
    lifecycle = {
      preStop.exec.command = [
        "/bin/bash"
        "-c"
        "/opt/bitnami/scripts/start-scripts/prestop-valkey.sh"
      ];
    };
    resources = cfg.resources;
    volumeMounts = [
      {
        name = "valkey-data";
        mountPath = "/data";
      }
      {
        name = "health";
        mountPath = "/health";
      }
      {
        name = "start-scripts";
        mountPath = "/opt/bitnami/scripts/start-scripts";
      }
      {
        name = "sentinel-data";
        mountPath = "/opt/bitnami/valkey-sentinel/etc";
      }
      {
        name = "empty-dir";
        mountPath = "/opt/bitnami/valkey/etc";
        subPath = "app-conf-dir";
      }
      {
        name = "config";
        mountPath = "/opt/bitnami/valkey/mounted-etc";
      }
      {
        name = "valkey-password";
        mountPath = "/opt/bitnami/valkey/secrets";
      }
      {
        name = "empty-dir";
        mountPath = "/tmp";
        subPath = "tmp-dir";
      }
    ];
    securityContext = {
      allowPrivilegeEscalation = false;
      capabilities.drop = [ "ALL" ];
      readOnlyRootFilesystem = true;
      runAsNonRoot = true;
      runAsUser = 1001;
      runAsGroup = 1001;
      seccompProfile.type = "RuntimeDefault";
    };
  };

  sentinelContainer = {
    name = "sentinel";
    image = "${cfg.sentinel.image.repository}:${cfg.sentinel.image.tag}";
    imagePullPolicy = cfg.sentinel.image.pullPolicy;
    command = [ "/bin/bash" ];
    args = [
      "-c"
      "/opt/bitnami/scripts/start-scripts/start-sentinel.sh"
    ];
    env = [
      {
        name = "BITNAMI_DEBUG";
        value = "false";
      }
      {
        name = "VALKEY_SENTINEL_PORT";
        value = "26379";
      }
      {
        name = "VALKEY_SENTINEL_TLS_ENABLED";
        value = "no";
      }
    ]
    ++ lib.optionals cfg.auth.enabled [
      {
        name = "VALKEY_PASSWORD_FILE";
        value = "/opt/bitnami/valkey/secrets/${authPasswordKey}";
      }
    ];
    ports = [
      {
        name = "valkey-sentinel";
        containerPort = 26379;
        protocol = "TCP";
      }
    ];
    livenessProbe = {
      exec.command = [
        "sh"
        "-c"
        "/health/ping_sentinel.sh 5"
      ];
      initialDelaySeconds = 20;
      periodSeconds = 10;
      timeoutSeconds = 5;
      successThreshold = 1;
      failureThreshold = 6;
    };
    readinessProbe = {
      exec.command = [
        "sh"
        "-c"
        "/health/ping_sentinel.sh 1"
      ];
      initialDelaySeconds = 20;
      periodSeconds = 5;
      timeoutSeconds = 1;
      successThreshold = 1;
      failureThreshold = 6;
    };
    startupProbe = {
      exec.command = [
        "sh"
        "-c"
        "/health/ping_sentinel.sh 5"
      ];
      initialDelaySeconds = 10;
      periodSeconds = 10;
      timeoutSeconds = 5;
      successThreshold = 1;
      failureThreshold = 22;
    };
    lifecycle = {
      preStop.exec.command = [
        "/bin/bash"
        "-c"
        "/opt/bitnami/scripts/start-scripts/prestop-sentinel.sh"
      ];
    };
    resources = cfg.sentinel.resources;
    volumeMounts = [
      {
        name = "valkey-data";
        mountPath = "/data";
      }
      {
        name = "health";
        mountPath = "/health";
      }
      {
        name = "start-scripts";
        mountPath = "/opt/bitnami/scripts/start-scripts";
      }
      {
        name = "sentinel-data";
        mountPath = "/opt/bitnami/valkey-sentinel/etc";
      }
      {
        name = "config";
        mountPath = "/opt/bitnami/valkey-sentinel/mounted-etc";
      }
      {
        name = "valkey-password";
        mountPath = "/opt/bitnami/valkey/secrets";
      }
      {
        name = "empty-dir";
        mountPath = "/tmp";
        subPath = "tmp-dir";
      }
    ];
    securityContext = {
      allowPrivilegeEscalation = false;
      capabilities.drop = [ "ALL" ];
      readOnlyRootFilesystem = true;
      runAsNonRoot = true;
      runAsUser = 1001;
      runAsGroup = 1001;
      seccompProfile.type = "RuntimeDefault";
    };
  };

  metricsContainer = {
    name = "metrics";
    image = "${cfg.metrics.image.repository}:${cfg.metrics.image.tag}";
    imagePullPolicy = cfg.metrics.image.pullPolicy;
    command = [
      "/bin/bash"
      "-c"
      ''
        export REDIS_PASSWORD="$(< $REDIS_PASSWORD_FILE)"
        redis_exporter
      ''
    ];
    env = [
      {
        name = "REDIS_ALIAS";
        value = name;
      }
      {
        name = "REDIS_EXPORTER_WEB_LISTEN_ADDRESS";
        value = ":9121";
      }
      {
        name = "REDIS_USER";
        value = "default";
      }
    ]
    ++ lib.optionals cfg.auth.enabled [
      {
        name = "REDIS_PASSWORD_FILE";
        value = "/secrets/${authPasswordKey}";
      }
    ];
    ports = [
      {
        name = "metrics";
        containerPort = 9121;
        protocol = "TCP";
      }
    ];
    livenessProbe = {
      tcpSocket.port = "metrics";
      initialDelaySeconds = 10;
      periodSeconds = 10;
      timeoutSeconds = 5;
      successThreshold = 1;
      failureThreshold = 5;
    };
    readinessProbe = {
      httpGet = {
        path = "/";
        port = "metrics";
      };
      initialDelaySeconds = 5;
      periodSeconds = 10;
      timeoutSeconds = 1;
      successThreshold = 1;
      failureThreshold = 3;
    };
    resources = cfg.metrics.resources;
    volumeMounts = lib.optionals cfg.auth.enabled [
      {
        name = "valkey-password";
        mountPath = "/secrets";
      }
    ]
    ++ [
      {
        name = "empty-dir";
        mountPath = "/tmp";
        subPath = "tmp-dir";
      }
    ];
    securityContext = {
      allowPrivilegeEscalation = false;
      capabilities.drop = [ "ALL" ];
      readOnlyRootFilesystem = true;
      runAsNonRoot = true;
      runAsUser = 1001;
      runAsGroup = 1001;
      seccompProfile.type = "RuntimeDefault";
    };
  };

  # Assemble the container list — metrics first, then sentinel, then valkey
  # (matches Bitnami ordering).
  containers =
    lib.optional cfg.metrics.enabled metricsContainer
    ++ [
      sentinelContainer
      valkeyContainer
    ];

in
self: {

  # --- ServiceAccount ---
  serviceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${name}";
    labels = selectorLabels;
    extra = {
      automountServiceAccountToken = false;
    };
  };

  # --- Secret (credentials, only when no existingSecret) ---
  secret =
    if cfg.auth.enabled && cfg.auth.existingSecret == null then
      scope.mkResource {
        apiVersion = "v1";
        kind = "Secret";
        name = "${name}-credentials";
        labels = selectorLabels;
        extra = {
          type = "Opaque";
          stringData = lib.optionalAttrs (cfg.auth.password != null) {
            ${authPasswordKey} = cfg.auth.password;
          };
        };
      }
    else
      null;

  # --- ConfigMap (scripts — start + prestop) ---
  configmap = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = "${name}-scripts";
    labels = selectorLabels;
    data = {
      "start-node.sh" = startNodeScript;
      "start-sentinel.sh" = startSentinelScript;
      "prestop-sentinel.sh" = prestopSentinelScript;
      "prestop-valkey.sh" = prestopValkeyScript;
    };
  };

  # --- ConfigMap (health check scripts) ---
  healthConfigmap = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = "${name}-health";
    labels = selectorLabels;
    data = {
      "ping_liveness_local.sh" = pingLivenessLocalScript;
      "ping_readiness_local.sh" = pingReadinessLocalScript;
      "ping_sentinel.sh" = pingSentinelScript;
    };
  };

  # --- ConfigMap (configuration — sentinel.conf + valkey.conf) ---
  configurationConfigmap = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = "${name}-configuration";
    labels = selectorLabels;
    data = {
      "primary.conf" = primaryConf;
      "replica.conf" = replicaConf;
      "sentinel.conf" = sentinelConf;
      "valkey.conf" = valkeyConf;
    };
  };

  # --- StatefulSet (valkey-node) ---
  statefulSet = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "StatefulSet";
    name = "${name}-node";
    labels = commonLabels;
    spec = {
      serviceName = "${self.headlessService}";
      replicas = cfg.replicaCount;
      podManagementPolicy = cfg.podManagementPolicy;
      updateStrategy = {
        type = "RollingUpdate";
      };
      selector.matchLabels = selectorLabels // {
        "app.kubernetes.io/component" = "node";
      };
      template = {
        metadata = {
          labels = selectorLabels // {
            "app.kubernetes.io/component" = "node";
          };
          annotations = {
            "checksum/configmap" = "\${${self.configmap}}";
            "checksum/health" = "\${${self.healthConfigmap}}";
            "checksum/scripts" = "\${${self.configmap}}";
            "checksum/secret" = "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a";
          }
          // lib.optionalAttrs cfg.metrics.enabled {
            "prometheus.io/port" = "9121";
            "prometheus.io/scrape" = "true";
          };
        };
        spec = {
          serviceAccountName = "${self.serviceAccount}";
          automountServiceAccountToken = false;
          terminationGracePeriodSeconds = 30;
          securityContext = {
            fsGroup = 1001;
            fsGroupChangePolicy = "Always";
          };
          affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution = [
            {
              weight = 1;
              podAffinityTerm = {
                labelSelector.matchLabels = selectorLabels // {
                  "app.kubernetes.io/component" = "node";
                };
                topologyKey = "kubernetes.io/hostname";
              };
            }
          ];
          inherit containers;
          volumes = [
            {
              name = "config";
              configMap = {
                name = "${self.configurationConfigmap}";
                defaultMode = 420; # 0644
              };
            }
            {
              name = "empty-dir";
              emptyDir = { };
            }
            {
              name = "health";
              configMap = {
                name = "${self.healthConfigmap}";
                defaultMode = 493; # 0755
              };
            }
            {
              name = "sentinel-data";
              emptyDir = { };
            }
            {
              name = "start-scripts";
              configMap = {
                name = "${self.configmap}";
                defaultMode = 493; # 0755
              };
            }
          ]
          ++ lib.optionals cfg.auth.enabled [
            {
              name = "valkey-password";
              secret = {
                secretName =
                  if cfg.auth.existingSecret != null then
                    cfg.auth.existingSecret
                  else
                    "${self.secret}";
                defaultMode = 420; # 0644
                items = [
                  {
                    key = authPasswordKey;
                    path = authPasswordKey;
                  }
                ];
              };
            }
          ]
          ++ lib.optional (!cfg.persistence.enabled) {
            name = "valkey-data";
            emptyDir = { };
          };
        }
        // lib.optionalAttrs (cfg.priorityClassName != null) {
          priorityClassName = cfg.priorityClassName;
        };
      };
    }
    // lib.optionalAttrs cfg.persistence.enabled {
      volumeClaimTemplates = [
        {
          metadata = {
            name = "valkey-data";
            labels = selectorLabels // {
              "app.kubernetes.io/component" = "node";
            };
          };
          spec = {
            accessModes = [ "ReadWriteOnce" ];
            resources.requests.storage = cfg.persistence.size;
          }
          // lib.optionalAttrs (cfg.persistence.storageClass != null) {
            storageClassName = cfg.persistence.storageClass;
          };
        }
      ];
    };
  };

  # --- Service (headless, for StatefulSet DNS) ---
  headlessService = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${name}-headless";
    labels = selectorLabels;
    spec = {
      type = "ClusterIP";
      clusterIP = "None";
      publishNotReadyAddresses = true;
      selector = selectorLabels;
      ports = [
        {
          name = "tcp-redis";
          port = 6379;
          targetPort = "redis";
          protocol = "TCP";
        }
        {
          name = "tcp-sentinel";
          port = 26379;
          targetPort = "valkey-sentinel";
          protocol = "TCP";
        }
      ];
    };
    requires = [ self.statefulSet ];
  };

  # --- Service (main entry point — exposes both redis and sentinel) ---
  mainService = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${name}";
    labels = commonLabels;
    spec = {
      type = "ClusterIP";
      selector = selectorLabels // {
        "app.kubernetes.io/component" = "node";
      };
      ports = [
        {
          name = "tcp-redis";
          port = 6379;
          targetPort = 6379;
          protocol = "TCP";
        }
        {
          name = "tcp-sentinel";
          port = 26379;
          targetPort = 26379;
          protocol = "TCP";
        }
      ];
    };
    outputs = {
      sentinelPort = "26379";
      port = "6379";
      primarySet = cfg.sentinel.primarySet;
    };
    requires = [ self.statefulSet ];
  };

  # --- Service (metrics, optional) ---
  metricsService =
    if cfg.metrics.enabled then
      scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${name}-metrics";
        labels = commonLabels // {
          "app.kubernetes.io/component" = "metrics";
        };
        annotations = {
          "prometheus.io/scrape" = "true";
          "prometheus.io/port" = "9121";
        };
        spec = {
          type = "ClusterIP";
          selector = selectorLabels;
          ports = [
            {
              name = "http-metrics";
              port = 9121;
              targetPort = "metrics";
              protocol = "TCP";
            }
          ];
        };
        outputs = {
          metricsPort = "9121";
        };
        requires = [ self.statefulSet ];
      }
    else
      null;

  # --- Entry point ---
  # main = main Service. Exposes both redis (6379) and sentinel (26379) ports.
  # Consumers connect to sentinel to discover the current primary via
  # SENTINEL get-master-addr-by-name.
  main = {
    resource = self.mainService;
    requires = lib.optional (self.metricsService != null) self.metricsService;
  };
}

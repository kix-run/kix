# Valkey (Redis-compatible) kix package.
#
# Supports two topologies (controlled by sentinel.enabled):
#   sentinel=true  — Node StatefulSet with sentinel sidecar for HA failover.
#   sentinel=false — Primary/replica StatefulSet (Bitnami primary/replica mode).
# Both default from the cluster's availability level (v2_discussions/145):
# standalone below "node", Sentinel with three pods from "node" up.
#
# Mirrors the Bitnami Valkey Helm chart topology.
#
# Resources: ServiceAccount, ConfigMap (scripts + health + configuration),
# StatefulSet, Service (main), Service (headless), NetworkPolicy, and
# optionally: Service (metrics), Secret (credentials). The
# PodDisruptionBudget is derived by the compiler from the availability
# level, not written here.
#
# root = primary Service.

{
  scope,
  lib,
  kix,
  availability,
}:

{
  meta = {
    version = "8.1.1";
    description = "Valkey: Redis-compatible in-memory data store";
    owner = "platform";
    lifecycle = "stateful";
    defaultAliases = [
      "valkey"
      "redis"
    ];
    k8s.minVersion = "1.25";
  };

  options = {
    image = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "docker.io/bitnamilegacy/valkey";
        tag = "8.1.3-debian-12-r3";
        pullPolicy = "IfNotPresent";
      };
    };
    replicaCount = lib.mkOption {
      type = lib.types.int;
      # A replica that cannot fail over is cost without benefit, so below
      # "node" Valkey runs standalone; from "node" up it is the Sentinel
      # topology (three nodes, quorum of two).
      default = kix.availability.pick availability {
        none = 1;
        pod = 1;
        node = 3;
        zone = 3;
      };
      description = ''
        Number of Valkey pods. Defaults from the cluster's availability
        level (v2_discussions/145): standalone below "node", three with
        Sentinel from "node" up.
      '';
    };
    podManagementPolicy = lib.mkOption {
      type = lib.types.str;
      default = "OrderedReady";
    };
    auth = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = true;
        existingSecret = null;
        existingSecretPasswordKey = "valkey-password";
        password = null;
        # Path to a SOPS-encrypted file containing the valkey-password key.
        # Wired to kix.run/sops-source so `kix deploy` decrypts it at apply time.
        secretSource = null;
      };
    };
    sentinel = lib.mkOption {
      type = lib.types.anything;
      default = {
        # Automatic failover needs a second node to fail over to.
        enabled = kix.availability.atLeast "node" availability;
        image = {
          repository = "docker.io/bitnamilegacy/valkey-sentinel";
          tag = "8.1.3-debian-12-r3";
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
    };
    persistence = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = true;
        size = "8Gi";
        storageClass = null;
      };
    };
    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
        requests = {
          cpu = "250m";
          memory = "512Mi";
        };
        limits = {
          cpu = "1";
          memory = "512Mi";
        };
      };
    };
    metrics = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = false;
        image = {
          repository = "docker.io/bitnamilegacy/redis-exporter";
          tag = "1.76.0-debian-12-r0";
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
    };
    priorityClassName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    # Extra valkey configuration lines appended to valkey.conf
    extraConfig = lib.mkOption {
      type = lib.types.str;
      default = "";
    };
    # Extra primary-only configuration
    extraPrimaryConfig = lib.mkOption {
      type = lib.types.str;
      default = "";
    };
    # Extra replica-only configuration
    extraReplicaConfig = lib.mkOption {
      type = lib.types.str;
      default = "";
    };
  };

  build =
    {
      self,
      config,
      clusterConfig,
      prometheus ? null,
    }:
    let
      name = scope.instanceName;

      hasMetrics = config.metrics.enabled && prometheus != null;

      selectorLabels = scope.selectorLabels // {
        "app.kubernetes.io/name" = "valkey";
      };

      # When sentinel is disabled, use "primary" component label to match Bitnami's primary/replica topology.
      componentName = if config.sentinel.enabled then "node" else "primary";

      componentLabel =
        if scope.labelStyle == "helm" then
          { component = componentName; }
        else
          { "app.kubernetes.io/component" = componentName; };

      commonLabels = selectorLabels // componentLabel;

      # Distinct metadata identity for the headless twin
      # (distinctSameKindLabels): without it the headless Service's labels
      # are a subset of the main Service's, so no label selector can single
      # either out.
      headlessComponentLabel =
        if scope.labelStyle == "helm" then
          { component = "headless"; }
        else
          { "app.kubernetes.io/component" = "headless"; };

      # Auth-related helpers.
      authPasswordKey = config.auth.existingSecretPasswordKey;

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
                quorum_info_command="valkey-cli -h $VALKEY_SERVICE -p $SENTINEL_SERVICE_PORT --tls --cert ''${VALKEY_TLS_CERT_FILE} --key ''${VALKEY_TLS_KEY_FILE} --cacert ''${VALKEY_TLS_CA_FILE} sentinel primary ${config.sentinel.primarySet}"
            else
                quorum_info_command="valkey-cli -h $VALKEY_SERVICE -p $SENTINEL_SERVICE_PORT sentinel primary ${config.sentinel.primarySet}"
            fi
            info "about to run the command: $quorum_info_command"
            eval $quorum_info_command | grep -Fq "s_down"
        }
        trigger_manual_failover() {
            if is_boolean_yes "$VALKEY_TLS_ENABLED"; then
                failover_command="valkey-cli -h $VALKEY_SERVICE -p $SENTINEL_SERVICE_PORT --tls --cert ''${VALKEY_TLS_CERT_FILE} --key ''${VALKEY_TLS_KEY_FILE} --cacert ''${VALKEY_TLS_CA_FILE} sentinel failover ${config.sentinel.primarySet}"
            else
                failover_command="valkey-cli -h $VALKEY_SERVICE -p $SENTINEL_SERVICE_PORT sentinel failover ${config.sentinel.primarySet}"
            fi
            info "about to run the command: $failover_command"
            eval $failover_command
        }
        get_sentinel_primary_info() {
            if is_boolean_yes "$VALKEY_TLS_ENABLED"; then
                sentinel_info_command="timeout 90 valkey-cli -h $VALKEY_SERVICE -p $SENTINEL_SERVICE_PORT --tls --cert ''${VALKEY_TLS_CERT_FILE} --key ''${VALKEY_TLS_KEY_FILE} --cacert ''${VALKEY_TLS_CA_FILE} sentinel get-primary-addr-by-name ${config.sentinel.primarySet}"
            else
                sentinel_info_command="timeout 90 valkey-cli -h $VALKEY_SERVICE -p $SENTINEL_SERVICE_PORT sentinel get-primary-addr-by-name ${config.sentinel.primarySet}"
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
                sentinel_info_command="timeout 90 valkey-cli -h $VALKEY_SERVICE -p $SENTINEL_SERVICE_PORT --tls --cert ''${VALKEY_SENTINEL_TLS_CERT_FILE} --key ''${VALKEY_SENTINEL_TLS_KEY_FILE} --cacert ''${VALKEY_SENTINEL_TLS_CA_FILE} sentinel get-primary-addr-by-name ${config.sentinel.primarySet}"
            else
                sentinel_info_command="timeout 90 valkey-cli -h $VALKEY_SERVICE -p $SENTINEL_SERVICE_PORT sentinel get-primary-addr-by-name ${config.sentinel.primarySet}"
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
        printf "\nsentinel auth-pass %s %s" "${config.sentinel.primarySet}" "$VALKEY_PASSWORD" >> /opt/bitnami/valkey-sentinel/etc/prepare-sentinel.conf
        printf "\nsentinel myid %s" "$(host_id "$HOSTNAME")" >> /opt/bitnami/valkey-sentinel/etc/prepare-sentinel.conf
        if [[ -z "$VALKEY_PRIMARY_HOST" ]] || [[ -z "$VALKEY_PRIMARY_PORT_NUMBER" ]]
        then
            # Prevent incorrect configuration to be written to sentinel.conf
            error "Valkey primary host is configured incorrectly (host: $VALKEY_PRIMARY_HOST, port: $VALKEY_PRIMARY_PORT_NUMBER)"
            exit 1
        fi
        sentinel_conf_set "sentinel monitor" "${config.sentinel.primarySet} "$VALKEY_PRIMARY_HOST" "$VALKEY_PRIMARY_PORT_NUMBER" ${toString config.sentinel.quorum}"
        add_known_sentinel() {
            hostname="$1"
            ip="$2"
            if [[ -n "$hostname" && -n "$ip" && "$hostname" != "$HOSTNAME" ]]; then
                sentinel_conf_add "sentinel known-sentinel ${config.sentinel.primarySet} $(get_full_hostname "$hostname") $(get_port "$hostname" "SENTINEL") $(host_id "$hostname")"
            fi
        }
        add_known_replica() {
            hostname="$1"
            ip="$2"
            if [[ -n "$ip" && "$(get_full_hostname "$hostname")" != "$VALKEY_PRIMARY_HOST" ]]; then
                sentinel_conf_add "sentinel known-replica ${config.sentinel.primarySet} $(get_full_hostname "$hostname") $(get_port "$hostname" "VALKEY")"
            fi
        }
        # Add available hosts on the network as known replicas & sentinels
        for node in $(seq 0 $((${toString config.replicaCount}-1))); do
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
          VALKEY_SENTINEL_INFO=($(run_sentinel_command get-primary-addr-by-name "${config.sentinel.primarySet}"))
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
            VALKEY_SENTINEL_INFO=($(run_sentinel_command get-primary-addr-by-name "${config.sentinel.primarySet}"))
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
            run_sentinel_command failover "${config.sentinel.primarySet}"
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

      # ── Primary/Replica scripts (non-sentinel mode) ─────────────
      startPrimaryScript = ''
        #!/bin/bash
        [[ -f $VALKEY_PASSWORD_FILE ]] && export VALKEY_PASSWORD="$(< "''${VALKEY_PASSWORD_FILE}")"
        if [[ -f /opt/bitnami/valkey/mounted-etc/primary.conf ]];then
            cp /opt/bitnami/valkey/mounted-etc/primary.conf /opt/bitnami/valkey/etc/primary.conf
        fi
        if [[ -f /opt/bitnami/valkey/mounted-etc/valkey.conf ]];then
            cp /opt/bitnami/valkey/mounted-etc/valkey.conf /opt/bitnami/valkey/etc/valkey.conf
        fi
        ARGS=("--port" "''${VALKEY_PORT}")
        ARGS+=("--requirepass" "''${VALKEY_PASSWORD}")
        ARGS+=("--primaryauth" "''${VALKEY_PASSWORD}")
        ARGS+=("--include" "/opt/bitnami/valkey/etc/valkey.conf")
        ARGS+=("--include" "/opt/bitnami/valkey/etc/primary.conf")
        exec valkey-server "''${ARGS[@]}"
      '';

      startReplicaScript = ''
        #!/bin/bash
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
        [[ -f $VALKEY_PASSWORD_FILE ]] && export VALKEY_PASSWORD="$(< "''${VALKEY_PASSWORD_FILE}")"
        [[ -f $VALKEY_PRIMARY_PASSWORD_FILE ]] && export VALKEY_PRIMARY_PASSWORD="$(< "''${VALKEY_PRIMARY_PASSWORD_FILE}")"
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
        ARGS+=("--replicaof" "''${VALKEY_PRIMARY_HOST}" "''${VALKEY_PRIMARY_PORT_NUMBER}")
        ARGS+=("--requirepass" "''${VALKEY_PASSWORD}")
        ARGS+=("--primaryauth" "''${VALKEY_PRIMARY_PASSWORD}")
        ARGS+=("--include" "/opt/bitnami/valkey/etc/valkey.conf")
        ARGS+=("--include" "/opt/bitnami/valkey/etc/replica.conf")
        exec valkey-server "''${ARGS[@]}"
      '';

      # ── Health check scripts for primary/replica mode ────────────
      pingLivenessPrimaryScript = ''
        #!/bin/bash
        [[ -f $VALKEY_PRIMARY_PASSWORD_FILE ]] && export VALKEY_PRIMARY_PASSWORD="$(< "''${VALKEY_PRIMARY_PASSWORD_FILE}")"
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
      '';

      pingReadinessPrimaryScript = ''
        #!/bin/bash
        [[ -f $VALKEY_PRIMARY_PASSWORD_FILE ]] && export VALKEY_PRIMARY_PASSWORD="$(< "''${VALKEY_PRIMARY_PASSWORD_FILE}")"
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
        if [ "$response" != "PONG" ]; then
          echo "$response"
          exit 1
        fi
      '';

      pingLivenessLocalAndPrimaryScript = ''
        script_dir="$(dirname "$0")"
        exit_status=0
        "$script_dir/ping_liveness_local.sh" $1 || exit_status=$?
        "$script_dir/ping_liveness_primary.sh" $1 || exit_status=$?
        exit $exit_status
      '';

      pingReadinessLocalAndPrimaryScript = ''
        script_dir="$(dirname "$0")"
        exit_status=0
        "$script_dir/ping_readiness_local.sh" $1 || exit_status=$?
        "$script_dir/ping_readiness_primary.sh" $1 || exit_status=$?
        exit $exit_status
      '';

      parseSentinelsAwk = ''
        /ip/ {FOUND_IP=1}
        /port/ {FOUND_PORT=1}
        /runid/ {FOUND_RUNID=1}
        !/ip|port|runid/ {
          if (FOUND_IP==1) {
            IP=$1; FOUND_IP=0;
          }
          else if (FOUND_PORT==1) {
            PORT=$1;
            FOUND_PORT=0;
          } else if (FOUND_RUNID==1) {
            printf "\nsentinel known-sentinel primary %s %s %s", IP, PORT, $0; FOUND_RUNID=0;
          }
        }
      '';

      # ── Configuration ConfigMap ─────────────────────────────────
      sentinelConf = ''
        dir "/tmp"
        port 26379
        sentinel monitor ${config.sentinel.primarySet} ${name}-node-0.${headlessServiceFqdn} 6379 ${toString config.sentinel.quorum}
        sentinel down-after-milliseconds ${config.sentinel.primarySet} ${toString config.sentinel.downAfterMilliseconds}
        sentinel failover-timeout ${config.sentinel.primarySet} ${toString config.sentinel.failoverTimeout}
        sentinel parallel-syncs ${config.sentinel.primarySet} ${toString config.sentinel.parallelSyncs}
        # User-supplied sentinel configuration:
        # End of sentinel configuration
      '';

      primaryConf = ''
        dir /data
        # User-supplied primary configuration:
        ${config.extraPrimaryConfig}# End of primary configuration
      '';

      replicaConf = ''
        dir /data
        # User-supplied replica configuration:
        ${config.extraReplicaConfig}# End of replica configuration
      '';

      valkeyConf = ''
        # User-supplied common configuration:
        ${config.extraConfig}# End of common configuration
      '';

      # ── Containers ──────────────────────────────────────────────────

      valkeyContainer = {
        name = "valkey";
        image = "${config.image.repository}:${config.image.tag}";
        imagePullPolicy = config.image.pullPolicy;
        command = [ "/bin/bash" ];
        args = [
          "-c"
          "/opt/bitnami/scripts/start-scripts/start-${
            if config.sentinel.enabled then "node" else "primary"
          }.sh"
        ];
        env = kix.mkEnvVars (
          {
            ALLOW_EMPTY_PASSWORD = "no";
            BITNAMI_DEBUG = "false";
            VALKEY_PORT = "6379";
            VALKEY_TLS_ENABLED = "no";
            VALKEY_PASSWORD_FILE =
              if config.auth.enabled then "/opt/bitnami/valkey/secrets/${authPasswordKey}" else null;
          }
          // (
            if config.sentinel.enabled then
              {
                # Sentinel mode env vars
                VALKEY_DATA_DIR = "/data";
                VALKEY_SENTINEL_PORT = "26379";
                VALKEY_SENTINEL_TLS_ENABLED = "no";
                VALKEY_PRIMARY_PORT_NUMBER = "6379";
                VALKEY_PRIMARY_PASSWORD_FILE =
                  if config.auth.enabled then "/opt/bitnami/valkey/secrets/${authPasswordKey}" else null;
              }
            else
              {
                # Primary/replica mode env vars
                VALKEY_REPLICATION_MODE = "primary";
              }
          )
        );
        ports = [
          (kix.port "redis" 6379)
        ];
        livenessProbe = {
          exec.command = [
            "sh"
            "-c"
            "/health/ping_liveness_local.sh 5"
          ];
          initialDelaySeconds = 20;
          periodSeconds = 5;
          timeoutSeconds = if config.sentinel.enabled then 5 else 6;
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
          timeoutSeconds = if config.sentinel.enabled then 1 else 2;
          successThreshold = 1;
          failureThreshold = 5;
        };
        resources = config.resources;
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
        ]
        ++ lib.optional config.sentinel.enabled {
          name = "sentinel-data";
          mountPath = "/opt/bitnami/valkey-sentinel/etc";
        }
        ++ [
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
      }
      // lib.optionalAttrs config.sentinel.enabled {
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
      };

      sentinelContainer = {
        name = "sentinel";
        image = "${config.sentinel.image.repository}:${config.sentinel.image.tag}";
        imagePullPolicy = config.sentinel.image.pullPolicy;
        command = [ "/bin/bash" ];
        args = [
          "-c"
          "/opt/bitnami/scripts/start-scripts/start-sentinel.sh"
        ];
        env = kix.mkEnvVars {
          BITNAMI_DEBUG = "false";
          VALKEY_SENTINEL_PORT = "26379";
          VALKEY_SENTINEL_TLS_ENABLED = "no";
          VALKEY_PASSWORD_FILE =
            if config.auth.enabled then "/opt/bitnami/valkey/secrets/${authPasswordKey}" else null;
        };
        ports = [
          (kix.port "valkey-sentinel" 26379)
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
        resources = config.sentinel.resources;
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
        image = "${config.metrics.image.repository}:${config.metrics.image.tag}";
        imagePullPolicy = config.metrics.image.pullPolicy;
        command = [
          "/bin/bash"
          "-c"
          ''
            export REDIS_PASSWORD="$(< $REDIS_PASSWORD_FILE)"
            redis_exporter
          ''
        ];
        env = kix.mkEnvVars {
          REDIS_ALIAS = name;
          REDIS_EXPORTER_WEB_LISTEN_ADDRESS = ":9121";
          REDIS_USER = "default";
          REDIS_PASSWORD_FILE = if config.auth.enabled then "/secrets/${authPasswordKey}" else null;
        };
        ports = [
          (kix.port "metrics" 9121)
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
        resources = config.metrics.resources;
        volumeMounts =
          lib.optionals config.auth.enabled [
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

      # Assemble the container list — metrics first, then sentinel (if enabled), then valkey
      # (matches Bitnami ordering).
      containers =
        lib.optional config.metrics.enabled metricsContainer
        ++ lib.optional config.sentinel.enabled sentinelContainer
        ++ [
          valkeyContainer
        ];

    in
    {

      # --- ServiceAccount ---
      # In primary/replica mode, the SA is named {name}-primary to match Bitnami's pattern.
      serviceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = if config.sentinel.enabled then "${name}" else "${name}-primary";
        labels = selectorLabels;
        extra = {
          automountServiceAccountToken = false;
        };
      };

      # --- Secret (credentials, only when no existingSecret) ---
      # In primary/replica mode, the secret is named {name} (not {name}-credentials).
      secret =
        if config.auth.enabled && config.auth.existingSecret == null then
          scope.mkSecret {
            name = if config.sentinel.enabled then "${name}-credentials" else "${name}";
            labels = selectorLabels;
            keys = [ authPasswordKey ];
            stringData = lib.optionalAttrs (config.auth.password != null) {
              ${authPasswordKey} = config.auth.password;
            };
            source = config.auth.secretSource or null;
          }
        else
          null;

      # --- Auth secret handle (for consumers) ---
      # Consumers read the password via `valkey.out.authSecret.out.keyRef ...`.
      # When the user points us at an existingSecret, wrap it in a SecretRef so
      # it still carries DI context and the keyRef/mkEnv helpers.
      authSecret =
        if !config.auth.enabled then
          null
        else if config.auth.existingSecret != null then
          scope.mkSecretRef {
            name = config.auth.existingSecret;
            keys = [ authPasswordKey ];
          }
        else
          self.secret;

      # --- ConfigMap (scripts — start + prestop) ---
      configmap = scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "${name}-scripts";
        labels = selectorLabels;
        data =
          if config.sentinel.enabled then
            {
              "start-node.sh" = startNodeScript;
              "start-sentinel.sh" = startSentinelScript;
              "prestop-sentinel.sh" = prestopSentinelScript;
              "prestop-valkey.sh" = prestopValkeyScript;
            }
          else
            {
              "start-primary.sh" = startPrimaryScript;
              "start-replica.sh" = startReplicaScript;
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
          "ping_liveness_primary.sh" = pingLivenessPrimaryScript;
          "ping_readiness_primary.sh" = pingReadinessPrimaryScript;
          "ping_liveness_local_and_primary.sh" = pingLivenessLocalAndPrimaryScript;
          "ping_readiness_local_and_primary.sh" = pingReadinessLocalAndPrimaryScript;
          "parse_sentinels.awk" = parseSentinelsAwk;
        }
        // lib.optionalAttrs config.sentinel.enabled {
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
          "valkey.conf" = valkeyConf;
        }
        // lib.optionalAttrs config.sentinel.enabled {
          "sentinel.conf" = sentinelConf;
        };
      };

      # --- StatefulSet (valkey-node or valkey-primary) ---
      statefulSet =
        let
          topologySuffix = if config.sentinel.enabled then "node" else "primary";
        in
        {
          name = "${name}-${topologySuffix}";
          labels = commonLabels;
          spec = {
            serviceName = self.headlessService.name;
            replicas = config.replicaCount;
            podManagementPolicy = config.podManagementPolicy;
            updateStrategy = {
              type = "RollingUpdate";
            };
            selector.matchLabels = selectorLabels // componentLabel;
            template = {
              metadata = {
                labels = selectorLabels // componentLabel;
                annotations = {
                  "checksum/configmap" = self.configmap.out.identityHash;
                  "checksum/health" = self.healthConfigmap.out.identityHash;
                  "checksum/scripts" = self.configmap.out.identityHash;
                  "checksum/secret" = "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a";
                }
                // lib.optionalAttrs config.metrics.enabled {
                  "prometheus.io/port" = "9121";
                  "prometheus.io/scrape" = "true";
                };
              };
              spec = {
                serviceAccountName = self.serviceAccount.out.name;
                automountServiceAccountToken = false;
                terminationGracePeriodSeconds = 30;
                securityContext = {
                  fsGroup = 1001;
                  fsGroupChangePolicy = "Always";
                };
                inherit containers;
                volumes = [
                  {
                    name = "config";
                    configMap = {
                      name = self.configurationConfigmap.out.name;
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
                      name = self.healthConfigmap.out.name;
                      defaultMode = 493; # 0755
                    };
                  }
                ]
                ++ lib.optional config.sentinel.enabled {
                  name = "sentinel-data";
                  emptyDir = { };
                }
                ++ [
                  {
                    name = "start-scripts";
                    configMap = {
                      name = self.configmap.out.name;
                      defaultMode = 493; # 0755
                    };
                  }
                ]
                ++ lib.optionals config.auth.enabled [
                  {
                    name = "valkey-password";
                    secret = {
                      # `self.authSecret` is `self.secret` in managed mode
                      # and a `mkSecretRef` marker when the user passes
                      # `existingSecret` — both carry DI context.
                      secretName = self.authSecret.out.name;
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
                ++ lib.optional (!config.persistence.enabled) {
                  name = "valkey-data";
                  emptyDir = { };
                };
              }
              // lib.optionalAttrs (config.priorityClassName != null) {
                priorityClassName = config.priorityClassName;
              };
            };
          }
          // lib.optionalAttrs config.persistence.enabled {
            volumeClaimTemplates = [
              {
                metadata = {
                  name = "valkey-data";
                  labels = selectorLabels // componentLabel;
                };
                spec = {
                  accessModes = [ "ReadWriteOnce" ];
                  resources.requests.storage = config.persistence.size;
                }
                // lib.optionalAttrs (config.persistence.storageClass != null) {
                  storageClassName = config.persistence.storageClass;
                };
              }
            ];
          };
        }
        |> scope.mkStatefulSet;

      # --- Service (headless, for StatefulSet DNS) ---
      # The selector comes from the workload, so the dependency on the
      # StatefulSet is tracked and `selectorCoherence` has a workload to
      # trace it to. `clusterIP = "None"` merges into the built spec rather
      # than replacing it.
      headlessService =
        self.statefulSet
        |> kix.service.fromWorkload {
          name = "${name}-headless";
          labels = selectorLabels // headlessComponentLabel;
          spec.clusterIP = "None";
          ports = [
            {
              name = "tcp-redis";
              port = 6379;
              targetPort = 6379;
              protocol = "TCP";
            }
          ]
          ++ lib.optional config.sentinel.enabled {
            name = "tcp-sentinel";
            port = 26379;
            targetPort = 26379;
            protocol = "TCP";
          };
        }
        |> scope.mkResource;

      # --- Service (main entry point — exposes both redis and sentinel) ---
      mainService =
        self.statefulSet
        |> kix.service.fromWorkload {
          name = "${name}";
          labels = commonLabels;
          ports = [
            {
              name = "tcp-redis";
              port = 6379;
              targetPort = 6379;
              protocol = "TCP";
            }
          ]
          ++ lib.optional config.sentinel.enabled {
            name = "tcp-sentinel";
            port = 26379;
            targetPort = 26379;
            protocol = "TCP";
          };
          outputs = {
            port = "6379";
            primaryFqdn = "${name}-primary.${scope.namespaceName}.svc.cluster.local";
          }
          // lib.optionalAttrs config.sentinel.enabled {
            sentinelPort = "26379";
            primarySet = config.sentinel.primarySet;
          };
        }
        |> scope.mkResource;

      # --- NetworkPolicy ---
      networkPolicy = scope.mkResource {
        apiVersion = "networking.k8s.io/v1";
        kind = "NetworkPolicy";
        inherit name;
        labels = selectorLabels;
        spec = {
          podSelector.matchLabels = selectorLabels;
          policyTypes = [
            "Ingress"
            "Egress"
          ];
          egress = [ { } ];
          ingress = [
            {
              ports = [
                {
                  port = 6379;
                  protocol = "TCP";
                }
              ]
              ++ lib.optional config.sentinel.enabled {
                port = 26379;
                protocol = "TCP";
              };
            }
          ]
          ++ lib.optional config.metrics.enabled {
            ports = [
              {
                port = 9121;
                protocol = "TCP";
              }
            ];
          };
        };
      };

      # --- Service (metrics, optional) ---
      metricsService =
        if config.metrics.enabled then
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
                  targetPort = 9121;
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

      # --- PrometheusRule (alerts, optional) ---
      prometheusRules =
        if hasMetrics then
          prometheus.out.mkPrometheusRule scope {
            name = "${name}-alerts";
            spec = {
              groups = [
                {
                  name = "valkey-alerts";
                  rules = [
                    {
                      alert = "ValkeyDown";
                      expr = "redis_up == 0";
                      "for" = "1m";
                      labels.severity = "critical";
                      annotations = {
                        summary = "Valkey instance is down";
                        description = "Valkey instance {{ $labels.instance }} has been down for more than 1 minute";
                      };
                    }
                    {
                      alert = "ValkeyOutOfConfiguredMaxmemory";
                      expr = "redis_memory_used_bytes / on(pod) group_left() kube_pod_container_resource_limits{container=\"valkey\", resource=\"memory\"} * 100 > 80";
                      "for" = "5m";
                      labels.severity = "critical";
                      annotations = {
                        summary = "Valkey running out of configured maxmemory";
                        description = "Valkey instance {{ $labels.instance }} is using {{ $value | humanizePercentage }} of Kubernetes memory limit";
                      };
                    }
                    {
                      alert = "ValkeyMemoryHigh";
                      expr = "redis_memory_used_bytes / on(pod) group_left() kube_pod_container_resource_limits{container=\"valkey\", resource=\"memory\"} * 100 > 60";
                      "for" = "10m";
                      labels.severity = "warning";
                      annotations = {
                        summary = "Valkey memory usage is high";
                        description = "Valkey instance {{ $labels.instance }} is using {{ $value | humanizePercentage }} of Kubernetes memory limit";
                      };
                    }
                    {
                      alert = "ValkeyTooManyConnections";
                      expr = "redis_connected_clients > 1000";
                      "for" = "5m";
                      labels.severity = "warning";
                      annotations = {
                        summary = "Valkey has too many connections";
                        description = "Valkey instance {{ $labels.instance }} has {{ $value }} connected clients";
                      };
                    }
                    {
                      alert = "ValkeyNotEnoughConnections";
                      expr = "redis_connected_clients < 1";
                      "for" = "5m";
                      labels.severity = "warning";
                      annotations = {
                        summary = "Valkey has no connections";
                        description = "Valkey instance {{ $labels.instance }} has no connected clients for more than 5 minutes";
                      };
                    }
                    {
                      alert = "ValkeyRejectedConnections";
                      expr = "increase(redis_rejected_connections_total[1m]) > 0";
                      "for" = "5m";
                      labels.severity = "warning";
                      annotations = {
                        summary = "Valkey is rejecting connections";
                        description = "Valkey instance {{ $labels.instance }} has rejected connections in the last minute";
                      };
                    }
                    {
                      alert = "ValkeyNoQuorum";
                      expr = "max(\n  label_replace(redis_connected_slaves, \"statefulset\", \"$1\", \"pod\", \"^(.*)-[0-9]+$\")\n) by (statefulset, namespace)\n<\non(statefulset, namespace) group_left()\n((kube_statefulset_status_replicas{statefulset=~\".*valkey.*-node\"} - 1) / 2)\n";
                      "for" = "5m";
                      labels.severity = "critical";
                      annotations = {
                        summary = "Valkey has lost sentinel quorum";
                        description = "Valkey cluster {{ $labels.statefulset }} in {{ $labels.namespace }} has {{ $value }} connected replicas - sentinel cannot perform automatic failover (requires quorum)";
                      };
                    }
                    {
                      alert = "ValkeyReplicaDegraded";
                      expr = "max(\n  label_replace(redis_connected_slaves, \"statefulset\", \"$1\", \"pod\", \"^(.*)-[0-9]+$\")\n) by (statefulset, namespace)\n<\non(statefulset, namespace) group_left()\n(kube_statefulset_status_replicas{statefulset=~\".*valkey.*-node\"} - 1)\nand\nmax(\n  label_replace(redis_connected_slaves, \"statefulset\", \"$1\", \"pod\", \"^(.*)-[0-9]+$\")\n) by (statefulset, namespace)\n>=\non(statefulset, namespace) group_left()\n((kube_statefulset_status_replicas{statefulset=~\".*valkey.*-node\"} - 1) / 2)\n";
                      "for" = "5m";
                      labels.severity = "warning";
                      annotations = {
                        summary = "Valkey cluster is degraded";
                        description = "Valkey cluster {{ $labels.statefulset }} in {{ $labels.namespace }} has {{ $value }} connected replicas (below configured replica count)";
                      };
                    }
                  ];
                }
              ];
            };
          }
        else
          null;

      # --- Entry point ---
      # root = primary Service. Exposes both redis (6379) and sentinel (26379) ports.
      # Consumers connect to sentinel to discover the current primary via
      # SENTINEL get-master-addr-by-name.
      root = {
        resource = self.mainService;
        out = lib.optionalAttrs (self.authSecret != null) {
          authSecret = self.authSecret;
          authPasswordKey = authPasswordKey;
        };
        requires = [
          self.serviceAccount
          self.configmap
          self.healthConfigmap
          self.configurationConfigmap
          self.statefulSet
          self.headlessService
        ]
        ++ lib.optional (self.secret != null) self.secret
        ++ lib.optional (self.metricsService != null) self.metricsService
        ++ lib.optional (self.prometheusRules != null) self.prometheusRules
        ++ [
          self.networkPolicy
        ];
      };
    };
}

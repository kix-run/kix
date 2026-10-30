# rabbitmq-cluster: a RabbitMQ cluster run by the RabbitMQ Cluster
# Operator, as one rabbitmq.com RabbitmqCluster.
#
# The operator creates the StatefulSet `<instance>-server` and its claims,
# the client Service `<instance>` (AMQP 5672, management 15672, and
# Prometheus 15692), the headless Service `<instance>-nodes`, the Erlang
# cookie, and the Secret `<instance>-default-user` with the credentials of
# an administrator it generates. The package references the client Service
# and the default-user Secret, so consumers wait for the cluster and get
# network policy to the RabbitMQ pods.
#
# Minimal instance, with an operator elsewhere in the cluster:
#
#   instances.messaging.rabbitmq.package = packages.rabbitmq-cluster;
#
# A consumer reads the broker from `out`:
#
#   env = kix.mkEnvVars {
#     AMQP_HOST = rabbitmq.out.host;
#     AMQP_PORT = rabbitmq.out.port;
#     AMQP_VHOST = rabbitmq.out.vhost;
#     AMQP_USERNAME = rabbitmq.out.credentials.out.keyRef "username";
#     AMQP_PASSWORD = rabbitmq.out.credentials.out.keyRef "password";
#   };
#
# Dependencies:
#   rabbitmqOperator (required)  a rabbitmq-operator instance; the package
#                                reads its CRD handle, release, and pod
#                                labels. An imported operator is refused.
#   storageClasses (optional)    the class of the data volumes when
#                                `storage.storageClass` is null.
#   prometheus (optional)        a PodMonitor for RabbitMQ's Prometheus
#                                endpoint (TCP 15692) while
#                                `metrics.enabled`.
#
# Defaults: `replicas` from the availability level (1 at none, 3 from pod
# up), RabbitMQ 4.3 from the official image, the definition's default
# resources (1 CPU requested, 2 CPU limit, 2Gi), and 10Gi volumes. Quorum
# queues need a majority of the nodes, so an even replica count is
# refused.
#
# Placement: with more than one replica, the pods spread over nodes and
# zones as the availability level asks, and a PodDisruptionBudget lets one
# pod go at a time. The operator's own zone spread is off
# (rabbitmq.com/disable-default-topology-spread-constraints), so the
# derived spread is the only placement rule.
#
# Network policy: with an enforcer, the package opens the pods' DNS,
# Erlang distribution (TCP 25672) and epmd (TCP 4369) between the
# cluster's own pods, and the operator's calls to the management API (TCP
# 15672). An image tag below 4.1, or one that names no version, also gets
# API server egress for the Kubernetes peer discovery backend; from 4.1 the
# operator grants the pods no peer-discovery Role
# (internal/resource/rabbitmq_resource_builder.go upstream).
# Consumers get AMQP (TCP 5672) through the client Service reference.
#
# Escape hatches: `settings`, rendered as rabbitmq.conf lines into
# `spec.rabbitmq.additionalConfig`, and `extraSpec`, merged over the
# RabbitmqCluster spec. The keys and fields the options own are refused,
# listed on each.
#
# Alerts: with a prometheus dependency and `metrics.enabled`, a
# PrometheusRule `<instance>-alerts` selects the PodMonitor's series by
# `job="<namespace>/<instance>"`. They read the aggregated `/metrics`
# endpoint the PodMonitor scrapes, which reports queues summed per node, so
# no rule names a queue.
#   RabbitMQDown (critical)                no node answers a scrape.
#   RabbitMQQuorumLost (critical, replicas > 1)
#                                          fewer than a majority of
#                                          `replicas` nodes answer, so
#                                          quorum queues and the metadata
#                                          store cannot commit. The
#                                          majority comes from `replicas`,
#                                          not from the nodes that run:
#                                          after a refused lower
#                                          `replicas` (see below) the rule
#                                          needs fewer nodes than the
#                                          running cluster does, and can
#                                          miss a lost majority.
#   RabbitMQClusterIdentityMismatch (critical, replicas > 1)
#                                          the nodes report more than one
#                                          cluster ID, so a node formed a
#                                          cluster of its own.
#   RabbitMQDistributionLinksMissing (warning, replicas > 1)
#                                          a node is connected to fewer than
#                                          `replicas - 1` other nodes.
#   RabbitMQMemoryAlarm (critical)         a node's memory alarm blocks
#                                          publishers on every node.
#   RabbitMQDiskAlarm (critical)           a node's free disk alarm does
#                                          the same.
#   RabbitMQMemoryNearWatermark (warning)  a node uses over 90% of its
#                                          memory high watermark.
#   RabbitMQDiskNearAlarm (warning)        a node's free disk is under twice
#                                          the free disk limit.
#   RabbitMQFileDescriptorsNearLimit (warning)
#                                          a node uses over 80% of its file
#                                          descriptors, past which it
#                                          refuses connections.
#   RabbitMQAlarmMetricsMissing (warning)  a node is scraped but reports no
#                                          alarm metrics, so the alarm
#                                          alerts cannot fire for it.
# The operator sets the free disk limit to 2GB. On a volume under 5GB
# RabbitMQDiskNearAlarm can fire while the cluster is idle and healthy, and
# at 2GB or less RabbitMQDiskAlarm fires too and publishers are blocked
# from the first boot. Evaluation warns about such a `storage.size`.
# The rules derive from the cluster-operator 2.23.0 rules in
# observability/prometheus/rules/rabbitmq, rewritten to select the instance.
# Left out: the file descriptor alarm rule, whose metric RabbitMQ 4.3.6 no
# longer reports; queues without consumers, growing queues, unroutable
# messages, and connection churn, which need per-queue metrics or depend on
# the application; and nodes not ready, full volumes, and crash
# loops, which prometheus-default-rules reports
# (KubeStatefulSetReplicasMismatch, KubePersistentVolumeFillingUp,
# KubePodCrashLooping). A queue that lost its leader shows only in
# `rabbitmq-queues quorum_status`.
#
# Limits: TLS, the Vault and external-Secret backends, and the ports of
# additional plugins (MQTT, STOMP, streams) are not modelled; network
# policy opens AMQP only. Queues, users, and vhosts are not modelled, so
# every consumer shares the default user and the default vhost. The
# operator copies the RabbitmqCluster's Kix annotations to the objects it
# creates; it drops the app.kubernetes.io labels, so `kix gc` does not list
# those objects as its own.
#
# Changes the operator refuses: it sets `ReconcileSuccess=False` and does
# not advance `status.observedGeneration`, so the deploy waits on
# `AllReplicasReady` until it times out without naming the reason. Kix
# cannot see the running cluster's values, so it cannot refuse these at
# evaluation. They are a lower `replicas` (`UnsupportedOperation`; lowering
# the availability level from pod to none does this), a smaller
# `storage.size`, and another `storage.storageClass` (`FailedReconcilePVC`).
# Read `kubectl get rabbitmqcluster <instance> -o yaml` for the condition.
# `settings.default_vhost` takes effect only when a node first boots with
# an empty data directory, so changing it on a running cluster points
# `out.vhost` at a vhost that does not exist.
#
# `out`:
#   out.host, out.port  the client Service and its AMQP port (5672).
#   out.vhost           the default vhost: `settings.default_vhost`, or "/".
#   out.credentials     the default-user Secret (keys `username` and
#                       `password`), for `out.keyRef` and `out.mkEnv`.
#   out.extraImages     the RabbitMQ image.
#
# root = the RabbitmqCluster.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "rabbitmq-cluster ${ns}/${name}";

  # meta.version and the default image tag: the RabbitMQ release the
  # cluster runs.
  release = "4.3.6";

  # The RabbitmqCluster fields this package writes are those of the
  # operator's 2.23 release.
  supportedRelease = "2.23";

  amqpPort = 5672;
  managementPort = 15672;
  prometheusPort = 15692;
  epmdPort = 4369;
  distributionPort = 25672;

  # RabbitmqCluster spec paths the options own.
  locked = [
    [ "replicas" ]
    [ "image" ]
    [ "resources" ]
    [
      "persistence"
      "storage"
    ]
    [
      "persistence"
      "storageClassName"
    ]
    [
      "rabbitmq"
      "additionalConfig"
    ]
  ]
  # The pod labels the operator sets and rabbitmq-operator's
  # operandSelectors names (internal/metadata/label.go upstream).
  ++
    map
      (label: [
        "override"
        "statefulSet"
        "spec"
        "template"
        "metadata"
        "labels"
        label
      ])
      [
        "app.kubernetes.io/name"
        "app.kubernetes.io/component"
        "app.kubernetes.io/part-of"
      ];

  # rabbitmq.conf keys the package owns, exactly or by prefix, with the
  # reason. Network policy, the PodMonitor, and the operator's management
  # calls are derived from the listener ports, and the operator configures
  # peer discovery and creates the default user (internal/resource/configmap.go
  # and default_user_secret.go upstream).
  ownedKeys = {
    "listeners.tcp" =
      "out.port and the network policy to the AMQP listener assume port ${toString amqpPort}";
    "management.tcp.port" =
      "the operator calls the management API on port ${toString managementPort}, and the package opens that port to it";
    "prometheus.tcp.port" = "the PodMonitor scrapes port ${toString prometheusPort}";
    "distribution.listener" =
      "the network policy between the cluster's pods opens Erlang distribution on port ${toString distributionPort}";
    "cluster_formation" = "the operator configures peer discovery";
    "default_user" =
      "the operator generates the default user and publishes it in the Secret `out.credentials` names";
    "default_pass" =
      "the operator generates the default user and publishes it in the Secret `out.credentials` names";
  };
  ownedBy =
    key:
    lib.findFirst (prefix: key == prefix || lib.hasPrefix "${prefix}." key) null (
      builtins.attrNames ownedKeys
    );

  renderValue = v: if builtins.isBool v then lib.boolToString v else toString v;

  # The PodMonitor's name. Its series carry job="<namespace>/<name>", which
  # the alerts select on.
  podMonitorName = name;
in
{
  meta = {
    version = release;
    description = "RabbitMQ cluster run by the RabbitMQ Cluster Operator (RabbitmqCluster)";
    owner = "platform";
    defaultAliases = [ "rabbitmq" ];
    lifecycle = "stateful";
    # Consumers read the default-user Secret by secretKeyRef.
    scope = "namespace";
  };

  assertions =
    { config, ... }:
    let
      badKeys = builtins.filter (k: builtins.match "[^[:space:]=]+" k == null) (
        builtins.attrNames config.settings
      );
      multiline = builtins.filter (
        k: builtins.match "[^\n\r]*" (renderValue config.settings.${k}) == null
      ) (builtins.attrNames config.settings);
      owned = builtins.filter (k: ownedBy k != null) (builtins.attrNames config.settings);
      envPorts = builtins.filter (lib.flip lib.hasInfix (config.extraSpec.rabbitmq.envConfig or "")) [
        "RABBITMQ_NODE_PORT"
        "RABBITMQ_DIST_PORT"
        "ERL_EPMD_PORT"
      ];
      passwords = builtins.filter (k: builtins.match ".*password.*" (lib.toLower k) != null) (
        builtins.attrNames config.settings
      );
    in
    [
      {
        # StatefulSet `<name>-server` takes the controller-revision-hash
        # label `<name>-server-<10 characters>`, at most 63.
        assertion =
          builtins.stringLength name <= 45 && builtins.match "[a-z]([-a-z0-9]*[a-z0-9])?" name != null;
        message = "the RabbitmqCluster name must be a DNS-1035 label of at most 45 characters, because the operator names its Service after it and its StatefulSet `<name>-server`; \"${name}\" is ${toString (builtins.stringLength name)} characters. Rename the instance.";
      }
      {
        assertion = lib.mod config.replicas 2 == 1;
        message = "replicas is ${toString config.replicas}. Quorum queues need a majority of the nodes, and an even count tolerates no more lost nodes than the odd count below it. Set replicas to an odd number.";
      }
      {
        assertion = badKeys == [ ];
        message = "settings key ${builtins.toJSON (builtins.head badKeys)} contains whitespace or `=`, so it does not render as one rabbitmq.conf line. Write the key as RabbitMQ's documentation spells it, such as \"vm_memory_high_watermark.relative\".";
      }
      {
        assertion = multiline == [ ];
        message = "settings.\"${builtins.head multiline}\" contains a line break, which would start another rabbitmq.conf line. Write the value on one line.";
      }
      {
        assertion = owned == [ ];
        message =
          let
            k = builtins.head owned;
          in
          "settings sets \"${k}\", which the package owns: ${ownedKeys.${ownedBy k}}. Remove it.";
      }
      {
        assertion = passwords == [ ];
        message = "settings sets \"${builtins.head passwords}\". The operator writes settings into the ConfigMap ${name}-server-conf, which is not a Secret, and the value also lands in the Nix store. Remove it; the package has no way to read a rabbitmq.conf value from a Secret.";
      }
      {
        assertion = !(config.extraSpec ? secretBackend);
        message = "extraSpec sets secretBackend, and out.credentials names the Secret ${name}-default-user that the operator creates only without one. Remove secretBackend.";
      }
      {
        assertion = envPorts == [ ];
        message = "extraSpec.rabbitmq.envConfig sets ${builtins.head envPorts}, which moves a port that out.port and the network policy name. Remove it.";
      }
      {
        assertion = !((config.extraSpec.tls or { }) ? disableNonTLSListeners);
        message = "extraSpec sets tls.disableNonTLSListeners, which closes the AMQP listener on port ${toString amqpPort} that out.port and the network policy name. Remove it; TLS listeners are not modelled.";
      }
    ];

  # An imported operator has no out.release; the build refuses it first.
  deps.rabbitmqOperator.assertions = dep: [
    {
      assertion = !(dep.out ? release) || lib.versions.majorMinor dep.out.release == supportedRelease;
      message = "this package writes the RabbitmqCluster fields of the RabbitMQ Cluster Operator ${supportedRelease}, and the rabbitmqOperator dependency runs ${dep.out.release}. Update kix/packages/rabbitmq-cluster for that release.";
    }
  ];

  options = {
    replicas = lib.mkOption {
      type = lib.types.ints.positive;
      # One node cannot survive its own pod's restart, and quorum queues
      # need a majority, so every level above `none` takes three.
      default = kix.availability.pick availability {
        none = 1;
        pod = 3;
        node = 3;
        zone = 3;
      };
      defaultText = lib.literalExpression "kix.availability.pick availability { none = 1; pod = 3; node = 3; zone = 3; }";
      description = "RabbitMQ nodes (`spec.replicas`). Must be odd.";
    };

    image = kix.options.image {
      repository = "docker.io/library/rabbitmq";
      tag = "${release}-management";
      digest = "sha256:316ffd2a847e59112eee2c65f04bbd0989d93aaf1486c07b721f8d22d863b968";
      description = "RabbitMQ image (`spec.image`). The operator enables the management, Prometheus, and Kubernetes peer discovery plugins, which the official image ships.";
    };

    # The definition's defaults for a RabbitmqCluster that sets none
    # (api/v1beta1/rabbitmqcluster_types.go upstream).
    resources = kix.options.resources {
      requests = {
        cpu = "1";
        memory = "2Gi";
      };
      limits = {
        cpu = "2";
        memory = "2Gi";
      };
    };

    storage = {
      size = lib.mkOption {
        type = kix.types.quantity;
        default = "10Gi";
        description = "Size of each node's data volume (`spec.persistence.storage`).";
      };
      storageClass = lib.mkOption {
        type = lib.types.nullOr lib.types.nonEmptyStr;
        default = null;
        description = "StorageClass of the data volumes. Null takes the `storageClasses` dependency's class, or the cluster's default class without one.";
      };
    };

    metrics = kix.options.monitor;

    settings = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.oneOf [
          lib.types.str
          lib.types.int
          lib.types.bool
        ]
      );
      default = { };
      example = {
        "vm_memory_high_watermark.relative" = "0.6";
        default_vhost = "app";
      };
      description = ''
        rabbitmq.conf entries, rendered one `key = value` line each into
        `spec.rabbitmq.additionalConfig`; RabbitMQ applies them over the
        operator's configuration. `default_vhost` also sets `out.vhost`;
        RabbitMQ creates that vhost only when a node first boots with an
        empty data directory, so set it before the first deploy.
        Refused: keys under `listeners.tcp`, `management.tcp.port`,
        `prometheus.tcp.port`, `distribution.listener`, and
        `cluster_formation`, `default_user`, `default_pass`, keys that
        contain `password`, and line breaks.
      '';
    };

    extraSpec = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        rabbitmq.additionalPlugins = [ "rabbitmq_shovel" ];
      };
      description = ''
        Merged over the RabbitmqCluster spec. Refused: `replicas`, `image`,
        `resources`, `persistence.storage`, `persistence.storageClassName`,
        `rabbitmq.additionalConfig` (use `settings`), `secretBackend`, and
        `tls.disableNonTLSListeners`, the pod template's
        `app.kubernetes.io/name`, `component`, and `part-of` labels under
        `override.statefulSet.spec.template.metadata.labels` (the network
        policy, the PodMonitor, and the operator's own pod cache select
        them), and an `rabbitmq.envConfig` that sets RABBITMQ_NODE_PORT,
        RABBITMQ_DIST_PORT, or ERL_EPMD_PORT. `rabbitmq.advancedConfig` is
        not checked: a listener port it moves leaves network policy on the
        old port.
        `override.statefulSet.spec.template.spec.topologySpreadConstraints`
        replaces the spread the package derives from the availability
        level.
      '';
    };
  };

  build = [
    (
      {
        self,
        config,
        clusterConfig,
        rabbitmqOperator,
        storageClasses ? null,
        prometheus ? null,
        ...
      }:
      let
        operator =
          if rabbitmqOperator.out ? operandSelectors then
            rabbitmqOperator.out
          else
            throw "${who}: the rabbitmqOperator dependency has no out.operandSelectors, as with an import. This package reads the operator's CRD handle and pod labels from it. Wire a managed rabbitmq-operator instance with deps.rabbitmqOperator = ref.<namespace>.<instance>.";

        operandSelector = operator.operandSelectors.cluster name;

        storageClass =
          if config.storage.storageClass != null then
            config.storage.storageClass
          else if storageClasses != null then
            storageClasses.out.storageClassName
          else
            null;

        spread = lib.optionals (config.replicas > 1) (
          kix.availability.spreadConstraints {
            level = availability;
            selector = operandSelector;
            topology = clusterConfig.cluster.topology;
          }
        );

        # From 4.1 the operator grants the pods no peer-discovery Role, so
        # they get no API server egress; a tag with no version keeps it.
        tagVersion = builtins.match "([0-9]+)\\.([0-9]+).*" config.image.tag;
        peerDiscoveryApi =
          tagVersion == null
          || lib.versionOlder "${builtins.elemAt tagVersion 0}.${builtins.elemAt tagVersion 1}" "4.1";

        additionalConfig = lib.concatStrings (
          lib.mapAttrsToList (k: v: "${k} = ${renderValue v}\n") config.settings
        );

        baseSpec = {
          inherit (config) replicas resources;
          image = kix.image.ref config.image;
          persistence = {
            storage = toString config.storage.size;
          }
          // lib.optionalAttrs (storageClass != null) { storageClassName = storageClass; };
        }
        // lib.optionalAttrs (additionalConfig != "") {
          rabbitmq.additionalConfig = additionalConfig;
        }
        // lib.optionalAttrs (spread != [ ]) {
          override.statefulSet.spec.template.spec.topologySpreadConstraints = spread;
        };

        spec = kix.mergeGuarded {
          inherit who locked;
        } baseSpec config.extraSpec;

        # The operator writes `disk_free_limit.absolute = 2GB` into every
        # node's rabbitmq.conf. Below 5GB a fresh volume leaves too little
        # headroom over twice that limit, where RabbitMQDiskNearAlarm fires.
        smallVolume = kix.parseQuantity "storage" config.storage.size < 5 * 1000 * 1000 * 1000;

        # Read only when the scope has an enforcer (kix.operandPolicy).
        netpol = scope.networkPolicyEnforcer.netpol;
        tcp = port: {
          inherit port;
          protocol = "TCP";
        };
        peerPorts = map tcp [
          epmdPort
          distributionPort
        ];
        operatorPorts = [ (tcp managementPort) ];
        operatorNamespace = (scope.forService rabbitmqOperator).namespaceName;
      in
      {
        cluster =
          lib.warnIf smallVolume
            "${who}: storage.size is ${toString config.storage.size}, under 5GB. The operator sets RabbitMQ's disk_free_limit to 2GB, so RabbitMQDiskNearAlarm can fire on this volume while the cluster is idle, and a volume of 2GB or less starts in the free disk alarm, which blocks every publisher. Use at least 5Gi."
            (
              scope.mkCR operator.crds.RabbitmqCluster {
                inherit name spec;
                annotations."rabbitmq.com/disable-default-topology-spread-constraints" = "true";
              }
            );

        client = scope.mkServiceRef {
          inherit name;
          selector = operandSelector;
          ports = [ (tcp amqpPort) ];
          requires = [ self.cluster ];
        };

        defaultUser = scope.mkSecretRef {
          name = "${name}-default-user";
          keys = [
            "username"
            "password"
          ];
          requires = [ self.cluster ];
        };

        # The operator renders no PodDisruptionBudget, and the availability
        # plugin derives one only for workloads Kix renders.
        podDisruptionBudget =
          if config.replicas > 1 then
            scope.mkResource {
              apiVersion = "policy/v1";
              kind = "PodDisruptionBudget";
              inherit name;
              annotations.${kix.keys.operandOf} = "rabbitmq.com/RabbitmqCluster/${self.cluster.out.name}";
              spec = {
                maxUnavailable = 1;
                selector.matchLabels = operandSelector;
              };
            }
          else
            null;

        podMonitor =
          if config.metrics.enabled && prometheus != null then
            prometheus.out.mkPodMonitor scope {
              name = podMonitorName;
              spec = {
                selector.matchLabels = operandSelector;
                podMetricsEndpoints = [
                  (
                    {
                      # RabbitMQ's Prometheus plugin (port name `prometheus`).
                      # The scrape egress rule needs the number, because Kix
                      # does not see the operator's pods.
                      portNumber = prometheusPort;
                    }
                    // lib.optionalAttrs (config.metrics.interval != null) { inherit (config.metrics) interval; }
                  )
                ];
              };
              requires = [ self.cluster ];
            }
          else
            null;

        # The operator creates these pods, so no policy is derived for them.
        operandEgress = kix.operandPolicy {
          inherit scope;
          name = "${name}-operand-egress";
          spec = {
            endpointSelector.matchLabels = operandSelector;
            egress = [
              netpol.dnsEgressRule
            ]
            ++ lib.optional peerDiscoveryApi netpol.apiServerEgressRule
            ++ [
              (netpol.mkServiceEgressRule {
                selector = operandSelector;
                namespace = ns;
                sourceNamespace = ns;
                ports = peerPorts;
              })
            ];
          };
        };
        operandIngress = kix.operandPolicy {
          inherit scope;
          name = "${name}-operand-ingress";
          spec = {
            endpointSelector.matchLabels = operandSelector;
            ingress = [
              (netpol.mkCallerIngressRule {
                callerSelector = operandSelector;
                callerNamespace = ns;
                ports = peerPorts;
              })
              (netpol.mkCallerIngressRule {
                callerSelector = operator.podSelector;
                callerNamespace = operatorNamespace;
                ports = operatorPorts;
              })
            ];
          };
        };
        # The other end of the operator rule, in the operator's namespace.
        operatorEgress = kix.operandPolicy {
          scope = scope.forService rabbitmqOperator;
          name = "${ns}-${name}-operator-egress";
          spec = {
            endpointSelector.matchLabels = operator.podSelector;
            egress = [
              (netpol.mkServiceEgressRule {
                selector = operandSelector;
                namespace = ns;
                sourceNamespace = operatorNamespace;
                ports = operatorPorts;
              })
            ];
          };
        };

        root = {
          resource = self.cluster;
          requires = [
            self.client
            self.defaultUser
          ]
          ++ builtins.filter (r: r != null) [
            self.podDisruptionBudget
            self.podMonitor
            self.operandEgress
            self.operandIngress
            self.operatorEgress
            self.prometheusRules
          ];
          out = {
            host = self.client.out.fqdn;
            inherit (self.client.out) port;
            vhost = if config.settings ? default_vhost then renderValue config.settings.default_vhost else "/";
            credentials = self.defaultUser;
            extraImages = [ (kix.image.ref config.image) ];
          };
        };
      }
    )

    # DI passes a build function only the arguments its formals name, so
    # this one names those kix.alerts reads.
    (
      {
        config,
        scope,
        prometheus ? null,
        ...
      }@args:
      let
        sel = ''namespace="${ns}",job="${ns}/${podMonitorName}"'';
        cluster = "RabbitMQ cluster ${ns}/${name}";
        majority = config.replicas / 2 + 1;
        # The alarm collector omits both alarm series from a scrape in which
        # reading the node's alarms times out. The two-minute window bridges
        # one such scrape, and RabbitMQAlarmMetricsMissing reports a node
        # where it keeps happening.
        alarm = metric: "max by (namespace, job, pod) (max_over_time(${metric}{${sel}}[2m])) > 0";
      in
      kix.alerts {
        alerts = {
          RabbitMQDown = {
            expr = "sum by (namespace, job) (up{${sel}}) == 0 or absent(up{${sel}})";
            "for" = "10m";
            severity = "critical";
            summary = "A RabbitMQ cluster has no node answering.";
            description = "No node of ${cluster} has answered a scrape for 10 minutes, so clients cannot connect. Check kubectl get rabbitmqcluster ${name} -n ${ns} and the pods of the StatefulSet ${name}-server.";
          };
          # A memory alarm on one node blocks publishing connections on every
          # node until it clears (https://www.rabbitmq.com/docs/alarms).
          RabbitMQMemoryAlarm = {
            expr = alarm "rabbitmq_alarms_memory_used_watermark";
            "for" = "5m";
            keep_firing_for = "5m";
            severity = "critical";
            summary = "A RabbitMQ memory alarm blocks publishers.";
            description = "Node {{ $labels.pod }} of ${cluster} is over its memory high watermark, so the cluster blocks every publishing connection. Restarting the node does not fix it. Check `rabbitmq-diagnostics memory_breakdown` on the node, and queues that grow because consumers are slow or missing.";
          };
          RabbitMQDiskAlarm = {
            expr = alarm "rabbitmq_alarms_free_disk_space_watermark";
            "for" = "5m";
            keep_firing_for = "5m";
            severity = "critical";
            summary = "A RabbitMQ free disk alarm blocks publishers.";
            description = "Node {{ $labels.pod }} of ${cluster} has less free disk than its free disk limit, so the cluster blocks every publishing connection. Drain the queues that hold the messages, or grow the node's volume.";
          };
          # rabbitmq_resident_memory_limit_bytes is the memory high
          # watermark, which the operator computes from the memory limit.
          RabbitMQMemoryNearWatermark = {
            expr = "max by (namespace, job, pod) (rabbitmq_process_resident_memory_bytes{${sel}} / rabbitmq_resident_memory_limit_bytes{${sel}}) > 0.9";
            "for" = "15m";
            severity = "warning";
            summary = "A RabbitMQ node is close to its memory alarm.";
            description = "Node {{ $labels.pod }} of ${cluster} uses {{ $value | humanizePercentage }} of its memory high watermark. At the watermark the cluster blocks every publisher. Check `rabbitmq-diagnostics memory_breakdown` and the queues that grow.";
          };
          RabbitMQDiskNearAlarm = {
            expr = "min by (namespace, job, pod) (rabbitmq_disk_space_available_bytes{${sel}}) < 2 * max by (namespace, job, pod) (rabbitmq_disk_space_available_limit_bytes{${sel}})";
            "for" = "15m";
            severity = "warning";
            summary = "A RabbitMQ node is close to its free disk alarm.";
            description = "Node {{ $labels.pod }} of ${cluster} has {{ $value | humanize }}B of disk free, under twice its free disk limit. At the limit the cluster blocks every publisher. Drain the queues that hold the messages, or grow the volumes (storage.size).";
          };
          RabbitMQFileDescriptorsNearLimit = {
            expr = "max by (namespace, job, pod) (rabbitmq_process_open_fds{${sel}} / rabbitmq_process_max_fds{${sel}}) > 0.8";
            "for" = "15m";
            severity = "warning";
            summary = "A RabbitMQ node is close to its file descriptor limit.";
            description = "Node {{ $labels.pod }} of ${cluster} uses {{ $value | humanizePercentage }} of its file descriptors. When none is left it refuses new connections. Look for clients that open a connection per message or never close them.";
          };
          RabbitMQAlarmMetricsMissing = {
            expr = "count by (namespace, job, pod) (up{${sel}} == 1) unless on (namespace, job, pod) count by (namespace, job, pod) (rabbitmq_alarms_memory_used_watermark{${sel}})";
            "for" = "15m";
            severity = "warning";
            summary = "A RabbitMQ node reports no alarm metrics.";
            description = "Node {{ $labels.pod }} of ${cluster} is scraped but reports no alarm metrics, so the memory and disk alarm alerts cannot fire for it. Its log shows `alarm_metrics_collector failed to emit metrics` when reading the alarms times out, which happens on an overloaded node.";
          };
        }
        // lib.optionalAttrs (config.replicas > 1) {
          # A missing pod has no `up` series, so the count compares with the
          # configured replicas. With every node down, the count is empty
          # and RabbitMQDown fires instead.
          RabbitMQQuorumLost = {
            expr = "count by (namespace, job) (up{${sel}} == 1) < ${toString majority}";
            "for" = "5m";
            severity = "critical";
            summary = "A RabbitMQ cluster has lost its majority.";
            description = "{{ $value }} of the ${toString config.replicas} nodes of ${cluster} answer, fewer than the ${toString majority} a majority needs. Quorum queues and the metadata store stop accepting writes until enough nodes return. Check the pods of the StatefulSet ${name}-server.";
          };
          # Each node reports one erlang_vm_dist_node_state series per peer
          # it is connected to, 3 while the link is up. CLI tools connect
          # as temporary nodes not named rabbit@, so the peer filter leaves
          # them out. A node with no link reports none, and the `or` branch
          # gives it a count of 0.
          RabbitMQDistributionLinksMissing = {
            expr = "(count by (namespace, job, pod) (erlang_vm_dist_node_state{${sel},peer=~\"rabbit@.+\"} == 3) or on (namespace, job, pod) count by (namespace, job, pod) (up{${sel}} == 1) * 0) < ${toString (config.replicas - 1)}";
            "for" = "10m";
            severity = "warning";
            summary = "A RabbitMQ node is not connected to every other node.";
            description = "Node {{ $labels.pod }} of ${cluster} has {{ $value }} of its ${toString (config.replicas - 1)} links to the other nodes up for 10 minutes. A node cut off from its peers can be partitioned from the cluster; quorum queues on it lose their replicas. Check `rabbitmq-diagnostics cluster_status` on that node and the network between the pods on port ${toString distributionPort}.";
          };
          # Every node of one cluster reads the ID from the replicated
          # metadata store (rabbit_nodes:persistent_cluster_id/0), so two IDs
          # mean a node formed or joined another cluster.
          RabbitMQClusterIdentityMismatch = {
            expr = "count by (namespace, job) (count by (namespace, job, rabbitmq_cluster_permanent_id) (rabbitmq_identity_info{${sel}})) > 1";
            "for" = "10m";
            severity = "critical";
            summary = "The nodes of a RabbitMQ cluster report different cluster IDs.";
            description = "The nodes of ${cluster} report {{ $value }} cluster IDs, so at least one node runs as a separate cluster and clients that reach it see other queues and messages. Compare `rabbitmq-diagnostics cluster_status` on each node.";
          };
        };
      } args
    )
  ];
}

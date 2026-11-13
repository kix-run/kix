# ClickHouse, replicated, run by the Altinity operator.
#
# The second implementation behind the `clickhouse` alias. It exposes the
# same `out` as the bare `clickhouse` package, so `clickhouse-database` and
# everything built on it run against either, and a cluster definition
# chooses. One shard, `replicas` replicas: more shards would change how
# consumers have to write (Distributed tables) and break that promise.
#
# One ClickHouseInstallation CR, built through the operator package's
# builder. The operator creates a StatefulSet per replica, the Services,
# the macros and remote_servers that make `ON CLUSTER '{cluster}'` work,
# and a PodDisruptionBudget. The scorecard cannot see any of those pods,
# so the availability posture is this package's default and not a rule's
# reminder: two replicas, spread over nodes by the operator's
# ClickHouseAntiAffinity.
#
# The operator's Service (`clickhouse-<name>`) is described with a
# ServiceRef, so the addresses on `out` carry dependency context and the
# endpoint fact. The Keeper address goes into the CR spec as a value from
# `clickhouseKeeper.out.host`, and the CRD's factBehavior (terminate, with
# the operand pod selector) turns that into the servers' egress to Keeper.
#
# Three flows have no address to ride on, because both ends are pods no
# build knows about: replica to replica, and the operator (with its metrics
# exporter) to every replica on 8123. The package states them as policies
# over the operator's pod labels.
#
# Upgrades: stay on an LTS line (the March and August releases), and upgrade
# to a new version only after it has had a few weeks of fixes. The operator
# restarts one replica at a time on an image change. Run no DDL until every
# replica reports the new version, and use no new feature until then
# either. Keep clickhouse-keeper on the same LTS line as the servers.
#
# Object storage is not modelled. A serverConfig that adds an S3 disk, and
# especially one that turns on allow_remote_fs_zero_copy_replication (off
# by default), is at the cluster's own risk: zero-copy replication has a
# history of data loss and of orphaned objects left in the bucket.
#
# Not carried over from the bare package: the Keeper digest identity. The
# CR has no way to take it from a Secret, so on this path Keeper's
# protection is network policy (only these servers may reach it).
#
# Dependencies:
#   clickhouseOperator (required)  the CRD, out.mkClickHouseInstallation,
#                                  out.podSelector
#   clickhouseKeeper (required)    the coordination quorum
#   credentials (required)         secret or secret-ref with a `password`
#                                  key, for the `default` user
#   storageClasses (optional)      storageClassName when the option is unset
#   prometheus (optional)          a PodMonitor on every replica's built-in
#                                  /metrics endpoint (:9363), and the alerts
#                                  below. Removing the `prometheus`
#                                  fragment drops both.
#
# Alerts (../clickhouse/alerts.nix, shared with the bare package): the bare
# package's list, per replica where it names a pod, plus two that need a
# second replica and render only with `replicas` above 1:
#   ClickHouseReplicationLag            ReplicasMaxAbsoluteDelay over
#                                       metrics.maxReplicationLag (warning)
#   ClickHouseReplicatedFetchesFailing  part fetches failing for 15 minutes
#                                       (warning)
# ClickHouseKeeperSessionLost here means the clickhouse-keeper quorum is
# unreachable. ClickHouseDown fires only when no replica is scraped; one
# replica down is TargetDown and KubeStatefulSetReplicasMismatch from the
# kube-prometheus rules. The operator's metrics exporter scrapes the same
# servers under other names (chi_clickhouse_*); no rule reads those.
#
# Exposes the clickhouse contract (`kix.contracts.experimental.clickhouse`, which checks
# it). `out.replicas` is the `replicas` option, and `out.replicaHosts` the
# operator's per-replica Services, replica 0 first.
#
# root = the ServiceRef.

{
  scope,
  lib,
  kix,
}:
let
  # ClickHouse versions have four parts, and the image tag is the version.
  release = "26.3.33.24";

  name = scope.instanceName;
  passwordKey = "password";
  ports = {
    http = 8123;
    native = 9000;
    metrics = 9363;
  };
  contract = kix.contracts.experimental.clickhouse;
  # The PodMonitor's name, which the alert selector's `job` label carries.
  podMonitorName = name;

  # Return true unless a null `prometheus` fragment or a null
  # `prometheus.prometheus` key removes the metrics endpoint.
  metricsEndpointOn =
    serverConfig:
    let
      f = serverConfig.prometheus or { };
    in
    f != null && (f.prometheus or { }) != null;
in
{
  meta = {
    version = release;
    description = "Replicated ClickHouse via a ClickHouseInstallation CR";
    lifecycle = "stateful";
    defaultAliases = [ "clickhouse" ];
    k8s.minVersion = "1.25";
  };

  deps = {
    credentials.assertions =
      dep:
      lib.optional (!(builtins.elem passwordKey (dep.out.keys or [ ]))) {
        assertion = false;
        message = "clickhouse-cluster reads the default user's password from the `${passwordKey}` key of its credentials secret, and the resolved secret declares: ${
          lib.concatStringsSep ", " (dep.out.keys or [ ])
        }. Add `${passwordKey}` to that instance's keys.";
      };
  };

  options = {
    image = kix.options.image {
      repository = "docker.io/clickhouse/clickhouse-server";
      tag = release;
      digest = "sha256:810861a2e2d0188744f5f23b2d3ec9ff95812bcb9ddbb8fed13a377a7f305893";
    };

    clusterName = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z_][A-Za-z0-9_]*";
      default = "default";
      description = "Name of the cluster the installation defines, and the value of the `{cluster}` macro.";
    };

    replicas = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Replicas of the single shard. Two or more to survive the loss of a node.";
    };

    storage = {
      size = lib.mkOption {
        type = lib.types.str;
        default = "50Gi";
        description = "Data volume per replica.";
      };
      storageClassName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "StorageClass for the volumes. Null takes it from the storageClasses dep, or the cluster default.";
      };
    };

    resources = kix.options.resources {
      requests = {
        cpu = "500m";
        memory = "2Gi";
      };
      limits = {
        cpu = "2";
        memory = "2Gi";
      };
      description = "Per replica. ClickHouse sizes itself from these limits; the memory limit is required and 2Gi is a floor (see the clickhouse package).";
    };

    serverConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = ''
        Server configuration fragments in ClickHouse's own vocabulary, as in
        the clickhouse package: each attribute becomes config.d/<name>.yaml
        on every replica, merged over the package's own (logging,
        prometheus, system-logs). Null removes.
      '';
    };

    extraSpec = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Merged over the ClickHouseInstallation spec the package builds.";
    };

    metrics = kix.options.monitor // {
      maxReplicationLag = lib.mkOption {
        type = lib.types.ints.positive;
        default = 300;
        description = "Seconds a replica may lag behind the newest part of a replicated table (ReplicasMaxAbsoluteDelay) for 15 minutes before ClickHouseReplicationLag fires. The default is the threshold of the Altinity operator's sample rules.";
      };
    };

    healthCheck = kix.options.healthCheck // {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run the post-deploy probe, the same one as the clickhouse package plus a replica count. It asks each replica for read-only tables through the replica's own Service.";
      };
      # A first install pulls images and forms two quorums.
      retryFor = lib.mkOption {
        type = lib.types.int;
        default = 300;
        description = "Seconds the probe keeps re-checking before it gives up.";
      };
    };
  };

  build = [
    (
      {
        self,
        config,
        scope,
        kix,
        clickhouseOperator,
        clickhouseKeeper,
        credentials,
        storageClasses ? null,
        prometheus ? null,
        ...
      }:
      let
        # Consumers check the server's version, so a tag that names none is
        # refused here with the option to change.
        serverVersion =
          let
            v = kix.image.version config.image;
          in
          if v == null then
            scope.fail {
              package = "clickhouse-cluster";
              option = "config.image.tag";
              message = "image.tag \"${builtins.unsafeDiscardStringContext config.image.tag}\" names no ClickHouse version. Packages that use this server check its version.";
              fix = "Set config.image.tag to a tag that starts with the version, such as \"${release}\".";
            }
          else
            v;
        # What the operator stamps on every pod of this installation.
        podSelector = clickhouseOperator.out.operandSelector.clickHouseInstallations name;

        # Trim a name segment for the operator's per-replica Service name,
        # chi-{chi}-{cluster}-{shard}-{replica} with zero-based indexes
        # (patterns.go in operator 0.27.3). It cuts the installation name to
        # 60 characters and the cluster name to 15, then trims "-", "_", and
        # "." from both ends of each. A serviceTemplate could rename it, so
        # extraSpec may not define one.
        operatorNamePart =
          length: s:
          let
            m = builtins.match "[-_.]*(.*[^-_.])?[-_.]*" (builtins.substring 0 length s);
          in
          if m == null || builtins.head m == null then "" else builtins.head m;
        replicaServiceName =
          replica:
          "chi-${operatorNamePart 60 name}-${operatorNamePart 15 config.clusterName}-0-${toString replica}";
        replicaIndexes = lib.range 0 (config.replicas - 1);

        storageClassName =
          if config.storage.storageClassName != null then
            config.storage.storageClassName
          else if storageClasses != null then
            storageClasses.out.storageClassName or null
          else
            null;

        # The lessons of the bare package that the operator's own fragments
        # do not cover: the shipped console log level is trace, most system
        # log tables have no TTL (the operator already gives query_log,
        # part_log, and trace_log one), and the metrics endpoint is off.
        builtinServerConfig = {
          logging.logger.level = "information";
          # The same endpoint as the bare package, so both share one metric
          # vocabulary and ../clickhouse/alerts.nix.
          prometheus.prometheus = {
            endpoint = "/metrics";
            port = ports.metrics;
            metrics = true;
            events = true;
            asynchronous_metrics = true;
            status_info = true;
          };
          system-logs =
            lib.genAttrs
              [
                "asynchronous_metric_log"
                "error_log"
                "metric_log"
                "query_metric_log"
                "query_views_log"
                "text_log"
              ]
              (_: {
                ttl = "event_date + INTERVAL 30 DAY DELETE";
              });
        };
        fragments = lib.filterAttrsRecursive (_: v: v != null) (
          lib.recursiveUpdate builtinServerConfig config.serverConfig
        );

        baseSpec = {
          configuration = {
            clusters = [
              {
                name = config.clusterName;
                layout = {
                  shardsCount = 1;
                  replicasCount = config.replicas;
                };
              }
            ];
            zookeeper.nodes = [
              {
                host = clickhouseKeeper.out.host;
                port = lib.toInt clickhouseKeeper.out.port;
              }
            ];
            users = {
              "default/password".valueFrom.secretKeyRef = {
                name = credentials.out.name;
                key = passwordKey;
              };
              # The operator restricts `default` to the installation's own
              # hosts. Consumers are other pods, so the password and network
              # policy are the boundary, as in the bare package.
              "default/networks/ip" = [ "::/0" ];
              # SQL-driven users and grants, which clickhouse-database uses.
              "default/access_management" = 1;
            };
            files = lib.mapAttrs' (
              fragment: value: lib.nameValuePair "config.d/kix-${fragment}.yaml" (builtins.toJSON value)
            ) fragments;
          };
          defaults.templates = {
            podTemplate = "server";
            dataVolumeClaimTemplate = "data";
          };
          templates = {
            podTemplates = [
              {
                name = "server";
                podDistribution = [
                  {
                    type = "ClickHouseAntiAffinity";
                    scope = "ClickHouseInstallation";
                  }
                ];
                spec.containers = [
                  {
                    name = "clickhouse";
                    image = kix.image.ref config.image;
                    imagePullPolicy = config.image.pullPolicy;
                    inherit (config) resources;
                  }
                ];
              }
            ];
            volumeClaimTemplates = [
              {
                name = "data";
                spec = {
                  accessModes = [ "ReadWriteOnce" ];
                  resources.requests.storage = config.storage.size;
                }
                // lib.optionalAttrs (storageClassName != null) { inherit storageClassName; };
              }
            ];
          };
        };

        netpol = if scope.networkPolicyEnforcer == null then null else scope.networkPolicyEnforcer.netpol;
        operatorScope = scope.forService clickhouseOperator;
        operatorNamespace = operatorScope.namespaceName;
        httpOnly = [
          {
            ports = [
              {
                port = toString ports.http;
                protocol = "TCP";
              }
            ];
          }
        ];
      in
      if (config.resources.limits.memory or null) == null then
        scope.fail {
          package = "clickhouse-cluster";
          option = "config.resources.limits.memory";
          message = "resources.limits.memory is unset. ClickHouse sizes its memory cap from the container limit and falls back to the node's RAM without one.";
          fix = "Set config.resources.limits.memory.";
        }
      else
        {
          installation = clickhouseOperator.out.mkClickHouseInstallation scope {
            inherit name;
            spec = kix.mergeGuarded {
              who = "clickhouse-cluster (${name})";
              # The Keeper address carries the netpol edge, the password
              # is the credentials dep, the users' network and
              # access_management are what lets clickhouse-database in,
              # and the rest have an option of their own.
              locked = [
                [
                  "configuration"
                  "zookeeper"
                ]
                [
                  "configuration"
                  "clusters"
                ]
                [
                  "configuration"
                  "files"
                ]
                [
                  "configuration"
                  "users"
                  "default/password"
                ]
                [
                  "configuration"
                  "users"
                  "default/networks/ip"
                ]
                [
                  "configuration"
                  "users"
                  "default/access_management"
                ]
                [
                  "templates"
                  "podTemplates"
                ]
                [
                  "templates"
                  "volumeClaimTemplates"
                ]
                [
                  "templates"
                  "serviceTemplates"
                ]
              ];
            } baseSpec config.extraSpec;
          };

          service = scope.mkServiceRef {
            name = "clickhouse-${name}";
            selector = podSelector;
            ports = [
              {
                name = "http";
                port = ports.http;
                protocol = "TCP";
              }
              {
                name = "tcp";
                port = ports.native;
                protocol = "TCP";
              }
            ];
            requires = [ self.installation ];
          };

          podMonitor =
            if config.metrics.enabled && prometheus != null && metricsEndpointOn config.serverConfig then
              prometheus.out.mkPodMonitor scope {
                name = podMonitorName;
                spec = {
                  selector.matchLabels = podSelector;
                  podMetricsEndpoints = [
                    (
                      {
                        # The operator's pod template declares no port for
                        # the endpoint, and the scrape egress rule needs a
                        # number.
                        portNumber = ports.metrics;
                      }
                      // lib.optionalAttrs (config.metrics.interval != null) { inherit (config.metrics) interval; }
                    )
                  ];
                };
                requires = [ self.installation ];
              }
            else
              null;

          # The health check asks every replica whether it has read-only
          # tables, which a query through the load-balanced Service cannot.
          replicaServices = map (
            replica:
            scope.mkServiceRef {
              name = replicaServiceName replica;
              # The replica's name is its index, as a label value too.
              selector = podSelector // {
                "clickhouse.altinity.com/replica" = toString replica;
              };
              ports = [
                {
                  name = "http";
                  port = ports.http;
                  protocol = "TCP";
                }
              ];
              requires = [ self.installation ];
            }
          ) replicaIndexes;

          # Replica to replica: fetches (9009), distributed DDL and queries
          # (9000), and name resolution for them.
          replicaEgress = kix.operandPolicy {
            inherit scope;
            name = "${name}-replicas-egress";
            spec = {
              endpointSelector.matchLabels = podSelector;
              egress = [
                netpol.dnsEgressRule
                { toEndpoints = [ { matchLabels = podSelector; } ]; }
              ];
            };
          };
          replicaIngress = kix.operandPolicy {
            inherit scope;
            name = "${name}-replicas-ingress";
            spec = {
              endpointSelector.matchLabels = podSelector;
              ingress = [
                { fromEndpoints = [ { matchLabels = podSelector; } ]; }
                # The operator propagates schema to a new replica and its
                # exporter reads metrics, both over HTTP.
                {
                  fromEndpoints = [
                    {
                      matchLabels = clickhouseOperator.out.podSelector // {
                        "k8s:io.kubernetes.pod.namespace" = operatorNamespace;
                      };
                    }
                  ];
                  toPorts = httpOnly;
                }
              ];
            };
          };
          # The other end of that second rule, in the operator's namespace.
          operatorEgress = kix.operandPolicy {
            scope = operatorScope;
            name = "${scope.namespaceName}-${name}-operator-egress";
            spec = {
              endpointSelector.matchLabels = clickhouseOperator.out.podSelector;
              egress = [
                {
                  toEndpoints = [
                    {
                      matchLabels = podSelector // {
                        "k8s:io.kubernetes.pod.namespace" = scope.namespaceName;
                      };
                    }
                  ];
                  toPorts = httpOnly;
                }
              ];
            };
          };

          root = {
            resource = self.service;
            requires = [
              self.installation
            ]
            ++ builtins.filter (p: p != null) [
              self.replicaEgress
              self.replicaIngress
              self.operatorEgress
            ];
            out = contract.check "clickhouse-cluster (${name})" {
              httpUrl = "http://${self.service.out.fqdn}:${toString ports.http}";
              nativeEndpoint = "${self.service.out.fqdn}:${toString ports.native}";
              host = self.service.out.fqdn;
              ports = {
                http = toString ports.http;
                native = toString ports.native;
              };
              username = "default";
              inherit credentials;
              inherit (config) clusterName;
              version = serverVersion;
              replicas = toString config.replicas;
              replicaHosts = map (svc: svc.out.fqdn) self.replicaServices;
              extraImages = [ (kix.image.ref config.image) ];
            };
          };
        }
    )

    # kix.alerts reads `scope` and `prometheus` from the arguments it is
    # called with, so the wrapper names them for the build to pass. Without
    # the metrics endpoint it gets no `prometheus`, which drops the rules.
    # The package's own fragments set none of the keys alerts.nix reads, so
    # it is given the instance's serverConfig alone.
    (
      {
        config,
        scope,
        prometheus ? null,
        ...
      }@args:
      kix.alerts {
        alerts = import ../clickhouse/alerts.nix { inherit lib kix; } {
          sel = ''namespace="${scope.namespaceName}",job="${scope.namespaceName}/${podMonitorName}"'';
          by = "namespace, job";
          instance = "${scope.namespaceName}/${name}";
          memoryLimit = config.resources.limits.memory or null;
          fragments = config.serverConfig;
          # One replica has no peer to lag behind or fetch from.
          maxReplicationLag = if config.replicas > 1 then config.metrics.maxReplicationLag else null;
        };
      } (args // lib.optionalAttrs (!metricsEndpointOn config.serverConfig) { prometheus = null; })
    )

    (kix.healthCheck {
      env =
        { self, ... }:
        {
          CLICKHOUSE_URL = self.root.out.httpUrl;
          CLICKHOUSE_USER = self.root.out.username;
          CLICKHOUSE_PASSWORD = self.root.out.credentials.out.keyRef "password";
          CLICKHOUSE_CLUSTER = self.root.out.clusterName;
          CLICKHOUSE_REPLICAS = self.root.out.replicas;
          CLICKHOUSE_REPLICA_URLS = lib.concatMapStringsSep " " (
            svc: "http://${svc.out.fqdn}:${svc.out.port}"
          ) self.replicaServices;
        };
      # One probe for both implementations of the contract.
      script = builtins.readFile ../clickhouse/health-check.py;
    })
  ];
}

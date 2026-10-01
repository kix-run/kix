# ClickHouse, replicated, run by the Altinity operator
# (v2_discussions/148, phase 5).
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
# over the operator's pod labels, the stackgres-cluster precedent. They are
# what phase 5's default-deny test on kind exercises.
#
# Not carried over from the bare package: the Keeper digest identity. The
# CR has no way to take it from a Secret, so on this path Keeper's
# protection is network policy (only these servers may reach it).
#
# DI deps:
#   clickhouseOperator (required)  the CRD, out.mkClickHouseInstallation,
#                                  out.podSelector
#   clickhouseKeeper (required)    the coordination quorum
#   credentials (required)         secret or secret-ref with a `password`
#                                  key, for the `default` user
#   storageClasses (optional)      storageClassName when the option is unset
#
# Exposes the clickhouse contract (../clickhouse/contract.nix, which checks
# it), plus out.replicas.
#
# root = the ServiceRef.

{
  scope,
  lib,
  kix,
}:
let
  name = scope.instanceName;
  passwordKey = "password";
  ports = {
    http = 8123;
    native = 9000;
  };
  contract = import ../clickhouse/contract.nix { inherit lib; };
in
{
  meta = {
    version = "26.3.33";
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
      tag = "26.3.33.24";
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
      description = "Per replica. ClickHouse sizes itself from these limits; 2Gi of memory is a floor (see the clickhouse package).";
    };

    serverConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = ''
        Server configuration fragments in ClickHouse's own vocabulary, as in
        the clickhouse package: each attribute becomes config.d/<name>.yaml
        on every replica, merged over the package's own (logging,
        system-logs). Null removes.
      '';
    };

    extraSpec = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Merged over the ClickHouseInstallation spec the package builds.";
    };

    healthCheck = kix.options.healthCheck // {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run the post-deploy probe, the same one as the clickhouse package plus a replica count.";
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
        ...
      }:
      let
        # What the operator stamps on every pod of this installation.
        podSelector = clickhouseOperator.out.operandSelector.clickHouseInstallations name;

        storageClassName =
          if config.storage.storageClassName != null then
            config.storage.storageClassName
          else if storageClasses != null then
            storageClasses.out.storageClassName or null
          else
            null;

        # The two lessons of the bare package that the operator's own
        # fragments do not cover: the shipped console log level is trace,
        # and most system log tables have no TTL. The operator already
        # gives query_log, part_log and trace_log one.
        builtinServerConfig = {
          logging.logger.level = "information";
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
            authSecret = credentials;
            authPasswordKey = passwordKey;
            inherit (config) clusterName;
            version = lib.versions.majorMinor config.image.tag;
            replicas = toString config.replicas;
            extraImages = [ (kix.image.ref config.image) ];
          };
        };
      }
    )

    (kix.healthCheck {
      env =
        { self, ... }:
        {
          CLICKHOUSE_URL = self.root.out.httpUrl;
          CLICKHOUSE_USER = self.root.out.username;
          CLICKHOUSE_PASSWORD = self.root.out.authSecret.out.keyRef self.root.out.authPasswordKey;
          CLICKHOUSE_CLUSTER = self.root.out.clusterName;
          CLICKHOUSE_REPLICAS = self.root.out.replicas;
        };
      # One probe for both implementations of the contract.
      script = builtins.readFile ../clickhouse/health-check.py;
    })
  ];
}

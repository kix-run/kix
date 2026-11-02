# ClickHouse Keeper, a quorum run by the Altinity operator.
#
# One ClickHouseKeeperInstallation CR, built through the operator package's
# builder. The operator turns it into one StatefulSet per replica, the
# Services between them, and a PodDisruptionBudget. Three replicas is the
# default and the smallest quorum that survives losing one; the scorecard
# cannot see operator-created pods, so high availability has to be the
# default here and not something a rule reminds you of.
#
# The Service the operator creates (`keeper-<name>`) is described with a
# ServiceRef, not rendered a second time, so `out.host` carries dependency
# context and the endpoint fact: a ClickHouseInstallation that puts it in
# its spec waits for the quorum and gets the network policy edge.
#
# Traffic between the replicas (raft) runs between pods that no build
# knows about, so no address can carry that edge. The package states it as
# a policy over the operator's pod labels.
#
# Each replica serves Prometheus metrics on TCP 7000 (`/metrics`), set
# through the CHK's `prometheus/*` settings.
#
# Dependencies:
#   clickhouseOperator (required)  the CRD and out.mkKeeperInstallation
#   storageClasses (optional)      storageClassName when the option is
#                                  unset; absent means the cluster default
#   prometheus (optional)          a PodMonitor on every replica's metrics
#                                  endpoint, and the alerts below, while
#                                  `metrics.enabled`
#
# Alerts: a PrometheusRule `<instance>-alerts` selects the PodMonitor's
# series (`job` is `<namespace>/<instance>`).
#   ClickHouseKeeperDown (critical)                no replica answers a
#                                                  scrape. Replicated tables
#                                                  on the servers go
#                                                  read-only.
#   ClickHouseKeeperQuorumLost (critical)          replicas answer but none
#                                                  is the leader, or the
#                                                  leader has too few
#                                                  in-sync followers for a
#                                                  majority, so the quorum
#                                                  takes no writes.
#   ClickHouseKeeperFollowersNotSynced (warning)   the leader has fewer
#                                                  in-sync followers than
#                                                  `replicas - 1`; renders
#                                                  only with `replicas`
#                                                  above 1.
#   ClickHouseKeeperMemorySoftLimit (warning)      a replica is over its
#                                                  memory soft limit and
#                                                  refuses requests that
#                                                  would grow it.
# One replica down while the quorum holds is left to TargetDown and
# KubeStatefulSetReplicasMismatch in prometheus-default-rules, a full volume
# to KubePersistentVolumeFillingUp, and the servers' view of Keeper to
# clickhouse-cluster's ClickHouseKeeperSessionLost.
#
# Upgrades: a version of this package that adds the metrics endpoint
# changes the CHK's settings, so the operator restarts each replica once.
#
# `out`:
#   out.host    "keeper-<name>.<ns>.svc..." (the operator's Service)
#   out.port    "2181"
#
# root = the ServiceRef.

{
  scope,
  lib,
  kix,
}:
let
  name = scope.instanceName;
  clientPort = 2181;
  metricsPort = 7000;
  # The PodMonitor's name, which the alert selector's `job` label carries.
  podMonitorName = name;
in
{
  meta = {
    version = "26.3.32";
    description = "ClickHouse Keeper quorum via a ClickHouseKeeperInstallation CR";
    lifecycle = "stateful";
    defaultAliases = [ "clickhouseKeeper" ];
    k8s.minVersion = "1.25";
  };

  options = {
    image = kix.options.image {
      repository = "docker.io/clickhouse/clickhouse-keeper";
      tag = "26.3.32.14";
      digest = "sha256:8dd3ed81719ae9467ad659d86b7af53a9ec5be6b50320f9ca84cf9c31dc7ccc8";
    };

    replicas = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = ''
        Keeper replicas: 1, or an odd number. Three is the smallest quorum
        that survives the loss of one. An even count is refused, since it
        survives no more losses than one fewer replica.
      '';
    };

    storage = {
      size = lib.mkOption {
        type = lib.types.str;
        default = "5Gi";
        description = "Volume per replica for the raft log and snapshots.";
      };
      storageClassName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "StorageClass for the volumes. Null takes it from the storageClasses dep, or the cluster default.";
      };
    };

    resources = kix.options.resources {
      requests = {
        cpu = "100m";
        memory = "256Mi";
      };
      limits = {
        cpu = "1";
        memory = "512Mi";
      };
    };

    extraSpec = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Merged over the ClickHouseKeeperInstallation spec the package builds. The metrics endpoint's `prometheus/port` and `prometheus/endpoint` settings are the package's.";
    };

    metrics = kix.options.monitor;
  };

  build = [
    (
      {
        self,
        config,
        scope,
        kix,
        clickhouseOperator,
        storageClasses ? null,
        prometheus ? null,
        ...
      }:
      let
        # What the operator stamps on every pod of this installation.
        podSelector = clickhouseOperator.out.operandSelector.clickHouseKeeperInstallations name;

        storageClassName =
          if config.storage.storageClassName != null then
            config.storage.storageClassName
          else if storageClasses != null then
            storageClasses.out.storageClassName or null
          else
            null;

        baseSpec = {
          configuration.clusters = [
            {
              name = "keeper";
              layout.replicasCount = config.replicas;
            }
          ];
          # The operator's default Keeper config has no metrics endpoint.
          configuration.settings = {
            "prometheus/endpoint" = "/metrics";
            "prometheus/port" = toString metricsPort;
            "prometheus/metrics" = "true";
            "prometheus/events" = "true";
            "prometheus/asynchronous_metrics" = "true";
          };
          defaults.templates = {
            podTemplate = "keeper";
            dataVolumeClaimTemplate = "data";
          };
          templates = {
            podTemplates = [
              {
                name = "keeper";
                spec = {
                  # One replica per node where there are nodes to spread
                  # over; still schedulable on a single-node cluster.
                  affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution = [
                    {
                      weight = 100;
                      podAffinityTerm = {
                        topologyKey = "kubernetes.io/hostname";
                        labelSelector.matchLabels = podSelector;
                      };
                    }
                  ];
                  containers = [
                    {
                      name = "clickhouse-keeper";
                      image = kix.image.ref config.image;
                      imagePullPolicy = config.image.pullPolicy;
                      inherit (config) resources;
                    }
                  ];
                };
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
        mkOperandPolicy =
          suffix: spec:
          kix.operandPolicy {
            inherit scope;
            name = "${name}-keeper-${suffix}";
            spec = {
              endpointSelector.matchLabels = podSelector;
            }
            // spec;
          };
      in
      # Raft needs a majority. Two replicas stop when either one is lost, and
      # every ReplicatedMergeTree table on the servers goes read-only with them.
      if lib.mod config.replicas 2 == 0 then
        throw "clickhouse-keeper (${name}): replicas is ${toString config.replicas}. A Keeper quorum needs a majority, so an even count survives no more losses than one fewer replica. Set config.replicas to 1 or an odd number (3 survives the loss of one)."
      else
        {
          keeper = clickhouseOperator.out.mkKeeperInstallation scope {
            inherit name;
            spec = kix.mergeGuarded {
              who = "clickhouse-keeper (${name})";
              # The replica count is the quorum, the pod template carries
              # the image and the spread, the volume has its option.
              locked = [
                [
                  "configuration"
                  "clusters"
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
                  "configuration"
                  "settings"
                  "prometheus/port"
                ]
                [
                  "configuration"
                  "settings"
                  "prometheus/endpoint"
                ]
              ];
            } baseSpec config.extraSpec;
          };

          service = scope.mkServiceRef {
            name = "keeper-${name}";
            selector = podSelector;
            ports = [
              {
                name = "zk";
                port = clientPort;
                protocol = "TCP";
              }
            ];
            requires = [ self.keeper ];
          };

          podMonitor =
            if config.metrics.enabled && prometheus != null then
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
                        portNumber = metricsPort;
                        path = "/metrics";
                      }
                      // lib.optionalAttrs (config.metrics.interval != null) { inherit (config.metrics) interval; }
                    )
                  ];
                };
                requires = [ self.keeper ];
              }
            else
              null;

          # Raft between the replicas, and name resolution for it.
          peerEgress = mkOperandPolicy "egress" {
            egress = [
              netpol.dnsEgressRule
              { toEndpoints = [ { matchLabels = podSelector; } ]; }
            ];
          };
          peerIngress = mkOperandPolicy "ingress" {
            ingress = [ { fromEndpoints = [ { matchLabels = podSelector; } ]; } ];
          };

          root = {
            resource = self.service;
            requires = [
              self.keeper
            ]
            ++ builtins.filter (p: p != null) [
              self.peerEgress
              self.peerIngress
              self.podMonitor
            ];
            out = {
              host = self.service.out.fqdn;
              port = toString clientPort;
              extraImages = [ (kix.image.ref config.image) ];
            };
          };
        }
    )

    # kix.alerts reads `scope` and `prometheus` from the arguments it is
    # called with, so the wrapper names them for the build to pass.
    (
      {
        config,
        scope,
        prometheus ? null,
        ...
      }@args:
      let
        ns = scope.namespaceName;
        sel = ''namespace="${ns}",job="${ns}/${podMonitorName}"'';
        keeper = "ClickHouse Keeper ${ns}/${name}";
        replicaCount = toString config.replicas;
      in
      kix.alerts {
        alerts = {
          ClickHouseKeeperDown = {
            expr = "sum by (namespace, job) (up{${sel}}) == 0 or absent(up{${sel}})";
            "for" = "10m";
            severity = "critical";
            summary = "No ClickHouse Keeper replica answers.";
            description = "No replica of ${keeper} has answered a scrape for 10 minutes. ClickHouse servers that use it lose their Keeper session, and their replicated tables go read-only. Check kubectl get chk ${name} -n ${ns} and its pods.";
          };
          # A replica reports every Keeper metric as 0 until its server is
          # active, so the 5m `for` rides out a restart. A one-replica
          # quorum is its own leader and has no followers to lose.
          ClickHouseKeeperQuorumLost = {
            expr =
              "max by (namespace, job) (ClickHouseAsyncMetrics_KeeperIsLeader{${sel}}) == 0"
              +
                lib.optionalString (config.replicas > 1)
                  " or (max by (namespace, job) (ClickHouseAsyncMetrics_KeeperSyncedFollowers{${sel}}) < ${toString (config.replicas / 2)} and on (namespace, job) max by (namespace, job) (ClickHouseAsyncMetrics_KeeperIsLeader{${sel}}) == 1)";
            "for" = "5m";
            severity = "critical";
            summary = "ClickHouse Keeper has lost its quorum.";
            description = "For 5 minutes ${keeper} has had no leader, or a leader with too few in-sync followers for a majority of its ${replicaCount} replicas, so it accepts no writes and replicated tables on the servers go read-only. Check that a majority of its replicas run and reach each other on the raft port, and read their logs.";
          };
          ClickHouseKeeperMemorySoftLimit = {
            expr = "max by (namespace, job, pod) (ClickHouseAsyncMetrics_KeeperIsExceedingMemorySoftLimitHit{${sel}}) == 1";
            "for" = "10m";
            severity = "warning";
            summary = "ClickHouse Keeper is over its memory soft limit.";
            description = "{{ $labels.pod }} of ${keeper} has been over its memory soft limit for 10 minutes, and refuses requests that would grow its memory, such as creating nodes. By default the limit is 90% of the container's memory. Raise resources.limits.memory, or find what fills Keeper with nodes or watches.";
          };
        }
        // lib.optionalAttrs (config.replicas > 1) {
          # Only the leader reports followers; the other replicas report 0.
          ClickHouseKeeperFollowersNotSynced = {
            expr = "max by (namespace, job) (ClickHouseAsyncMetrics_KeeperSyncedFollowers{${sel}}) < ${toString (config.replicas - 1)} and on (namespace, job) max by (namespace, job) (ClickHouseAsyncMetrics_KeeperIsLeader{${sel}}) == 1";
            "for" = "15m";
            severity = "warning";
            summary = "ClickHouse Keeper has followers out of sync.";
            description = "The leader of ${keeper} has had {{ $value }} in-sync followers of ${toString (config.replicas - 1)} for 15 minutes, so the quorum survives fewer replica losses than its ${replicaCount} replicas allow. Check the replicas that are behind or not running.";
          };
        };
      } args
    )
  ];
}

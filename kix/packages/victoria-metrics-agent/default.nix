# victoria-metrics-agent: HA scrape agent (VMAgent CR) feeding a
# victoria-metrics-cluster.
#
# Two identical replicas scrape everything and both remote-write to
# vminsert; the cluster's dedup (calibrated to the same scrapeInterval,
# via vmCluster.out.scrapeInterval) collapses the duplicate samples.
# Sharding (shardCount) is deliberately out of scope until target counts
# demand it.
#
# Watch-everything default: selectAllByDefault = true, so every
# VMServiceScrape / VMPodScrape (and, via the operator's converter,
# every ServiceMonitor / PodMonitor) in the cluster is scraped, matching
# the prometheus package's posture.
#
# Dependencies:
#   vmOperator (required)   provides the VMAgent CRD + mkVMAgent
#   vmCluster (required)    out.remoteWriteUrl (remote-write target),
#                           out.scrapeInterval (dedup coupling)
#
# The remoteWrite URL carries the store-path edge to the cluster's insert
# Service, and the VMAgent CRD's terminate factBehavior points netpol at
# the vmagent operand pods, so the egress hole lands on the pods that
# actually dial vminsert. The netpol scrape join opens the paths to the
# scrape objects the agent selects, the operator's own VMServiceScrapes for
# VictoriaMetrics operands included, and `agentEgress` opens DNS and the
# API server.
#
# Alerts (a VMRule `<instance>-alerts`, which vmalert evaluates and a
# prometheus-operator Prometheus does not load). They render only when the
# `prometheus` dependency is the VictoriaMetrics operator, because the series come from
# the operator's own scrape of the agent:
#   VMAgentDown                       down, critical. Every target's `up`
#                                     reaches the store through the agent,
#                                     so this also fires when vminsert or
#                                     vmstorage stop accepting writes.
#   VMAgentPersistentQueueDropping    data at risk, critical
#   VMAgentRemoteWriteDropping        data at risk, warning: vminsert
#                                     rejected blocks
#   VMAgentRemoteWriteErrors          stuck state, warning
#   VMAgentConfigReloadFailed         stuck state, warning
# Not covered here: other packages' targets failing their scrapes
# (TargetDown in prometheus-default-rules, which does not run on a cluster
# without prometheus-operator), one replica of the pair down, and scrape
# volume and saturation, which belong on a dashboard.

{
  scope,
  lib,
  kix,
  availability,
}:
let
  name = scope.instanceName;

  inherit (import ../victoria-metrics-operator/cr-image.nix { inherit lib kix; }) crImage;
in
{
  meta = {
    version = "v1.150.0";
    description = "VictoriaMetrics agent: a metrics scraper run through a VMAgent CR";
    owner = "platform";
    defaultAliases = [ "vmAgent" ];
    k8s.minVersion = "1.25";
  };

  # Dedup correctness rides on scrapeInterval equality with the cluster:
  # -dedup.minScrapeInterval on vmselect/vmstorage is calibrated to the
  # cluster's value, so a differing agent override double-counts samples.
  # Surfaced through the structured diagnostics channel so it lands in
  # Kix's warning output, not a bare eval trace. It is a warning rather
  # than an error so that a trial can scrape at another interval.
  warnings =
    { config, deps, ... }:
    lib.optional
      (
        config.scrapeInterval != null
        && (deps ? vmCluster)
        && config.scrapeInterval != deps.vmCluster.out.scrapeInterval
      )
      "scrapeInterval ${config.scrapeInterval} differs from the cluster's ${deps.vmCluster.out.scrapeInterval}; -dedup.minScrapeInterval on vmselect/vmstorage is calibrated to the cluster value, so samples may double-count. Change both together.";

  options = {
    image = kix.options.image {
      repository = "victoriametrics/vmagent";
      tag = "v1.150.0";
      pullPolicy = null;
    };
    replicaCount = lib.mkOption {
      type = lib.types.int;
      # The HA pair from "node" up; below that a second scraper only
      # doubles the ingest the cluster then has to dedup away.
      default = kix.availability.pick availability {
        none = 1;
        pod = 1;
        node = 2;
        zone = 2;
      };
      description = ''
        Identical-replica HA pair; the cluster's dedup collapses the
        double ingest. Defaults from the cluster's availability level.
      '';
    };
    scrapeInterval = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        null = use the cluster's out.scrapeInterval (recommended: dedup
        on vmselect/vmstorage is calibrated to it). Override only with a
        matching change on the cluster instance.
      '';
    };
    selectAllByDefault = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Scrape all scrape objects cluster-wide when the selectors are unset.";
    };
    externalLabels = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Labels attached to every scraped sample (e.g. cluster identity).";
    };
    # No CPU limit: a CFS quota throttles scrape bursts. The memory limit
    # bounds the process.
    resources = kix.options.resources {
      requests = {
        cpu = "250m";
        memory = "512Mi";
      };
      limits = {
        memory = "1Gi";
      };
    };
    extraArgs = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "vmagent flags for the VMAgent CR's `extraArgs`, keyed by flag name without the leading dash. Merged over the package's flags, so an entry here replaces the package's value for that flag. The package sets `promscrape.streamParse = \"true\"`.";
    };
    extraSpec = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Extra fields deep-merged into the VMAgent CR spec. The package refuses `remoteWrite` and `scrapeInterval`, which come from the vmCluster dependency, and `image`, `replicaCount`, `selectAllByDefault`, `resources`, and `extraArgs`, which have options of their own.";
    };

    # The operator scrapes the agent whatever this says; `enabled` only
    # switches the package's alert rules.
    metrics = kix.options.alerts;

    # After the agent is ready, run ./health-check.py as a Job in this
    # namespace: the agent's own samples are fresh, every replica is
    # scraped and up, no remote-write errors. Proves the scrape-and-write
    # path end to end from inside the cluster.
    # region:healthCheckOptions
    healthCheck = kix.options.healthCheck // {
      maxSampleAge = lib.mkOption {
        type = lib.types.int;
        default = 120;
        description = "Seconds. The agent's newest sample older than this fails the probe.";
      };
    };
    # endregion:healthCheckOptions
  };

  build = [
    (
      {
        self,
        config,
        clusterConfig,
        vmOperator,
        vmCluster,
        ...
      }:
      let
        # Stream-parse scrape responses instead of buffering them whole;
        # bounds vmagent memory on large targets (k8s-stack chart default).
        baseArgs = {
          "promscrape.streamParse" = "true";
        };
        baseSpec = {
          replicaCount = config.replicaCount;
          image = crImage config.image;
          remoteWrite = [ { url = vmCluster.out.remoteWriteUrl; } ];
          # The cluster's dedup is calibrated to its scrapeInterval; an
          # agent override that differs double-counts samples. Drift is
          # flagged through the package-level `warnings` channel above.
          scrapeInterval =
            if config.scrapeInterval == null then vmCluster.out.scrapeInterval else config.scrapeInterval;
          selectAllByDefault = config.selectAllByDefault;
          podDisruptionBudget = {
            maxUnavailable = 1;
          };
          # Operand pods are rendered by the operator, so Kix's derived
          # spread never sees them: the CR carries the rule, and the
          # failure-domain keys come from the cluster, never a literal.
          affinity = {
            podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution = map (topologyKey: {
              weight = 100;
              podAffinityTerm = {
                labelSelector.matchLabels = {
                  "app.kubernetes.io/name" = "vmagent";
                  "app.kubernetes.io/instance" = name;
                };
                inherit topologyKey;
              };
            }) clusterConfig.cluster.topology.failureDomainKeys;
          };
          resources = config.resources;
          extraArgs = baseArgs // config.extraArgs;
        }
        // lib.optionalAttrs (config.externalLabels != { }) {
          externalLabels = config.externalLabels;
        };
      in
      {
        vmAgent = vmOperator.out.mkVMAgent scope {
          inherit name;
          spec = kix.mergeGuarded {
            who = "victoria-metrics-agent ${scope.namespaceName}/${name}";
            locked = map lib.toList [
              "remoteWrite"
              "scrapeInterval"
              "image"
              "replicaCount"
              "selectAllByDefault"
              "resources"
              "extraArgs"
            ];
          } baseSpec config.extraSpec;
        };

        # The operator creates the agent pods, so no workload policy is
        # derived for them. Kubernetes service discovery and the
        # config-reloader sidecar call the API server. The remote write to
        # vminsert comes from the VMAgent CRD's factBehavior, and the scrape
        # paths from the netpol scrape join.
        agentEgress = kix.operandPolicy {
          inherit scope;
          name = "${name}-egress";
          spec = {
            endpointSelector.matchLabels = {
              "app.kubernetes.io/name" = "vmagent";
              "app.kubernetes.io/instance" = name;
            };
            egress = [
              scope.networkPolicyEnforcer.netpol.dnsEgressRule
              scope.networkPolicyEnforcer.netpol.apiServerEgressRule
            ];
          };
        };

        root = {
          resource = self.vmAgent;
          requires = lib.optional (self.agentEgress != null) self.agentEgress;
          out = {
            # Operand pods are operator-created; image not in any Kix manifest.
            extraImages = [ (kix.image.ref config.image) ];
          };
        };
      }
    )

    # DI passes a build function only the arguments its formals name, so
    # the wrapper names every argument kix.alerts reads.
    (
      {
        self,
        config,
        scope,
        prometheus ? null,
        ...
      }@args:
      let
        ns = scope.namespaceName;
        # The operator's VMServiceScrape sets `job` to the agent's Service
        # name, which the CR states as out.scrapeJob. The `service` label is
        # the same, but the config-reloader sidecar shares that Service
        # under job `<scrapeJob>-config-reloader`, so only `job` picks out
        # vmagent itself.
        ag = ''namespace="${ns}",job="${self.vmAgent.out.scrapeJob}"'';
      in
      kix.alerts
        {
          alerts = {
            VMAgentDown = {
              expr = "sum by (namespace, job) (up{${ag}}) == 0 or absent(up{${ag}})";
              "for" = "10m";
              severity = "critical";
              summary = "No vmagent replica is scraping.";
              description = "No replica of vmagent ${ns}/${name} has a fresh `up` sample for 10 minutes, so no target in the cluster is being scraped and stored. If the vmagent pods are running, vminsert or vmstorage is not accepting writes. Check the vmagent-${name} pods, then VMInsertDown and VMStorageDown.";
            };
            # The on-disk queue holds samples vminsert has not accepted yet;
            # a full queue drops the oldest.
            VMAgentPersistentQueueDropping = {
              expr = "sum by (namespace, job) (increase(vm_persistentqueue_bytes_dropped_total{${ag}}[5m])) > 0";
              "for" = "10m";
              severity = "critical";
              summary = "vmagent is dropping samples from its full persistent queue.";
              description = "vmagent ${ns}/${name} dropped {{ $value | humanize1024 }}B of queued samples in 5 minutes because its persistent queue is full. Those samples are lost. Check that vminsert accepts writes.";
            };
            VMAgentRemoteWriteDropping = {
              expr = "sum by (namespace, job) (increase(vmagent_remotewrite_packets_dropped_total{${ag}}[5m])) > 0";
              "for" = "15m";
              severity = "warning";
              summary = "vmagent is dropping data blocks that vminsert rejected.";
              description = "vmagent ${ns}/${name} dropped {{ $value | humanize }} blocks in 5 minutes after vminsert answered with a 4xx status. Those samples are lost. Check the vminsert logs for the reason.";
            };
            VMAgentRemoteWriteErrors = {
              expr = "sum by (namespace, job) (rate(vmagent_remotewrite_retries_count_total{${ag}}[5m])) > 0";
              "for" = "15m";
              severity = "warning";
              summary = "vmagent keeps retrying writes to vminsert.";
              description = "vmagent ${ns}/${name} has retried remote writes for 15 minutes. Samples wait in its queue meanwhile and are lost when the queue fills. Check that vminsert is reachable and healthy.";
            };
            VMAgentConfigReloadFailed = {
              expr = "min by (namespace, job) (vm_promscrape_config_last_reload_successful{${ag}}) < 1";
              "for" = "10m";
              severity = "warning";
              summary = "vmagent failed to load its scrape configuration.";
              description = "A replica of vmagent ${ns}/${name} could not load the scrape configuration the operator generated and still scrapes with the previous one. Check its logs and the VMServiceScrape and VMPodScrape objects changed most recently.";
            };
          };
        }
        (
          args
          // {
            # A native VMRule does not depend on the operator's
            # PrometheusRule converter, and a prometheus-operator
            # Prometheus on the same cluster does not load it.
            prometheus =
              if prometheus != null && prometheus.out ? mkVMRule then
                { out.mkPrometheusRule = prometheus.out.mkVMRule; }
              else
                null;
          }
        )
    )

    # The agent's samples arrive at the cluster and nothing on the
    # scrape-and-write path reports errors (see kix.healthCheck). The
    # script is a file so it can be read, linted, and run on its own.
    # region:healthCheckBuildEntry
    (kix.healthCheck {
      env =
        {
          self,
          config,
          deps,
          ...
        }:
        {
          VMSELECT_URL = deps.vmCluster.out.serviceUrl;
          # What the operator names and sizes the agent, read off the CR.
          AGENT_JOB = self.vmAgent.out.scrapeJob;
          AGENT_REPLICAS = self.vmAgent.out.replicas;
          MAX_SAMPLE_AGE = toString config.healthCheck.maxSampleAge;
        };
      script = builtins.readFile ./health-check.py;
    })
    # endregion:healthCheckBuildEntry
  ];
}

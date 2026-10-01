# victoria-metrics-agent: HA scrape agent (VMAgent CR) feeding a
# victoria-metrics-cluster (v2_discussions/133 §3.3).
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
# DI deps:
#   vmOperator (required)   provides the VMAgent CRD + mkVMAgent
#   vmCluster (required)    out.insertUrl (remote-write target),
#                           out.scrapeInterval (dedup coupling)
#
# The remoteWrite URL carries the store-path edge to the cluster's insert
# Service, and the VMAgent CRD's terminate factBehavior points netpol at
# the vmagent operand pods, so the egress hole lands on the pods that
# actually dial vminsert.

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

  # Dedup CORRECTNESS rides on scrapeInterval equality with the cluster
  # (doc 133 §5): -dedup.minScrapeInterval on vmselect/vmstorage is
  # calibrated to the cluster's value, so a differing agent override
  # double-counts samples. Surfaced through the structured diagnostics
  # channel so it lands in kix's warning output, not a bare eval trace.
  # FUTURE (purist note, 2026-08-31): arguably an assertion, or remove
  # the agent-side option so drift cannot exist. Kept a warning while
  # the trial wants easy experimentation.
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
        double ingest. Defaults from the cluster's availability level
        (v2_discussions/145).
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
      description = "Extra fields deep-merged into the VMAgent CR spec.";
    };

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
          remoteWrite = [ { url = vmCluster.out.insertUrl; } ];
          # The cluster's dedup is calibrated to ITS scrapeInterval; an
          # agent override that differs double-counts samples (doc 133 §5).
          # Drift is flagged through the package-level `warnings` channel
          # below, not inline.
          scrapeInterval =
            if config.scrapeInterval == null then vmCluster.out.scrapeInterval else config.scrapeInterval;
          selectAllByDefault = config.selectAllByDefault;
          podDisruptionBudget = {
            maxUnavailable = 1;
          };
          # Operand pods are rendered by the operator, so kix's derived
          # spread never sees them: the CR carries the rule, but the
          # failure-domain keys come from the cluster (v2_discussions/143
          # §2), never a literal.
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
          spec = lib.recursiveUpdate baseSpec config.extraSpec;
        };

        root = {
          resource = self.vmAgent;
          out = {
            # Operand pods are operator-created; image not in any kix manifest.
            extraImages = [ (kix.image.ref config.image) ];
          };
        };
      }
    )

    # The agent's samples arrive at the cluster and nothing on the
    # scrape-and-write path reports errors (see kix.healthCheck). The
    # script is a file so it can be read, linted and run on its own.
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

# victoria-metrics-agent — HA scrape agent (VMAgent CR) feeding a
# victoria-metrics-cluster (v2_discussions/133 §3.3).
#
# Two identical replicas scrape everything and both remote-write to
# vminsert; the cluster's dedup (calibrated to the same scrapeInterval,
# via vmCluster.out.scrapeInterval) collapses the duplicate samples.
# Sharding (shardCount) is deliberately out of scope until target counts
# demand it.
#
# Watch-everything default: selectAllByDefault = true, so every
# VMServiceScrape / VMPodScrape — and, via the operator's converter,
# every ServiceMonitor / PodMonitor — in the cluster is scraped, matching
# the prometheus package's posture.
#
# DI deps:
#   vmOperator (required) — provides the VMAgent CRD + mkVMAgent
#   vmCluster (required)  — out.insertUrl (remote-write target),
#                           out.scrapeInterval (dedup coupling)
#
# The remoteWrite URL carries the store-path edge to the cluster's insert
# Service, and the VMAgent CRD's terminate factBehavior points netpol at
# the vmagent operand pods — the egress hole lands on the pods that
# actually dial vminsert.

{
  scope,
  lib,
}:
let
  name = scope.instanceName;
in
{
  meta = {
    version = "v1.150.0";
    description = "VictoriaMetrics agent — HA metrics scraper via VMAgent CR";
    defaultAliases = [ "vmAgent" ];
    k8s.minVersion = "1.25";
  };

  options = {
    image = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "victoriametrics/vmagent";
        tag = "v1.150.0";
      };
    };
    replicaCount = lib.mkOption {
      type = lib.types.int;
      default = 2;
      description = "Identical-replica HA pair; the cluster's dedup collapses the double ingest.";
    };
    scrapeInterval = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        null = use the cluster's out.scrapeInterval (recommended — dedup
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
    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
        requests = {
          cpu = "250m";
          memory = "512Mi";
        };
        limits = {
          memory = "1Gi";
        };
      };
    };
    extraArgs = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        # Stream-parse scrape responses instead of buffering them whole —
        # bounds vmagent memory on large targets (k8s-stack chart default).
        "promscrape.streamParse" = "true";
      };
    };
    extraSpec = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Extra fields deep-merged into the VMAgent CR spec.";
    };
  };

  build =
    {
      self,
      config,
      vmOperator,
      vmCluster,
      ...
    }:
    let
      baseSpec = {
        replicaCount = config.replicaCount;
        image = {
          inherit (config.image) repository tag;
        };
        remoteWrite = [ { url = vmCluster.out.insertUrl; } ];
        # The cluster's dedup is calibrated to ITS scrapeInterval — an
        # agent override that differs double-counts samples (doc 133 §5).
        scrapeInterval =
          if config.scrapeInterval == null then
            vmCluster.out.scrapeInterval
          else
            lib.warnIf (config.scrapeInterval != vmCluster.out.scrapeInterval)
              "victoria-metrics-agent '${name}': scrapeInterval ${config.scrapeInterval} differs from the cluster's ${vmCluster.out.scrapeInterval}; -dedup.minScrapeInterval on vmselect/vmstorage is calibrated to the cluster value, so samples may double-count. Change both together."
              config.scrapeInterval;
        selectAllByDefault = config.selectAllByDefault;
        podDisruptionBudget = {
          maxUnavailable = 1;
        };
        affinity = {
          podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution = [
            {
              weight = 100;
              podAffinityTerm = {
                labelSelector.matchLabels = {
                  "app.kubernetes.io/name" = "vmagent";
                  "app.kubernetes.io/instance" = name;
                };
                topologyKey = "kubernetes.io/hostname";
              };
            }
          ];
        };
        resources = config.resources;
      }
      // lib.optionalAttrs (config.externalLabels != { }) {
        externalLabels = config.externalLabels;
      }
      // lib.optionalAttrs (config.extraArgs != { }) {
        extraArgs = config.extraArgs;
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
          extraImages = [ "${config.image.repository}:${config.image.tag}" ];
        };
      };
    };
}

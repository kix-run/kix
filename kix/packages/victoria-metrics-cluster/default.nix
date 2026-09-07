# victoria-metrics-cluster — VictoriaMetrics cluster (VMCluster CR) in HA
# mode, the metrics store behind the `prometheusServer` alias
# (v2_discussions/133 §3.2).
#
# Creates a VMCluster CR that the VM operator reconciles into vmstorage /
# vmselect / vminsert workloads. HA is the default posture — and must be,
# because the scorecard cannot see operator-created pods: replication
# factor 2 over 3 vmstorage nodes, 2 vmselect + 2 vminsert, per-component
# PDBs and preferred hostname anti-affinity.
#
# Dedup is correctness, not tuning: with replicationFactor > 1 every
# sample exists twice, and an HA vmagent pair ingests everything twice
# again. `-dedup.minScrapeInterval` must equal the scrape interval on both
# vmselect and vmstorage or queries double-count. Both flags derive from
# the single `scrapeInterval` option so they cannot drift; the agent
# package reads it back via `out.scrapeInterval`. (The operator's own
# fallback is 1ms — enough for replication twins, useless for HA-pair
# duplicates, which land with distinct timestamps.)
#
# DI deps:
#   vmOperator (required)      — provides the VMCluster CRD + mkVMCluster
#   storageClasses (optional)  — supplies vmstorage's storageClassName when
#                                the option is unset; absent = cluster
#                                default StorageClass
#
# Exposes:
#   out.serviceUrl — "http://<name>-select.<ns>.svc.cluster.local:8481/select/0/prometheus"
#     Prometheus-compatible read path; Grafana auto-wires any
#     `prometheusServer`-aliased instance exposing this.
#   out.insertUrl — ".../insert/0/prometheus/api/v1/write" full
#     remote-write URL (vmagent wants the full path).
#   out.insertBaseUrl — ".../insert/0/prometheus" (vmalert appends
#     /api/v1/write itself).
#   out.scrapeInterval — the interval dedup is calibrated to; scrapers
#     must use it.

{
  scope,
  lib,
}:
let
  name = scope.instanceName;
  ns = scope.namespaceName;

  mkComponentResources =
    requests: limits:
    lib.mkOption {
      type = lib.types.anything;
      default = {
        inherit requests limits;
      };
    };
in
{
  meta = {
    version = "v1.150.0";
    description = "VictoriaMetrics cluster — HA vmstorage/vmselect/vminsert via VMCluster CR";
    defaultAliases = [
      "prometheusServer"
      "vmCluster"
    ];
    k8s.minVersion = "1.25";
    # Trial posture: historical metrics are expendable on storage swaps
    # (prometheus package precedent). Revisit if VM becomes the long-term
    # store — v2_discussions/133 §3.2.
    lifecycle = "ephemeral";
  };

  options = {
    clusterVersion = lib.mkOption {
      type = lib.types.str;
      default = "v1.150.0-cluster";
      description = ''
        Image tag for all three components (spec.clusterVersion, used
        verbatim by the operator). Cluster-mode images carry the
        `-cluster` suffix.
      '';
    };
    retentionPeriod = lib.mkOption {
      type = lib.types.str;
      default = "30d";
    };
    replicationFactor = lib.mkOption {
      type = lib.types.int;
      default = 2;
      description = ''
        Copies of every sample across vmstorage nodes. The operator
        propagates it to vminsert and vmselect (-replicationFactor), so
        queries stay complete with one vmstorage down.
      '';
    };
    scrapeInterval = lib.mkOption {
      type = lib.types.str;
      default = "30s";
      description = ''
        Drives -dedup.minScrapeInterval on vmselect and vmstorage.
        Scrapers (victoria-metrics-agent) must scrape at this interval —
        read it via out.scrapeInterval.
      '';
    };
    useStrictSecurity = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Operator-applied hardened security contexts on operand pods.";
    };

    vmstorage = {
      replicaCount = lib.mkOption {
        type = lib.types.int;
        default = 3;
        description = "Minimum 3 for replicationFactor 2 with one-node failure headroom.";
      };
      storage = lib.mkOption {
        type = lib.types.anything;
        default = {
          resources.requests.storage = "20Gi";
        };
        description = "PVC spec for the vmstorage volumeClaimTemplate (operator-created claims).";
      };
      storageClassName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          StorageClass for vmstorage claims. null = take it from the
          optional storageClasses dep, or fall back to the cluster
          default StorageClass.
        '';
      };
      resources = mkComponentResources {
        cpu = "1";
        memory = "2Gi";
      } { memory = "4Gi"; };
      extraArgs = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
      };
    };

    vmselect = {
      replicaCount = lib.mkOption {
        type = lib.types.int;
        default = 2;
      };
      resources = mkComponentResources {
        cpu = "500m";
        memory = "512Mi";
      } { memory = "1Gi"; };
      extraArgs = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
      };
    };

    vminsert = {
      replicaCount = lib.mkOption {
        type = lib.types.int;
        default = 2;
      };
      resources = mkComponentResources {
        cpu = "500m";
        memory = "512Mi";
      } { memory = "1Gi"; };
      extraArgs = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
      };
    };

    extraSpec = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = ''
        Extra fields deep-merged into the VMCluster CR spec via
        lib.recursiveUpdate. Escape hatch for fields not exposed as typed
        options (downsampling, requestsLoadBalancer, per-component
        overrides).
      '';
    };
  };

  build =
    {
      self,
      config,
      vmOperator,
      storageClasses ? null,
      ...
    }:
    let
      # Operand pod labels the operator stamps on VMCluster children —
      # component name + CR name (CR name = instance name).
      componentSelector = component: {
        "app.kubernetes.io/name" = component;
        "app.kubernetes.io/instance" = name;
      };

      antiAffinity = component: {
        podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution = [
          {
            weight = 100;
            podAffinityTerm = {
              labelSelector.matchLabels = componentSelector component;
              topologyKey = "kubernetes.io/hostname";
            };
          }
        ];
      };

      pdb = {
        maxUnavailable = 1;
      };

      # FUTURE (purist note, 2026-08-31): dedup correctness rides in a
      # string flag merged into extraArgs — a cluster-side extraArgs
      # override can silently clobber it. Consider a first-class operator
      # spec field (or an eval assertion that extraArgs never overrides a
      # package-computed arg) if the VM operator ever grows one.
      dedupArgs = {
        "dedup.minScrapeInterval" = config.scrapeInterval;
      };

      # Explicit option > storageClasses dep > cluster default class.
      effectiveStorageClass =
        if config.vmstorage.storageClassName != null then
          config.vmstorage.storageClassName
        else if storageClasses != null then
          storageClasses.out.storageClassName
        else
          null;

      baseSpec = {
        inherit (config)
          retentionPeriod
          replicationFactor
          clusterVersion
          useStrictSecurity
          ;

        vmstorage = {
          inherit (config.vmstorage) replicaCount resources;
          storage.volumeClaimTemplate.spec =
            config.vmstorage.storage
            // lib.optionalAttrs (effectiveStorageClass != null) {
              storageClassName = effectiveStorageClass;
            };
          podDisruptionBudget = pdb;
          affinity = antiAffinity "vmstorage";
          extraArgs = dedupArgs // config.vmstorage.extraArgs;
        };

        vmselect = {
          inherit (config.vmselect) replicaCount resources;
          podDisruptionBudget = pdb;
          affinity = antiAffinity "vmselect";
          extraArgs = dedupArgs // config.vmselect.extraArgs;
        };

        vminsert = {
          inherit (config.vminsert) replicaCount resources;
          podDisruptionBudget = pdb;
          affinity = antiAffinity "vminsert";
        }
        // lib.optionalAttrs (config.vminsert.extraArgs != { }) {
          extraArgs = config.vminsert.extraArgs;
        };
      };
    in
    {
      vmCluster = vmOperator.out.mkVMCluster scope {
        inherit name;
        spec = lib.recursiveUpdate baseSpec config.extraSpec;
      };

      # The operator creates its own Services (vmselect-<name> etc.); these
      # package-owned ones exist for stable naming and DI-friendly
      # out.serviceUrl/out.insertUrl with dependency context — same
      # pattern as the prometheus package.
      selectService = scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${name}-select";
        # Distinct per-Service identity (distinctSameKindLabels): without
        # it, no label selector can tell the select and insert Services
        # apart.
        labels."app.kubernetes.io/component" = "vmselect";
        requires = [ self.vmCluster ];
        spec = {
          type = "ClusterIP";
          selector = componentSelector "vmselect";
          ports = [
            {
              name = "http";
              port = 8481;
              targetPort = 8481;
              protocol = "TCP";
            }
          ];
        };
        outputs = {
          serviceUrl = "http://${name}-select.${ns}.svc.cluster.local:8481/select/0/prometheus";
        };
      };

      insertService = scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${name}-insert";
        labels."app.kubernetes.io/component" = "vminsert";
        requires = [ self.vmCluster ];
        spec = {
          type = "ClusterIP";
          selector = componentSelector "vminsert";
          ports = [
            {
              name = "http";
              port = 8480;
              targetPort = 8480;
              protocol = "TCP";
            }
          ];
        };
        outputs = {
          insertUrl = "http://${name}-insert.${ns}.svc.cluster.local:8480/insert/0/prometheus/api/v1/write";
          insertBaseUrl = "http://${name}-insert.${ns}.svc.cluster.local:8480/insert/0/prometheus";
        };
      };

      root = {
        resource = self.selectService;
        requires = [
          self.vmCluster
          self.insertService
        ];
        out = {
          inherit (self.selectService.out) serviceUrl;
          inherit (self.insertService.out) insertUrl insertBaseUrl;
          inherit (config) scrapeInterval;
          # Operand images are reconciled by the operator, not in any
          # kix-generated pod spec.
          extraImages = [
            "victoriametrics/vmstorage:${config.clusterVersion}"
            "victoriametrics/vmselect:${config.clusterVersion}"
            "victoriametrics/vminsert:${config.clusterVersion}"
          ];
        };
      };
    };
}

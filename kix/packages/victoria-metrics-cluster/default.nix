# victoria-metrics-cluster: VictoriaMetrics cluster (VMCluster CR) in HA
# mode, the metrics store behind the `prometheusServer` alias
# (v2_discussions/133 §3.2).
#
# Creates a VMCluster CR that the VM operator reconciles into vmstorage /
# vmselect / vminsert workloads. HA is the default posture, and must be,
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
# fallback is 1ms: enough for replication twins, useless for HA-pair
# duplicates, which land with distinct timestamps.)
#
# DI deps:
#   vmOperator (required)        provides the VMCluster CRD + mkVMCluster
#   storageClasses (optional)    supplies vmstorage's storageClassName when
#                                the option is unset; absent = cluster
#                                default StorageClass
#
# Exposes:
#   out.serviceUrl: "http://vmselect-<name>.<ns>.svc:8481/select/0/prometheus" (the operator's Service)
#     Prometheus-compatible read path; Grafana auto-wires any
#     `prometheusServer`-aliased instance exposing this.
#   out.remoteWriteUrl: ".../insert/0/prometheus/api/v1/write", the full
#     Prometheus remote-write URL (vmagent and tempo read it).
#   out.insertBaseUrl: ".../insert/0/prometheus" (vmalert appends
#     /api/v1/write itself).
#   out.scrapeInterval: the interval dedup is calibrated to; scrapers
#     must use it.

{
  scope,
  lib,
  kix,
  availability,
}:
let
  name = scope.instanceName;
  who = "victoria-metrics-cluster ${scope.namespaceName}/${name}";
in
{
  meta = {
    version = "v1.150.0";
    description = "VictoriaMetrics cluster: vmstorage, vmselect and vminsert through a VMCluster CR";
    owner = "platform";
    defaultAliases = [
      "prometheusServer"
      "vmCluster"
    ];
    k8s.minVersion = "1.25";
    # Trial posture: historical metrics are expendable on storage swaps
    # (prometheus package precedent). Revisit if VM becomes the long-term
    # store (v2_discussions/133 §3.2).
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
      # A second copy of every sample only pays off once a whole node may
      # go, so replication starts at "node".
      default = kix.availability.pick availability {
        none = 1;
        pod = 1;
        node = 2;
        zone = 2;
      };
      description = ''
        Copies of every sample across vmstorage nodes. The operator
        propagates it to vminsert and vmselect (-replicationFactor), so
        queries stay complete with one vmstorage down. Defaults from the
        cluster's availability level (v2_discussions/145).
      '';
    };
    scrapeInterval = lib.mkOption {
      type = lib.types.str;
      default = "30s";
      description = ''
        Drives -dedup.minScrapeInterval on vmselect and vmstorage.
        Scrapers (victoria-metrics-agent) must scrape at this interval;
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
        # Three nodes is what replicationFactor 2 needs for one-node
        # failure headroom, so the count rises with the factor at "node".
        default = kix.availability.pick availability {
          none = 1;
          pod = 1;
          node = 3;
          zone = 3;
        };
        description = ''
          Minimum 3 for replicationFactor 2 with one-node failure
          headroom. Defaults from the cluster's availability level
          (v2_discussions/145).
        '';
      };
      storage = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        defaultText = lib.literalExpression ''{ resources.requests.storage = "20Gi"; }'';
        description = "PersistentVolumeClaim spec for the vmstorage volumeClaimTemplate (operator-created claims). Deep-merged over the package's spec, which requests 20Gi. `storageClassName` is refused here; set `vmstorage.storageClassName`.";
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
      # No CPU limit: a CFS quota throttles merges and query bursts.
      # VictoriaMetrics reads the memory limit from the cgroup to size its
      # caches.
      resources = kix.options.resources {
        requests = {
          cpu = "1";
          memory = "2Gi";
        };
        limits.memory = "4Gi";
      };
      extraArgs = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Extra vmstorage flags, keyed by flag name without the leading dash. `dedup.minScrapeInterval` is refused; it follows `scrapeInterval`.";
      };
    };

    vmselect = {
      replicaCount = lib.mkOption {
        type = lib.types.int;
        # Stateless read path: a second replica as soon as a pod restart must not
        # be an outage, and vmselect needs no more than the pair.
        default = kix.availability.pick availability {
          none = 1;
          pod = 2;
          node = 2;
          zone = 2;
        };
        description = ''
          Number of vmselect replicas. Defaults from the cluster's
          availability level (v2_discussions/145).
        '';
      };
      # No CPU limit: a CFS quota throttles merges and query bursts.
      # VictoriaMetrics reads the memory limit from the cgroup to size its
      # caches.
      resources = kix.options.resources {
        requests = {
          cpu = "500m";
          memory = "512Mi";
        };
        limits.memory = "1Gi";
      };
      extraArgs = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Extra vmselect flags, keyed by flag name without the leading dash. `dedup.minScrapeInterval` is refused; it follows `scrapeInterval`.";
      };
    };

    vminsert = {
      replicaCount = lib.mkOption {
        type = lib.types.int;
        # Stateless write path: a second replica as soon as a pod restart must not
        # be an outage, and vminsert needs no more than the pair.
        default = kix.availability.pick availability {
          none = 1;
          pod = 2;
          node = 2;
          zone = 2;
        };
        description = ''
          Number of vminsert replicas. Defaults from the cluster's
          availability level (v2_discussions/145).
        '';
      };
      # No CPU limit: a CFS quota throttles merges and query bursts.
      # VictoriaMetrics reads the memory limit from the cgroup to size its
      # caches.
      resources = kix.options.resources {
        requests = {
          cpu = "500m";
          memory = "512Mi";
        };
        limits.memory = "1Gi";
      };
      extraArgs = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Extra vminsert flags, keyed by flag name without the leading dash.";
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
      clusterConfig,
      kix,
      vmOperator,
      storageClasses ? null,
      ...
    }:
    let
      # Operand pod labels the operator stamps on VMCluster children:
      # component name + CR name (CR name = instance name).
      componentSelector = component: {
        "app.kubernetes.io/name" = component;
        "app.kubernetes.io/instance" = name;
      };

      # Operand pods are rendered by the operator, so kix's derived spread
      # never sees them: the CR carries the rule, but the failure-domain
      # keys come from the cluster (v2_discussions/143 §2), never a literal.
      antiAffinity = component: {
        podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution = map (topologyKey: {
          weight = 100;
          podAffinityTerm = {
            labelSelector.matchLabels = componentSelector component;
            inherit topologyKey;
          };
        }) clusterConfig.cluster.topology.failureDomainKeys;
      };

      pdb = {
        maxUnavailable = 1;
      };

      # The VMCluster CR has no dedup field, so the interval travels as a
      # flag. `extraSpec` cannot reach it (kix.mergeGuarded below) and the
      # component `extraArgs` options may not set it.
      dedupArgs = {
        "dedup.minScrapeInterval" = config.scrapeInterval;
      };
      componentArgs =
        component:
        let
          args = config.${component}.extraArgs;
        in
        if args ? "dedup.minScrapeInterval" then
          throw "${who}: ${component}.extraArgs sets dedup.minScrapeInterval, which the package derives from scrapeInterval so that vmselect and vmstorage agree. Set scrapeInterval instead."
        else
          dedupArgs // args;

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
            if config.vmstorage.storage ? storageClassName then
              throw "${who}: vmstorage.storage sets storageClassName, which the package derives from vmstorage.storageClassName, the storageClasses dependency, or the cluster default. Set vmstorage.storageClassName instead."
            else
              lib.recursiveUpdate { resources.requests.storage = "20Gi"; } config.vmstorage.storage
              // lib.optionalAttrs (effectiveStorageClass != null) {
                storageClassName = effectiveStorageClass;
              };
          podDisruptionBudget = pdb;
          affinity = antiAffinity "vmstorage";
          extraArgs = componentArgs "vmstorage";
        };

        vmselect = {
          inherit (config.vmselect) replicaCount resources;
          podDisruptionBudget = pdb;
          affinity = antiAffinity "vmselect";
          extraArgs = componentArgs "vmselect";
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
        spec = kix.mergeGuarded {
          inherit who;
          # Everything here is computed (the storage class from the
          # dep, the dedup flag) or has an option of its own.
          locked = [
            [ "retentionPeriod" ]
            [ "replicationFactor" ]
            [ "clusterVersion" ]
            [
              "vmstorage"
              "storage"
            ]
            [
              "vmstorage"
              "extraArgs"
            ]
            [
              "vmselect"
              "extraArgs"
            ]
          ];
        } baseSpec config.extraSpec;
      };

      # The operator creates the operand Services itself: vmselect-<name>
      # on 8481 and vminsert-<name> on 8480, selecting the pods it stamps
      # with componentSelector. A ServiceRef describes each one, so
      # consumers get out.fqdn with dependency context, the deploy engine
      # waits for the Service to exist, and netpol opens the same edges it
      # would for a rendered Service (v2_discussions/135).
      selectService = scope.mkServiceRef {
        name = "vmselect-${name}";
        selector = componentSelector "vmselect";
        ports = [
          {
            name = "http";
            port = 8481;
            protocol = "TCP";
          }
        ];
        requires = [ self.vmCluster ];
      };

      insertService = scope.mkServiceRef {
        name = "vminsert-${name}";
        selector = componentSelector "vminsert";
        ports = [
          {
            name = "http";
            port = 8480;
            protocol = "TCP";
          }
        ];
        requires = [ self.vmCluster ];
      };

      root = {
        resource = self.selectService;
        requires = [
          self.vmCluster
          self.insertService
        ];
        out = {
          # URLs are built on the refs' fqdn, so they carry the marker's
          # dependency context and the endpoint fact.
          serviceUrl = "http://${self.selectService.out.fqdn}:8481/select/0/prometheus";
          remoteWriteUrl = "http://${self.insertService.out.fqdn}:8480/insert/0/prometheus/api/v1/write";
          insertBaseUrl = "http://${self.insertService.out.fqdn}:8480/insert/0/prometheus";
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

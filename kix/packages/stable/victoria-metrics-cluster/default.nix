# victoria-metrics-cluster: VictoriaMetrics cluster (VMCluster CR) in HA
# mode, the metrics store behind the `prometheusServer` alias.
#
# Creates a VMCluster CR that the VM operator reconciles into vmstorage /
# vmselect / vminsert workloads. HA is the default posture, and must be,
# because the scorecard cannot see operator-created pods: replication
# factor 2 over 3 vmstorage nodes, 2 vmselect + 2 vminsert, and, for each
# component above one replica, topology spread at the instance's
# availability level and a PodDisruptionBudget of one pod.
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
# Upgrades: VictoriaMetrics says a move to a newer release is safe, also
# across several releases, and so is a move back, unless the release notes
# say otherwise. From 1.150 to 1.156 they say neither. vmstorage keeps the
# data 1.150 wrote, and 1.150 reads the data 1.156 wrote. To go back, deploy
# the previous Kix release. The operator then restarts each component with
# the older image.
#
# Dependencies:
#   vmOperator (required)        provides the VMCluster CRD + mkVMCluster
#   storageClasses (optional)    supplies vmstorage's storageClassName when
#                                the option is unset; absent = cluster
#                                default StorageClass
#
# Network policy, with an enforcer: vminsert and vmselect reach vmstorage.
# When extraSpec sets vmstorage.vmBackup, vmbackupmanager in the vmstorage
# pods reaches the object store outside the cluster on the port of
# customS3Endpoint, else 443. A store inside the cluster needs a policy of
# its own.
#
# `out`:
#   out.serviceUrl: "http://vmselect-<name>.<ns>.svc:8481/select/0/prometheus" (the operator's Service)
#     Prometheus-compatible read path; Grafana auto-wires any
#     `prometheusServer`-aliased instance exposing this.
#   out.remoteWriteUrl: ".../insert/0/prometheus/api/v1/write", the full
#     Prometheus remote-write URL (vmagent and tempo read it).
#   out.insertBaseUrl: ".../insert/0/prometheus" (vmalert appends
#     /api/v1/write itself).
#   out.scrapeInterval: the interval dedup is calibrated to; scrapers
#     must use it.
#   out.version: the VictoriaMetrics version `clusterVersion` names.
#
# Alerts (a VMRule `<instance>-alerts`, which vmalert evaluates and a
# prometheus-operator Prometheus does not load). They render only when the
# `prometheus` dependency is the VictoriaMetrics operator, because the series come from
# the operator's own VMServiceScrapes, which a Prometheus server does not
# read:
#   VMStorageDown, VMInsertDown           down, critical
#   VMStorageReadOnly                     stuck state, critical: the node
#                                         accepts no writes
#   VMStorageDiskNearlyFull               exhaustion, warning, at
#                                         metrics.minFreeDiskPercent of the
#                                         space left before read-only
#   VMStorageReplicationLost              data at risk, critical: as many
#                                         vmstorage nodes down as the
#                                         replication factor (only with more
#                                         nodes than the factor)
#   VMInsertIncompleteReplication         data at risk, warning (only with a
#                                         replication factor above 1)
#   VMStorageMemoryNearLimit              exhaustion, warning
# Not covered here: vmselect down (vmalert queries through vmselect, so no
# rule fires; the Watchdog heartbeat in victoria-metrics-alert stops),
# single replicas down and restarts (TargetDown and KubePodCrashLooping
# where prometheus-default-rules runs; it does not run on a cluster without
# prometheus-operator), and ingestion details such as rejected rows, churn,
# and slow inserts, which belong on a dashboard.

{
  scope,
  lib,
  kix,
  availability,
}:
let
  release = "v1.156.0";
  name = scope.instanceName;
  inherit (import ../victoria-metrics-operator/operand-placement.nix { inherit lib kix; })
    operandPlacement
    ;
in
{
  meta = {
    version = release;
    description = "VictoriaMetrics cluster: vmstorage, vmselect and vminsert through a VMCluster CR";
    owner = "platform";
    defaultAliases = [
      "prometheusServer"
      "vmCluster"
    ];
    # One metrics store receives remote writes from every namespace, so
    # consumers in any namespace find it by name.
    scope = "cluster";
    k8s.minVersion = "1.25";
    # Historical metrics are expendable on storage backend swaps.
    lifecycle = "ephemeral";
  };

  options = {
    clusterVersion = lib.mkOption {
      type = lib.types.str;
      default = "${release}-cluster";
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
        cluster's availability level.
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
          headroom. Defaults from the cluster's availability level.
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
        description = "Extra vmstorage flags, keyed by flag name without the leading dash. The package refuses `dedup.minScrapeInterval`, `retentionPeriod`, and `replicationFactor`, which follow `scrapeInterval`, `retentionPeriod`, and `replicationFactor`.";
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
          availability level.
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
        description = "Extra vmselect flags, keyed by flag name without the leading dash. The package refuses `dedup.minScrapeInterval`, `retentionPeriod`, and `replicationFactor`, which follow `scrapeInterval`, `retentionPeriod`, and `replicationFactor`, and `httpListenAddr`, because `out.serviceUrl` names port 8481.";
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
          availability level.
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
        description = "Extra vminsert flags, keyed by flag name without the leading dash. The package refuses `retentionPeriod` and `replicationFactor`, which follow the options of the same name, and `httpListenAddr`, because `out.remoteWriteUrl` names port 8480.";
      };
    };

    # The operator scrapes the components whatever this says; `enabled`
    # only switches the package's alert rules.
    metrics = kix.options.alerts // {
      minFreeDiskPercent = lib.mkOption {
        type = lib.types.ints.between 1 99;
        default = 20;
        description = "VMStorageDiskNearlyFull fires when a vmstorage node has less than this percentage of its usable disk left, where usable is the stored data plus the free space above -storage.minFreeDiskSpaceBytes. Below that limit the node turns read-only. The default follows upstream's DiskRunsOutOfSpace rule (80% used).";
      };
    };

    extraSpec = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = ''
        Extra fields deep-merged into the VMCluster CR spec via
        lib.recursiveUpdate. Escape hatch for fields not exposed as typed
        options (downsampling, requestsLoadBalancer, per-component
        overrides). Setting `topologySpreadConstraints` on `vmstorage`,
        `vmselect`, or `vminsert` here replaces the default pod spread
        constraints set from the availability level.
      '';
    };
  };

  build = [
    (
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
        # Return operand pod labels the operator stamps on VMCluster children:
        # component name + CR name (CR name = instance name).
        componentSelector = component: {
          "app.kubernetes.io/name" = component;
          "app.kubernetes.io/instance" = name;
        };

        placement =
          component: replicas:
          operandPlacement {
            inherit availability replicas;
            topology = clusterConfig.cluster.topology;
            selector = componentSelector component;
          };

        # The VMCluster CR has no dedup field, so the interval travels as a
        # flag. `extraSpec` cannot reach it (kix.mergeGuarded below) and the
        # component `extraArgs` options may not set it.
        dedup = {
          flags."dedup.minScrapeInterval" = config.scrapeInterval;
          reason = "vmselect and vmstorage must use the same deduplication interval from scrapeInterval.";
          fix = "Remove dedup.minScrapeInterval and set scrapeInterval instead.";
        };
        # The operator turns spec fields into component flags, and an
        # `extraArgs` key of the same name replaces the generated flag.
        # Each component refuses the flags behind its spec fields, and the
        # listen address of the two Services the package's out URLs name.
        specFields = [
          {
            names = [ "retentionPeriod" ];
            from = "the retentionPeriod option";
            fix = "Remove retentionPeriod and set the retentionPeriod option instead.";
          }
          {
            names = [ "replicationFactor" ];
            reason = "vminsert, vmselect, and vmstorage must share the same replicationFactor.";
            fix = "Remove replicationFactor and set the replicationFactor option instead.";
          }
        ];
        ownedByComponent = {
          vmstorage = [ dedup ] ++ specFields;
          vmselect = [
            dedup
          ]
          ++ specFields
          ++ [
            {
              names = [ "httpListenAddr" ];
              reason = "the vmselect Service and query URL (out.serviceUrl) use port 8481.";
            }
          ];
          vminsert = specFields ++ [
            {
              names = [ "httpListenAddr" ];
              reason = "the vminsert Service and remote-write URLs (out.remoteWriteUrl and out.insertBaseUrl) use port 8480.";
            }
          ];
        };
        # vminsert, vmselect, and vmstorage parse flags with Go's flag
        # package (lib/envflag upstream).
        componentArgs =
          component:
          kix.mergeArgs {
            inherit scope;
            parser = "go";
            option = "${component}.extraArgs";
            args = ownedByComponent.${component};
          } config.${component}.extraArgs;

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
                scope.fail {
                  option = "vmstorage.storage.storageClassName";
                  message = "vmstorage.storage sets storageClassName, which the package derives from vmstorage.storageClassName, the storageClasses dependency, or the cluster default.";
                  fix = "Set vmstorage.storageClassName instead.";
                }
              else
                lib.recursiveUpdate { resources.requests.storage = "20Gi"; } config.vmstorage.storage
                // lib.optionalAttrs (effectiveStorageClass != null) {
                  storageClassName = effectiveStorageClass;
                };
            extraArgs = componentArgs "vmstorage";
          }
          // placement "vmstorage" config.vmstorage.replicaCount;

          vmselect = {
            inherit (config.vmselect) replicaCount resources;
            extraArgs = componentArgs "vmselect";
          }
          // placement "vmselect" config.vmselect.replicaCount;

          vminsert = {
            inherit (config.vminsert) replicaCount resources;
          }
          // placement "vminsert" config.vminsert.replicaCount
          // lib.optionalAttrs (config.vminsert.extraArgs != { }) {
            extraArgs = componentArgs "vminsert";
          };
        };

        spec = kix.mergeGuarded {
          inherit scope;
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

        # vmbackupmanager runs in the vmstorage pods when extraSpec sets
        # vmstorage.vmBackup, and uploads to the object store outside the
        # cluster: on the port of customS3Endpoint when it is set, else on
        # 443. An `fs://` destination is a local volume and needs no egress.
        vmBackup = spec.vmstorage.vmBackup or null;
        backupPort =
          let
            endpoint = vmBackup.customS3Endpoint or null;
            m =
              if endpoint == null then
                null
              else
                builtins.match "(https?)://(\\[[^]]*]|[^]/:?#[]*)(:([0-9]+))?([/?#].*)?" endpoint;
          in
          if vmBackup == null || lib.hasPrefix "fs://" (vmBackup.destination or "") then
            null
          else if endpoint == null then
            443
          else if m == null then
            scope.fail {
              option = "extraSpec.vmstorage.vmBackup.customS3Endpoint";
              message = "extraSpec.vmstorage.vmBackup.customS3Endpoint \"${endpoint}\" is not an http or https URL, so the package cannot tell which port vmbackupmanager reaches.";
              fix = "Write it as https://<host>[:<port>].";
            }
          else if builtins.elemAt m 3 != null then
            lib.toInt (builtins.elemAt m 3)
          else if builtins.elemAt m 0 == "https" then
            443
          else
            80;

        storagePorts = {
          vminsert = lib.toInt (toString (spec.vmstorage.vmInsertPort or 8400));
          vmselect = lib.toInt (toString (spec.vmstorage.vmSelectPort or 8401));
        };
      in
      {
        vmCluster = vmOperator.out.mkVMCluster scope {
          inherit name spec;
        };

        # The operator creates the pods, so no workload policy is derived
        # for them. vminsert writes to vmstorage on its vminsert port and
        # vmselect reads from it on its vmselect port; every component
        # resolves the others through DNS. Clients reach vminsert and
        # vmselect through the ServiceRefs below, and VMAgents reach every
        # component's metrics through the scrape join.
        operandPolicies =
          let
            netpol = scope.networkPolicyEnforcer.netpol;
            ns = scope.namespaceName;
            tcp = port: {
              inherit port;
              protocol = "TCP";
            };
            toStorage =
              component:
              netpol.mkServiceEgressRule {
                selector = componentSelector "vmstorage";
                namespace = ns;
                sourceNamespace = ns;
                ports = [ (tcp storagePorts.${component}) ];
              };
            fromComponent =
              component:
              netpol.mkCallerIngressRule {
                callerSelector = componentSelector component;
                callerNamespace = ns;
                ports = [ (tcp storagePorts.${component}) ];
              };
            policy =
              component: rules:
              kix.operandPolicy (
                {
                  inherit scope;
                  name = "${name}-${component}";
                  selector = componentSelector component;
                }
                // rules
              );
          in
          {
            vmstorage = policy "vmstorage" {
              egress = [
                netpol.dnsEgressRule
              ]
              ++
                lib.optionals (backupPort != null)
                  (netpol.translateIntentRules {
                    intents.backup.egress = [
                      {
                        to = "world";
                        ports = [ (tcp backupPort) ];
                      }
                    ];
                  }).egressRules;
              ingress = [
                (fromComponent "vminsert")
                (fromComponent "vmselect")
              ];
            };
            vminsert = policy "vminsert" {
              egress = [
                netpol.dnsEgressRule
                (toStorage "vminsert")
              ];
            };
            vmselect = policy "vmselect" {
              egress = [
                netpol.dnsEgressRule
                (toStorage "vmselect")
              ];
            };
          };

        # The operator creates the operand Services itself: vmselect-<name>
        # on 8481 and vminsert-<name> on 8480, selecting the pods it stamps
        # with componentSelector. A ServiceRef describes each one, so
        # consumers get out.fqdn with dependency context, the deploy engine
        # waits for the Service to exist, and netpol opens the same edges it
        # would for a rendered Service.
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
          ]
          ++ builtins.filter (p: p != null) (builtins.attrValues self.operandPolicies);
          out = {
            # URLs are built on the refs' fqdn, so they carry the marker's
            # dependency context and the endpoint fact.
            serviceUrl = "http://${self.selectService.out.fqdn}:8481/select/0/prometheus";
            remoteWriteUrl = "http://${self.insertService.out.fqdn}:8480/insert/0/prometheus/api/v1/write";
            insertBaseUrl = "http://${self.insertService.out.fqdn}:8480/insert/0/prometheus";
            inherit (config) scrapeInterval;
            version = kix.version.ofTag config.clusterVersion;
            # Operand images are reconciled by the operator, not in any
            # Kix-generated pod spec.
            extraImages = [
              "victoriametrics/vmstorage:${config.clusterVersion}"
              "victoriametrics/vmselect:${config.clusterVersion}"
              "victoriametrics/vminsert:${config.clusterVersion}"
            ];
          };
        };
      }
    )

    # DI passes a build function only the arguments its formals name, so
    # the wrapper names every argument kix.alerts reads.
    (
      {
        config,
        scope,
        prometheus ? null,
        ...
      }@args:
      let
        ns = scope.namespaceName;
        # The operator's VMServiceScrape for each component sets `job` to
        # the component's Service name, such as vmstorage-<CR name>
        # (factory/vmscrapes/servicescrape.go at operator v0.75.2). The
        # `service` label is the same, but vmstorage's vmbackupmanager
        # endpoint shares that Service under job
        # `vmstorage-<name>-vmbackupmanager`, so only `job` picks out the
        # component's own process.
        sel = component: ''namespace="${ns}",job="${component}-${name}"'';
        st = sel "vmstorage";
        ins = sel "vminsert";

        rf = config.replicationFactor;
        # extraSpec may set the node count; the merge takes its value.
        storageNodes = (config.extraSpec.vmstorage or { }).replicaCount or config.vmstorage.replicaCount;
        minFree = toString config.metrics.minFreeDiskPercent;

        down = component: selector: {
          expr = "sum by (namespace, job) (up{${selector}}) == 0 or absent(up{${selector}})";
          "for" = "10m";
          severity = "critical";
          summary = "Every ${component} node of a VictoriaMetrics cluster is down.";
          description = "No ${component} of victoria-metrics-cluster ${ns}/${name} has answered a scrape for 10 minutes, so the cluster accepts no new samples. When this fires with many absent() alerts at once, the write path is the cause. Check the ${component}-${name} pods.";
        };
      in
      kix.alerts
        {
          alerts = {
            VMStorageDown = down "vmstorage" st;
            VMInsertDown = down "vminsert" ins;

            VMStorageReadOnly = {
              expr = "max by (namespace, job, pod) (vm_storage_is_read_only{${st}}) > 0";
              "for" = "5m";
              severity = "critical";
              summary = "A vmstorage node is read-only.";
              description = "vmstorage {{ $labels.pod }} in ${ns} has less free disk than -storage.minFreeDiskSpaceBytes and accepts no new samples. vminsert sends its share to the other nodes, which then fill faster; with one node, ingestion has stopped. Free or add disk space.";
            };

            # Usable space is what the node can still write before it turns
            # read-only, measured against the data it already holds.
            VMStorageDiskNearlyFull = {
              expr = "sum by (namespace, job, pod) (vm_free_disk_space_bytes{${st}} - vm_free_disk_space_limit_bytes{${st}}) / (sum by (namespace, job, pod) (vm_free_disk_space_bytes{${st}}) + sum by (namespace, job, pod) (vm_data_size_bytes{${st}})) * 100 < ${minFree}";
              "for" = "30m";
              severity = "warning";
              summary = "A vmstorage node is running out of disk space.";
              description = "vmstorage {{ $labels.pod }} in ${ns} has {{ $value | humanize }}% of its usable disk left; it turns read-only when that reaches 0. Grow the volume, shorten retentionPeriod, or add vmstorage nodes.";
            };
          }
          # With no more nodes than copies, losing nodes either keeps every
          # copy or takes every node down, which VMStorageDown reports.
          // lib.optionalAttrs (storageNodes > rf) {
            VMStorageReplicationLost = {
              expr = "count by (namespace, job) (up{${st}} == 1) <= ${toString (storageNodes - rf)}";
              "for" = "10m";
              severity = "critical";
              summary = "Enough vmstorage nodes are down that some samples have no live copy.";
              description = "Only {{ $value }} of ${toString storageNodes} vmstorage nodes of ${ns}/${name} are up, with replication factor ${toString rf}. Queries for some series return partial results, and losing the down nodes' disks loses those samples. Bring the vmstorage-${name} pods back.";
            };
          }
          // lib.optionalAttrs (rf > 1) {
            VMInsertIncompleteReplication = {
              expr = "sum by (namespace, job) (increase(vm_rpc_rows_incompletely_replicated_total{${ins}}[5m])) > 0";
              "for" = "15m";
              severity = "warning";
              summary = "vminsert is storing samples with fewer copies than the replication factor.";
              description = "vminsert in ${ns} stored {{ $value | humanize }} rows in 5 minutes with fewer than ${toString rf} copies, so losing one more vmstorage node loses them. Check which vmstorage nodes are down or read-only.";
            };
          }
          // {
            # vmstorage sizes its caches from the cgroup memory limit it reads
            # itself (vm_available_memory_bytes), so the threshold follows
            # vmstorage.resources without a copy here.
            VMStorageMemoryNearLimit = {
              expr = "max by (namespace, job, pod) (min_over_time(process_resident_memory_anon_bytes{${st}}[10m]) / vm_available_memory_bytes{${st}}) > 0.8";
              "for" = "15m";
              severity = "warning";
              summary = "A vmstorage node is close to its memory limit.";
              description = "vmstorage {{ $labels.pod }} in ${ns} has used {{ $value | humanizePercentage }} of its memory limit for 15 minutes. An OOM kill drops samples not yet flushed to disk. Raise vmstorage.resources.limits.memory.";
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
  ];
}

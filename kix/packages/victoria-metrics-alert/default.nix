# victoria-metrics-alert — alerting rule evaluation (VMAlert CR ×2) plus
# the Alertmanager it notifies (VMAlertmanager CR ×2)
# (v2_discussions/133 §3.4).
#
# vmalert evaluates VMRules (and, via the operator's converter,
# PrometheusRules) against the cluster's read path and remote-writes
# recording-rule results back through vminsert so they persist. State is
# restored on restart via remoteRead. VMAlertmanager rather than the
# alertmanager package so the prometheus-operator controller isn't
# needed; the routing `config`/`secrets` options mirror the alertmanager
# package's shape (ludo's Telegram wiring is the reference consumer).
#
# Notifier wiring is operator-side service discovery: the VMAlert CR
# selects the VMAlertmanager CR by label, and the operator expands that
# to every alertmanager replica's pod FQDN — which is what Alertmanager
# HA requires (fan-out to all replicas, not a load-balanced Service).
# NOTE the vmalert → alertmanager notifier traffic is therefore between
# operator-created pods with no endpoint fact in any kix manifest — the
# doc 96 netpol blindspot, same class as the intra-VMCluster traffic.
#
# DI deps:
#   vmOperator (required) — VMAlert/VMAlertmanager CRDs + builders
#   vmCluster (required)  — out.serviceUrl (datasource + remoteRead),
#                           out.insertBaseUrl (remoteWrite; vmalert
#                           appends /api/v1/write itself)

{
  scope,
  lib,
  kix,
  availability,
}:
let
  name = scope.instanceName;
  ns = scope.namespaceName;
in
{
  meta = {
    version = "v1.150.0";
    description = "VictoriaMetrics alerting — VMAlert + VMAlertmanager in HA pairs";
    owner = "platform";
    defaultAliases = [ "vmAlert" ];
    k8s.minVersion = "1.25";
  };

  options = {
    image = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "victoriametrics/vmalert";
        tag = "v1.150.0";
      };
    };
    replicaCount = lib.mkOption {
      type = lib.types.int;
      # Two vmalert replicas evaluate every rule from "node" up;
      # alertmanager collapses the duplicate notifications.
      default = kix.availability.pick availability {
        none = 1;
        pod = 1;
        node = 2;
        zone = 2;
      };
      description = ''
        Number of vmalert replicas. Defaults from the cluster's
        availability level (v2_discussions/145).
      '';
    };
    evaluationInterval = lib.mkOption {
      type = lib.types.str;
      default = "30s";
    };
    selectAllByDefault = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Evaluate all VMRules (and converted PrometheusRules) cluster-wide.";
    };
    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
        requests = {
          cpu = "100m";
          memory = "256Mi";
        };
        limits = {
          memory = "512Mi";
        };
      };
    };
    extraArgs = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
    };
    extraSpec = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Extra fields deep-merged into the VMAlert CR spec.";
    };

    alertmanager = {
      image = lib.mkOption {
        type = lib.types.anything;
        default = {
          repository = "quay.io/prometheus/alertmanager";
          tag = "v0.33.1";
        };
      };
      replicaCount = lib.mkOption {
        type = lib.types.int;
        # The pair gossips silences and the notification log, so from
        # "node" up a lost pod does not take them with it.
        default = kix.availability.pick availability {
          none = 1;
          pod = 1;
          node = 2;
          zone = 2;
        };
        description = ''
          Number of VMAlertmanager replicas. Defaults from the cluster's
          availability level (v2_discussions/145).
        '';
      };
      retention = lib.mkOption {
        type = lib.types.str;
        default = "120h";
      };
      storage = lib.mkOption {
        type = lib.types.anything;
        default = null;
        description = ''
          PVC spec for the alertmanager volumeClaimTemplate. null =
          emptyDir: silences and the notification log survive single-pod
          restarts via pair gossip, but a simultaneous restart (node
          reboot) drops them. Set for anything beyond a trial.
        '';
      };
      # Routing config — receivers, routes, etc. Cluster-specific; same
      # shape as the alertmanager package's `config` option.
      config = lib.mkOption {
        type = lib.types.anything;
        default = {
          global.resolve_timeout = "5m";
          route = {
            group_by = [
              "namespace"
              "alertname"
            ];
            group_wait = "30s";
            group_interval = "5m";
            repeat_interval = "12h";
            receiver = "null";
            routes = [
              {
                receiver = "null";
                matchers = [ "alertname = Watchdog" ];
              }
            ];
          };
          receivers = [ { name = "null"; } ];
        };
      };
      secrets = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Secrets mounted into Alertmanager pods (credentials referenced from config).";
      };
      configMaps = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
      resources = lib.mkOption {
        type = lib.types.anything;
        default = {
          requests = {
            cpu = "50m";
            memory = "128Mi";
          };
          limits = {
            memory = "256Mi";
          };
        };
      };
      extraSpec = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        description = "Extra fields deep-merged into the VMAlertmanager CR spec.";
      };
    };
    # After vmalert is ready, run ./health-check.py as a Job in this
    # namespace: every vmalert and alertmanager replica is up, rules
    # loaded, no alert-send, datasource or remote-write errors.
    healthCheck = kix.options.healthCheck;
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
        # Operand pods are rendered by the operator, so kix's derived spread
        # never sees them: the CR carries the rule, but the failure-domain
        # keys come from the cluster (v2_discussions/143 §2), never a literal.
        antiAffinity = component: {
          podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution = map (topologyKey: {
            weight = 100;
            podAffinityTerm = {
              labelSelector.matchLabels = {
                "app.kubernetes.io/name" = component;
                "app.kubernetes.io/instance" = name;
              };
              inherit topologyKey;
            };
          }) clusterConfig.cluster.topology.failureDomainKeys;
        };

        alertmanagerBaseSpec = {
          replicaCount = config.alertmanager.replicaCount;
          image = {
            inherit (config.alertmanager.image) repository tag;
          };
          # out.name carries the store-path edge to the config Secret.
          configSecret = self.alertmanagerConfig.out.name;
          retention = config.alertmanager.retention;
          podDisruptionBudget = {
            maxUnavailable = 1;
          };
          affinity = antiAffinity "vmalertmanager";
          resources = config.alertmanager.resources;
        }
        // lib.optionalAttrs (config.alertmanager.storage != null) {
          storage.volumeClaimTemplate.spec = config.alertmanager.storage;
        }
        // lib.optionalAttrs (config.alertmanager.secrets != [ ]) {
          secrets = config.alertmanager.secrets;
        }
        // lib.optionalAttrs (config.alertmanager.configMaps != [ ]) {
          configMaps = config.alertmanager.configMaps;
        };

        vmAlertBaseSpec = {
          replicaCount = config.replicaCount;
          image = {
            inherit (config.image) repository tag;
          };
          datasource.url = vmCluster.out.serviceUrl;
          remoteWrite.url = vmCluster.out.insertBaseUrl;
          remoteRead.url = vmCluster.out.serviceUrl;
          # Discover the sibling VMAlertmanager by its own labels
          # (out.selector carries the dependency edge); the operator expands
          # the match to every replica's pod FQDN.
          notifiers = [
            {
              selector = {
                namespaceSelector.matchNames = [ ns ];
                labelSelector.matchLabels = self.vmAlertmanager.out.selector;
              };
            }
          ];
          evaluationInterval = config.evaluationInterval;
          selectAllByDefault = config.selectAllByDefault;
          podDisruptionBudget = {
            maxUnavailable = 1;
          };
          affinity = antiAffinity "vmalert";
          resources = config.resources;
        }
        // lib.optionalAttrs (config.extraArgs != { }) {
          extraArgs = config.extraArgs;
        };
      in
      {
        # VMAlertmanager expects the config under key `alertmanager.yaml`
        # (mounted at /etc/alertmanager/config). JSON is valid YAML.
        alertmanagerConfig = scope.mkSecret {
          name = "${name}-alertmanager-config";
          stringData."alertmanager.yaml" = builtins.toJSON config.alertmanager.config;
        };

        vmAlertmanager = vmOperator.out.mkVMAlertmanager scope {
          inherit name;
          spec = lib.recursiveUpdate alertmanagerBaseSpec config.alertmanager.extraSpec;
        };

        vmAlert = vmOperator.out.mkVMAlert scope {
          inherit name;
          spec = lib.recursiveUpdate vmAlertBaseSpec config.extraSpec;
        };

        root = {
          resource = self.vmAlert;
          out = {
            extraImages = [
              "${config.image.repository}:${config.image.tag}"
              "${config.alertmanager.image.repository}:${config.alertmanager.image.tag}"
            ];
          };
        };
      }
    )

    # Rule evaluation and delivery are healthy (see kix.healthCheck).
    (kix.healthCheck {
      # Reading both CRs' outputs makes the probe wait for both.
      env =
        { self, deps, ... }:
        {
          VMSELECT_URL = deps.vmCluster.out.serviceUrl;
          # What the operator names and sizes each operand, read off the CRs.
          ALERT_JOB = self.vmAlert.out.scrapeJob;
          ALERT_REPLICAS = self.vmAlert.out.replicas;
          ALERTMANAGER_JOB = self.vmAlertmanager.out.scrapeJob;
          ALERTMANAGER_REPLICAS = self.vmAlertmanager.out.replicas;
        };
      script = builtins.readFile ./health-check.py;
    })
  ];
}

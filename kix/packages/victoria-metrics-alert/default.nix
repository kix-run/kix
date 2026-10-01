# victoria-metrics-alert: alerting rule evaluation (VMAlert CR ×2) plus
# the Alertmanager it notifies (VMAlertmanager CR ×2)
# (v2_discussions/133 §3.4).
#
# vmalert evaluates VMRules (and, via the operator's converter,
# PrometheusRules) against the cluster's read path and remote-writes
# recording-rule results back through vminsert so they persist. State is
# restored on restart via remoteRead. VMAlertmanager rather than the
# alertmanager package so the prometheus-operator controller isn't
# needed; the `settings` and `secrets` options have the alertmanager
# package's shape, and both packages render the same default settings.
#
# Notifier wiring is operator-side service discovery: the VMAlert CR
# selects the VMAlertmanager CR by label, and the operator expands that
# to every alertmanager replica's pod FQDN, which is what Alertmanager
# HA requires (fan-out to all replicas, not a load-balanced Service).
# NOTE the vmalert → alertmanager notifier traffic is therefore between
# operator-created pods with no endpoint fact in any kix manifest: the
# doc 96 netpol blindspot, same class as the intra-VMCluster traffic.
#
# DI deps:
#   vmOperator (required)   VMAlert/VMAlertmanager CRDs + builders
#   vmCluster (required)    out.serviceUrl (datasource + remoteRead),
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
  who = "victoria-metrics-alert ${ns}/${name}";

  inherit (import ../victoria-metrics-operator/cr-image.nix { inherit lib kix; })
    crImage
    crImageVersionTag
    ;

  defaultAlertmanagerSettings = import ../alertmanager/default-settings.nix;
in
{
  meta = {
    version = "v1.150.0";
    description = "VictoriaMetrics alerting: VMAlert and VMAlertmanager";
    owner = "platform";
    defaultAliases = [ "vmAlert" ];
    k8s.minVersion = "1.25";
  };

  options = {
    image = kix.options.image {
      repository = "victoriametrics/vmalert";
      tag = "v1.150.0";
      pullPolicy = null;
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
    # No CPU limit: a CFS quota delays rule evaluation under bursts. The
    # memory limit bounds the process.
    resources = kix.options.resources {
      requests = {
        cpu = "100m";
        memory = "256Mi";
      };
      limits = {
        memory = "512Mi";
      };
    };
    extraArgs = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "vmalert flags for the VMAlert CR's `extraArgs`, keyed by flag name without the leading dash.";
    };
    extraSpec = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Extra fields deep-merged into the VMAlert CR spec. The package refuses `datasource.url`, `remoteWrite.url`, `remoteRead.url`, and `notifiers`, which come from the vmCluster dependency and the alertmanager this package runs, and `image`, `replicaCount`, `evaluationInterval`, `selectAllByDefault`, `resources`, and `extraArgs`, which have options of their own.";
    };

    alertmanager = {
      image = kix.options.image {
        repository = "quay.io/prometheus/alertmanager";
        tag = "v0.33.1";
        pullPolicy = null;
        description = "Alertmanager container image for the VMAlertmanager CR. It cannot take a digest: the operator reads the tag as a semantic version to choose feature flags.";
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
      settings = lib.mkOption {
        type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
        default = null;
        defaultText = lib.literalMD "null: the package's configuration, which routes every alert to the receiver `null`";
        description = "The Alertmanager configuration file, alertmanager.yaml (`global`, `route`, `receivers`, `inhibit_rules`, `templates`). A value replaces the package's configuration as a whole rather than merging into it, because the package's routing tree names its own `null` receiver. Null uses the package's configuration, which routes every alert to the receiver `null`.";
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
      # No CPU limit, as for vmalert above.
      resources = kix.options.resources {
        requests = {
          cpu = "50m";
          memory = "128Mi";
        };
        limits = {
          memory = "256Mi";
        };
      };
      extraSpec = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        description = "Extra fields deep-merged into the VMAlertmanager CR spec. The package refuses `configSecret`, which holds `alertmanager.settings`, and `image`, `replicaCount`, `retention`, `storage`, `secrets`, `configMaps`, and `resources`, which have options of their own.";
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
          image = crImageVersionTag "alertmanager.image" config.alertmanager.image;
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
          image = crImage config.image;
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
          stringData."alertmanager.yaml" = builtins.toJSON (
            if config.alertmanager.settings == null then
              defaultAlertmanagerSettings
            else
              config.alertmanager.settings
          );
        };

        vmAlertmanager = vmOperator.out.mkVMAlertmanager scope {
          inherit name;
          spec = kix.mergeGuarded {
            inherit who;
            what = "alertmanager.extraSpec";
            locked = map lib.toList [
              "configSecret"
              "image"
              "replicaCount"
              "retention"
              "storage"
              "secrets"
              "configMaps"
              "resources"
            ];
          } alertmanagerBaseSpec config.alertmanager.extraSpec;
        };

        vmAlert = vmOperator.out.mkVMAlert scope {
          inherit name;
          spec = kix.mergeGuarded {
            inherit who;
            locked = [
              [
                "datasource"
                "url"
              ]
              [
                "remoteWrite"
                "url"
              ]
              [
                "remoteRead"
                "url"
              ]
            ]
            ++ map lib.toList [
              "notifiers"
              "image"
              "replicaCount"
              "evaluationInterval"
              "selectAllByDefault"
              "resources"
              "extraArgs"
            ];
          } vmAlertBaseSpec config.extraSpec;
        };

        root = {
          resource = self.vmAlert;
          out = {
            extraImages = [
              (kix.image.ref config.image)
              (kix.image.ref config.alertmanager.image)
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

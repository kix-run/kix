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
#
# Alerts (a VMRule `<instance>-alerts`, which vmalert evaluates and a
# prometheus-operator Prometheus does not load). They render only when the
# `prometheus` dependency is the VictoriaMetrics operator, because the series come from
# the operator's own scrape of vmalert and Alertmanager:
#   Watchdog                              always firing, severity `none`
#   VMAlertRuleErrors                     stuck state, warning
#   VMAlertNotificationsFailing           stuck state, warning
#   VMAlertRemoteWriteDropping            data at risk, warning
#   VMAlertConfigReloadFailed             stuck state, warning
#   VMAlertmanagerConfigReloadFailed      stuck state, warning
#   VMAlertmanagerNotificationsFailing    stuck state, warning
#   VMAlertmanagerMembersInconsistent     stuck state, warning (only with
#                                         more than one replica)
#
# VictoriaMetrics cannot alert on its own failure. vmalert evaluates every
# rule through vmselect and delivers through this Alertmanager, so when
# vmalert, vmselect, or Alertmanager stops, or the receiver breaks, nothing
# fires, and no rule here checks that vmalert or Alertmanager is up.
# Watchdog is the cover: like kube-prometheus's rule of the same name, it
# always fires, and the site routes it in `alertmanager.settings` to an
# external heartbeat service that pages when it stops arriving. Its
# expression needs no stored data, so it does not cover the write path;
# VMAgentDown in victoria-metrics-agent does.

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
    # The operator scrapes vmalert and Alertmanager whatever this says;
    # `enabled` only switches the package's alert rules.
    metrics.enabled = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Render the package's alert rules, Watchdog included, when the `prometheus` dependency is the VictoriaMetrics operator. The operator's own scrape of vmalert and Alertmanager does not depend on it.";
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
          requires = lib.optional (self.prometheusRules != null) self.prometheusRules;
          out = {
            extraImages = [
              (kix.image.ref config.image)
              (kix.image.ref config.alertmanager.image)
            ];
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
        # The operator's VMServiceScrapes set `job` to each Service's name,
        # which the CRs state as out.scrapeJob. The `service` label is the
        # same, but the config-reloader sidecars share those Services under
        # job `<scrapeJob>-config-reloader`, so only `job` picks out the main
        # process.
        va = ''namespace="${ns}",job="${self.vmAlert.out.scrapeJob}"'';
        am = ''namespace="${ns}",job="${self.vmAlertmanager.out.scrapeJob}"'';
        amReplicas = config.alertmanager.replicaCount;
      in
      kix.alerts
        {
          alerts = {
            # No `for`: the alert exists to fire continuously. Severity `none`
            # is kube-prometheus's value for this rule, which routes match on;
            # it is not one of the levels a page or ticket uses.
            Watchdog = {
              expr = "vector(1)";
              severity = "none";
              labels.namespace = ns;
              summary = "An alert that always fires, to prove the alerting pipeline works.";
              description = "vmalert ${ns}/${name} evaluates this rule through vmselect and sends it through Alertmanager, so it arrives only while the whole pipeline works. Route it to an external heartbeat service that pages when it stops arriving.";
            };
            VMAlertRuleErrors = {
              expr = ''sum by (namespace, job, group) (increase({__name__=~"vmalert_(alerting|recording)_rules_errors_total",${va}}[5m])) > 0'';
              "for" = "15m";
              severity = "warning";
              summary = "vmalert fails to evaluate rules.";
              description = "vmalert ${ns}/${name} failed {{ $value | humanize }} rule evaluations in group {{ $labels.group }} in 5 minutes, so those rules cannot fire. A failing datasource (vmselect) fails every group; otherwise check the group's expressions in the vmalert logs.";
            };
            VMAlertNotificationsFailing = {
              expr = "sum by (namespace, job) (increase(vmalert_alerts_send_errors_total{${va}}[5m])) > 0";
              "for" = "15m";
              severity = "warning";
              summary = "vmalert fails to send alerts to Alertmanager.";
              description = "vmalert ${ns}/${name} failed to send {{ $value | humanize }} alerts to Alertmanager in 5 minutes. This alert arrives only through an Alertmanager replica that still answers. Check the vmalertmanager-${name} pods.";
            };
            VMAlertRemoteWriteDropping = {
              expr = "sum by (namespace, job) (increase(vmalert_remotewrite_dropped_rows_total{${va}}[5m])) > 0";
              "for" = "5m";
              severity = "warning";
              summary = "vmalert is dropping rule results it could not write to vminsert.";
              description = "vmalert ${ns}/${name} dropped {{ $value | humanize }} rows in 5 minutes. Recording rule results are lost, and so is the alert state vmalert restores after a restart, so pending alerts start their `for` over. Check that vminsert accepts writes.";
            };
            VMAlertConfigReloadFailed = {
              expr = "min by (namespace, job) (vmalert_config_last_reload_successful{${va}}) < 1";
              "for" = "10m";
              severity = "warning";
              summary = "vmalert failed to load its rules.";
              description = "A replica of vmalert ${ns}/${name} could not load the rule files the operator generated and still evaluates the previous ones. Check its logs and the VMRule and PrometheusRule objects changed most recently.";
            };
            VMAlertmanagerConfigReloadFailed = {
              expr = "min by (namespace, job) (alertmanager_config_last_reload_successful{${am}}) < 1";
              "for" = "10m";
              severity = "warning";
              summary = "Alertmanager failed to load its configuration.";
              description = "A replica of Alertmanager ${ns}/${name} could not load the configuration in alertmanager.settings and still routes with the previous one. Check its logs.";
            };
            VMAlertmanagerNotificationsFailing = {
              expr = "sum by (namespace, job, integration) (increase(alertmanager_notifications_failed_total{${am}}[15m])) > 0";
              "for" = "15m";
              severity = "warning";
              summary = "Alertmanager fails to deliver notifications to a receiver.";
              description = "Alertmanager ${ns}/${name} failed {{ $value | humanize }} notifications to {{ $labels.integration }} in 15 minutes. This alert arrives only through another receiver that still works. Check the receiver's settings and the Alertmanager logs.";
            };
          }
          # Replicas gossip silences and the notification log; a replica that
          # sees fewer peers sends duplicates and misses silences.
          // lib.optionalAttrs (amReplicas > 1) {
            VMAlertmanagerMembersInconsistent = {
              expr = "min by (namespace, job) (max_over_time(alertmanager_cluster_members{${am}}[5m])) < ${toString amReplicas}";
              "for" = "15m";
              severity = "warning";
              summary = "Alertmanager replicas do not see each other.";
              description = "An Alertmanager replica of ${ns}/${name} sees {{ $value }} of ${toString amReplicas} cluster members, so silences and the notification log are not shared. Check that the vmalertmanager-${name} pods can reach each other on the cluster port.";
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

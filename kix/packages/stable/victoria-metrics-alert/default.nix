# victoria-metrics-alert: alerting rule evaluation (VMAlert CR ×2) plus
# the Alertmanager it notifies (VMAlertmanager CR ×2).
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
# The vmalert -> alertmanager notifier traffic runs between
# operator-created pods with no endpoint fact in any Kix manifest, so the
# package writes the network policy for it (`operandPolicies`), as
# victoria-metrics-cluster does for the traffic between its components.
#
# Dependencies:
#   vmOperator (required)   VMAlert/VMAlertmanager CRDs + builders
#   vmCluster (required)    out.serviceUrl (datasource + remoteRead),
#                           out.insertBaseUrl (remoteWrite; vmalert
#                           appends /api/v1/write itself)
#   alertmanagerConfig (optional)
#                           a secret with the key `alertmanager.yaml`, the
#                           Alertmanager configuration, in place of
#                           `alertmanager.settings`. The CR's `configSecret`
#                           names it and the package renders no
#                           configuration Secret.
#
# Where the Alertmanager configuration comes from, one of three:
#   alertmanager.settings        rendered into a Secret the package
#                                classifies as `configuration`
#                                (`kix.run/classification`), since the
#                                operator mounts the configuration from a
#                                Secret. Credential keys written inline are
#                                refused (alertmanager-inline-secrets.nix).
#   alertmanager.configRawYaml   the same configuration written into the
#                                CR's `configRawYaml`, so no Secret is
#                                rendered. Same refusal of inline credentials.
#   alertmanagerConfig           the dependency above.
# Unset, the package renders its default configuration as `settings` would.
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
  release = "v1.150.0";
  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "victoria-metrics-alert ${ns}/${name}";

  inherit (import ../victoria-metrics-operator/cr-image.nix { inherit lib kix; })
    crImage
    crImageVersionTag
    ;
  inherit (import ../victoria-metrics-operator/operand-placement.nix { inherit lib kix; })
    operandPlacement
    ;

  defaultAlertmanagerSettings = import ./alertmanager-default-settings.nix;
  refuseInlineSecrets = import ./alertmanager-inline-secrets.nix {
    inherit lib;
    fail = scope.fail;
  };
  receiverPorts = import ./alertmanager-receiver-ports.nix {
    inherit lib;
    fail = scope.fail;
  };
in
{
  meta = {
    version = lib.removePrefix "v" release;
    description = "VictoriaMetrics alerting: VMAlert and VMAlertmanager";
    owner = "platform";
    defaultAliases = [ "vmAlert" ];
    k8s.minVersion = "1.25";
  };

  options = {
    image = kix.options.image {
      repository = "docker.io/victoriametrics/vmalert";
      tag = release;
      digest = "sha256:c6e6c1ef6e43c09510dd0aff264bf0ea319c1bdfced1ccc79dad1545950a7989";
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
        availability level.
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
      description = "Extra fields deep-merged into the VMAlert CR spec. The package refuses `datasource.url`, `remoteWrite.url`, `remoteRead.url`, and `notifiers`, which come from the vmCluster dependency and the alertmanager this package runs, and `image`, `replicaCount`, `evaluationInterval`, `selectAllByDefault`, `resources`, and `extraArgs`, which have options of their own. Setting `topologySpreadConstraints` here replaces the default pod spread constraints set from the availability level.";
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
          availability level.
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
        description = "The Alertmanager configuration file, alertmanager.yaml (`global`, `route`, `receivers`, `inhibit_rules`, `templates`), rendered into a Secret the CR's `configSecret` names. A value replaces the package's configuration as a whole rather than merging into it, because the package's routing tree names its own `null` receiver. Null uses the package's configuration, which routes every alert to the receiver `null`. A credential written inline (`auth_password`, `routing_key`, `api_key`, a Slack `api_url`, and the like) is refused: take it from a file (`api_url_file`, `password_file`, `credentials_file`) mounted through `secrets`. Mutually exclusive with `configRawYaml` and the `alertmanagerConfig` dependency.";
      };
      configRawYaml = lib.mkOption {
        type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
        default = null;
        description = "The Alertmanager configuration file, written into the CR's `configRawYaml` so that the package renders no configuration Secret. Same content and the same refusal of inline credentials as `settings`. Mutually exclusive with `settings` and the `alertmanagerConfig` dependency.";
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
        description = "Extra fields deep-merged into the VMAlertmanager CR spec. The package refuses `configSecret` and `configRawYaml`, which the configuration options and the `alertmanagerConfig` dependency decide, and `image`, `replicaCount`, `retention`, `storage`, `secrets`, `configMaps`, and `resources`, which have options of their own. Setting `topologySpreadConstraints` here replaces the default pod spread constraints set from the availability level.";
      };
    };
    # The operator scrapes vmalert and Alertmanager whatever this says;
    # `enabled` only switches the package's alert rules.
    metrics = kix.options.alerts;
    # After vmalert is ready, run ./health-check.py as a Job in this
    # namespace: every vmalert and alertmanager replica is up, rules
    # loaded, and no alert-send, datasource, or remote-write errors.
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
        alertmanagerConfig ? null,
        ...
      }:
      let
        am = config.alertmanager;
        configRoutes =
          lib.optional (am.settings != null) "alertmanager.settings"
          ++ lib.optional (am.configRawYaml != null) "alertmanager.configRawYaml"
          ++ lib.optional (alertmanagerConfig != null) "the alertmanagerConfig dependency";
        configDep =
          if builtins.length configRoutes > 1 then
            scope.fail {
              package = "victoria-metrics-alert";
              message = "${lib.concatStringsSep " and " configRoutes} are set, and each supplies the whole Alertmanager configuration.";
              fix = "Keep one.";
            }
          else
            kix.contracts.secret.helpers.use {
              inherit who;
              arg = "alertmanagerConfig";
              dep = alertmanagerConfig;
              keys = [ "alertmanager.yaml" ];
            };
        # The configuration Kix renders, as JSON (valid YAML), or null when
        # the dependency supplies it.
        amSettings =
          if configDep != null then
            null
          else
            refuseInlineSecrets (
              if am.configRawYaml != null then
                am.configRawYaml
              else if am.settings != null then
                am.settings
              else
                defaultAlertmanagerSettings
            );
        renderedConfig = if amSettings == null then null else builtins.toJSON amSettings;
        configInCr = am.configRawYaml != null;
        placement =
          component: replicas:
          operandPlacement {
            inherit availability replicas;
            topology = clusterConfig.cluster.topology;
            selector = {
              "app.kubernetes.io/name" = component;
              "app.kubernetes.io/instance" = name;
            };
          };

        alertmanagerBaseSpec = {
          replicaCount = config.alertmanager.replicaCount;
          image = crImageVersionTag scope.fail "alertmanager.image" config.alertmanager.image;
          retention = config.alertmanager.retention;
          resources = config.alertmanager.resources;
        }
        // placement "vmalertmanager" config.alertmanager.replicaCount
        // lib.optionalAttrs configInCr { configRawYaml = renderedConfig; }
        // lib.optionalAttrs (configDep != null) { configSecret = configDep.out.name; }
        # out.name carries the store-path edge to the config Secret.
        // lib.optionalAttrs (!configInCr && configDep == null) {
          configSecret = self.configSecret.out.name;
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
          resources = config.resources;
        }
        // placement "vmalert" config.replicaCount
        // lib.optionalAttrs (config.extraArgs != { }) {
          extraArgs = config.extraArgs;
        };
      in
      {
        # VMAlertmanager expects the config under key `alertmanager.yaml`
        # (mounted at /etc/alertmanager/config). Null when the configuration
        # goes into the CR or comes from the dependency.
        configSecret =
          if configInCr || configDep != null then
            null
          else
            scope.mkSecret {
              name = "${name}-alertmanager-config";
              stringData."alertmanager.yaml" = renderedConfig;
              # Configuration the operator mounts from a Secret; the
              # credential keys the package knows are refused above.
              meta.classification = "configuration";
            };

        vmAlertmanager = vmOperator.out.mkVMAlertmanager scope {
          inherit name;
          spec = kix.mergeGuarded {
            inherit who;
            what = "alertmanager.extraSpec";
            locked = map lib.toList [
              "configSecret"
              "configRawYaml"
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

        # The operator creates the vmalert and Alertmanager pods, so no
        # workload policy is derived for them. Both config-reloader sidecars
        # call the API server. vmalert notifies every Alertmanager replica
        # by pod address, the replicas gossip with each other, and
        # Alertmanager delivers to the receivers its configuration names.
        # vmalert's paths to vmselect and vminsert come from the VMAlert
        # CRD's factBehavior, and the scrape paths from the netpol
        # scrape join. A configuration from the alertmanagerConfig
        # dependency opens no receiver ports.
        operandPolicies =
          let
            netpol = scope.networkPolicyEnforcer.netpol;
            # The port the operator serves Alertmanager on, which
            # alertmanager.extraSpec may change.
            amPort = {
              port = lib.toInt (toString (self.vmAlertmanager.rawManifest.spec.port or 9093));
              protocol = "TCP";
            };
            alertSelector = {
              "app.kubernetes.io/name" = "vmalert";
              "app.kubernetes.io/instance" = name;
            };
            amSelector = {
              "app.kubernetes.io/name" = "vmalertmanager";
              "app.kubernetes.io/instance" = name;
            };
            peers = netpol.mkSelfRules { selector = amSelector; };
            ports = if amSettings == null then [ ] else receiverPorts amSettings;
            replicas = config.alertmanager.replicaCount;
          in
          {
            vmalert = kix.operandPolicy {
              inherit scope;
              name = "${name}-vmalert";
              spec = {
                endpointSelector.matchLabels = alertSelector;
                egress = [
                  netpol.dnsEgressRule
                  netpol.apiServerEgressRule
                  (netpol.mkServiceEgressRule {
                    selector = amSelector;
                    namespace = ns;
                    sourceNamespace = ns;
                    ports = [ amPort ];
                  })
                ];
              };
            };
            alertmanager = kix.operandPolicy {
              inherit scope;
              name = "${name}-vmalertmanager";
              spec = {
                endpointSelector.matchLabels = amSelector;
                egress = [
                  netpol.dnsEgressRule
                  netpol.apiServerEgressRule
                ]
                ++ lib.optionals (replicas > 1) peers.egress
                ++
                  lib.optionals (ports != [ ])
                    (netpol.translateIntentRules {
                      intents.receivers.egress = [
                        {
                          to = "world";
                          ports = map (port: {
                            inherit port;
                            protocol = "TCP";
                          }) ports;
                        }
                      ];
                    }).egressRules;
                ingress = [
                  (netpol.mkCallerIngressRule {
                    callerSelector = alertSelector;
                    callerNamespace = ns;
                    ports = [ amPort ];
                  })
                ]
                ++ lib.optionals (replicas > 1) peers.ingress;
              };
            };
          };

        root = {
          resource = self.vmAlert;
          requires = builtins.filter (p: p != null) (builtins.attrValues self.operandPolicies);
          out = {
            version = kix.image.version config.image;
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

# Tests for the monitoring packages: prometheus-operator, prometheus,
# alertmanager, grafana, kube-state-metrics, and prometheus-default-rules.
# Each cluster puts the package under test in `monitoring` beside a real
# prometheus-operator; the refusals are paired with a cluster that differs
# only in the refused value.

{
  lib,
  mkCluster,
  baseInstances,
  netpolOn,
  manifests,
  ofKind,
  byName,
  evalFails,
  ...
}:

let
  pkg = name: import ../../../packages/${name};

  show = builtins.toJSON;

  clusterWith =
    {
      instances ? { },
      extra ? { },
    }:
    mkCluster [
      { instances.dns = baseInstances.instances.dns; }
      {
        instances.monitoring = lib.recursiveUpdate {
          prometheus-operator.package = pkg "prometheus-operator";
        } instances;
      }
      extra
    ];

  # The server instance is not named `prometheus`: an instance name answers
  # a dependency of that name, and `prometheus` is the operator's alias.
  server = config: {
    prometheus-server = {
      package = pkg "prometheus";
      inherit config;
    };
  };

  one = name: config: {
    ${name} = {
      package = pkg name;
      inherit config;
    };
  };

  grafanaAdmin = keys: {
    grafana-admin = {
      package = pkg "secret";
      aliases = [ "grafanaAdmin" ];
      config.stringData = lib.genAttrs keys (_: "test-only");
    };
  };
  grafanaWith =
    config:
    clusterWith {
      instances =
        one "grafana" config
        // grafanaAdmin [
          "admin-user"
          "admin-password"
        ];
    };

  kindIn = kind: cluster: ofKind kind (manifests cluster);
  prometheusCr = cluster: builtins.head (kindIn "Prometheus" cluster);
  alertmanagerCr = cluster: builtins.head (kindIn "Alertmanager" cluster);
  grafanaDeployment = cluster: byName "grafana" (kindIn "Deployment" cluster);
  grafanaIni = cluster: (byName "grafana-config" (kindIn "ConfigMap" cluster)).data."grafana.ini";
  ruleNamed = name: cluster: byName name (kindIn "PrometheusRule" cluster);
in
{
  # The config-reloader's pull policy comes from the Prometheus or
  # Alertmanager resource, so setting it on the operator is refused.
  monitoring-stack-operator-reloader-pull-policy-refused =
    (
      !(evalFails (clusterWith { }))
      && evalFails (clusterWith {
        instances.prometheus-operator.config.operandImages.prometheus-config-reloader.pullPolicy = "Always";
      })
    )
    || throw "the reloader pullPolicy refusal did not fire";

  # The CRDs and ClusterRole are vendored from one release; another minor
  # version is refused, a patch of the same minor is not.
  monitoring-stack-operator-tag-minor-refused =
    (
      !(evalFails (clusterWith {
        instances.prometheus-operator.config.image.tag = "v0.92.9";
      }))
      && evalFails (clusterWith {
        instances.prometheus-operator.config.image.tag = "v0.93.0";
      })
    )
    || throw "the image.tag minor refusal did not fire";

  # extraArgs appends flags and refuses the ones the package owns.
  monitoring-stack-operator-owned-flags =
    let
      args =
        cluster:
        (builtins.head (byName "prometheus-operator" (kindIn "Deployment" cluster))
          .spec.template.spec.containers).args;
      plus = clusterWith { instances.prometheus-operator.config.extraArgs = [ "--log-level=debug" ]; };
    in
    (
      lib.last (args plus) == "--log-level=debug"
      && evalFails (clusterWith {
        instances.prometheus-operator.config.extraArgs = [ "--kubelet-service=default/k" ];
      })
    )
    || throw "operator args: ${show (args plus)}";

  # Prometheus names the Alertmanager it binds, and only then.
  monitoring-stack-prometheus-alerting-from-dependency =
    let
      alone = prometheusCr (clusterWith {
        instances = server { };
      });
      paired = prometheusCr (clusterWith {
        instances = server { } // one "alertmanager" { };
      });
    in
    (
      !(alone.spec ? alerting)
      && alone.spec.enableAdminAPI == false
      &&
        paired.spec.alerting.alertmanagers == [
          {
            name = "alertmanager-operated";
            namespace = "monitoring";
            port = "web";
            apiVersion = "v2";
          }
        ]
    )
    || throw "prometheus alerting: ${show paired.spec}";

  # extraSpec reaches the resource; the paths the package sets are refused.
  monitoring-stack-prometheus-extra-spec =
    let
      spec =
        (prometheusCr (clusterWith {
          instances = server { extraSpec.retention = "30d"; };
        })).spec;
    in
    (
      spec.retention == "30d"
      && evalFails (clusterWith {
        instances = server { extraSpec.replicas = 3; };
      })
      && evalFails (clusterWith {
        instances = server { } // one "alertmanager" { };
        extra.instances.monitoring.prometheus-server.config.extraSpec.alerting = { };
      })
    )
    || throw "prometheus extraSpec: ${show spec}";

  # storage.size gives a claim template; a class without a size is refused.
  monitoring-stack-prometheus-storage =
    let
      spec =
        (prometheusCr (clusterWith {
          instances = server {
            storage = {
              size = "20Gi";
              storageClassName = "fast";
            };
          };
        })).spec;
    in
    (
      spec.storage.volumeClaimTemplate.spec == {
        accessModes = [ "ReadWriteOnce" ];
        resources.requests.storage = "20Gi";
        storageClassName = "fast";
      }
      && evalFails (clusterWith {
        instances = server { storage.storageClassName = "fast"; };
      })
    )
    || throw "prometheus storage: ${show spec}";

  # The receivers in settings decide the world egress ports. The stub
  # enforcer translates intents to nothing, so the derivation is checked
  # through its pure function and the policy through its presence.
  monitoring-stack-alertmanager-receiver-ports =
    let
      portsOf = import ../../../packages/alertmanager/receiver-ports.nix {
        inherit lib;
        who = "alertmanager test/test";
      };
      fails = settings: !(builtins.tryEval (builtins.deepSeq (portsOf settings) true)).success;
      routed = {
        global.smtp_smarthost = "smtp.example.com:25";
        receivers = [
          { name = "null"; }
          {
            name = "team";
            slack_configs = [ { api_url = "https://hooks.slack.com/services/x"; } ];
            webhook_configs = [ { url = "http://[fd00::1]:8080/alert"; } ];
            pagerduty_configs = [ { routing_key_file = "/etc/alertmanager/secrets/pd/key"; } ];
            email_configs = [
              { to = "ops@example.com"; }
              {
                to = "dev@example.com";
                smarthost = "mail.example.com:587";
              }
            ];
          }
        ];
      };
      am =
        settings:
        clusterWith {
          instances = one "alertmanager" { inherit settings; };
          extra = netpolOn // {
            cluster.availability.default = "none";
          };
        };
      egress = cluster: byName "alertmanager-egress" (manifests cluster);
    in
    (
      portsOf routed == [
        25
        443
        587
        8080
      ]
      && portsOf { receivers = [ { name = "null"; } ]; } == [ ]
      && egress (am null) == null
      && egress (am routed) != null
      && fails {
        receivers = [
          {
            name = "mail";
            email_configs = [ { to = "ops@example.com"; } ];
          }
        ];
      }
      && fails {
        receivers = [
          {
            name = "hook";
            webhook_configs = [ { url = "hooks.example.com/alert"; } ];
          }
        ];
      }
    )
    || throw "alertmanager receiver ports: ${show (portsOf routed)}";

  # The configuration Secret is the resource's configSecret, and extraSpec
  # may not replace it.
  monitoring-stack-alertmanager-config-secret =
    let
      spec =
        (alertmanagerCr (clusterWith {
          instances = one "alertmanager" { };
        })).spec;
    in
    (
      spec.configSecret == "alertmanager-config"
      && evalFails (clusterWith {
        instances = one "alertmanager" { extraSpec.configSecret = "other"; };
      })
    )
    || throw "alertmanager configSecret: ${show spec}";

  # The administrator's secret must declare both keys.
  monitoring-stack-grafana-admin-keys =
    (
      !(evalFails (grafanaWith { }))
      && evalFails (clusterWith {
        instances = one "grafana" { } // grafanaAdmin [ "admin-password" ];
      })
    )
    || throw "the grafanaAdmin key check did not fire";

  # A datasource may not reuse the name or uid of a wired one.
  monitoring-stack-grafana-datasource-clash =
    let
      withProm =
        datasources:
        clusterWith {
          instances =
            one "grafana" { inherit datasources; }
            // server { }
            // grafanaAdmin [
              "admin-user"
              "admin-password"
            ];
        };
    in
    (
      !(evalFails (withProm [
        {
          name = "Tempo";
          type = "tempo";
          uid = "tempo";
        }
      ]))
      && evalFails (withProm [
        {
          name = "Other";
          type = "prometheus";
          uid = "prometheus";
        }
      ])
    )
    || throw "the datasource clash check did not fire";

  # settings merges over the package's grafana.ini, null removes a key, and
  # the keys the package owns are refused.
  monitoring-stack-grafana-settings =
    let
      ini = grafanaIni (grafanaWith {
        settings = {
          server.root_url = "https://grafana.example.com";
          log.mode = null;
        };
      });
    in
    (
      lib.hasInfix "root_url = https://grafana.example.com" ini
      && !(lib.hasInfix "mode = console" ini)
      && lib.hasInfix "reporting_enabled = false" ini
      && evalFails (grafanaWith {
        settings.paths.data = "/data";
      })
      && evalFails (grafanaWith {
        settings.security.admin_password = "x";
      })
      && evalFails (grafanaWith {
        env.GF_SECURITY_ADMIN_PASSWORD = "x";
      })
    )
    || throw "grafana.ini: ${ini}";

  # With the datasources sidecar off, the ConfigMap is mounted directly and
  # carries no sidecar label.
  monitoring-stack-grafana-datasources-without-sidecar =
    let
      cluster = grafanaWith { sidecar.datasources.enabled = false; };
      volumes = (grafanaDeployment cluster).spec.template.spec.volumes;
      cm = byName "grafana-datasources" (kindIn "ConfigMap" cluster);
    in
    (
      builtins.any (v: (v.configMap.name or null) == "grafana-datasources") volumes
      && !((cm.metadata.labels or { }) ? grafana_datasource)
    )
    || throw "grafana volumes: ${show volumes}";

  # The rules name the scrape targets' jobs; the Alertmanager group needs an
  # Alertmanager, and an unknown alert in ruleOverrides is refused.
  monitoring-stack-default-rules-jobs =
    let
      rules =
        instances:
        clusterWith {
          instances = one "prometheus-default-rules" { } // instances;
          # The bridge Services live in kube-system, which an instance there
          # declares.
          extra.instances.kube-system.placeholder = {
            package = pkg "secret";
            config.stringData.unused = "test-only";
          };
        };
      full = rules (
        server { }
        // one "alertmanager" { }
        // {
          ksm.package = pkg "kube-state-metrics";
        }
      );
      text = cluster: name: builtins.toJSON (ruleNamed "prometheus-default-rules-${name}" cluster);
    in
    (
      lib.hasInfix ''job=\"ksm\"'' (text full "kube-state-metrics")
      && lib.hasInfix ''job=\"prometheus-operated\",namespace=\"monitoring\"'' (text full "prometheus")
      && lib.hasInfix ''job=\"alertmanager-operated\",namespace=\"monitoring\"'' (
        text full "alertmanager.rules"
      )
      && lib.hasInfix ''job=\"prometheus-operator\",namespace=\"monitoring\"'' (
        text full "prometheus-operator"
      )
      && ruleNamed "prometheus-default-rules-alertmanager.rules" (rules { }) == null
      && evalFails (
        rules (one "prometheus-default-rules" { ruleOverrides.NoSuchAlert.labels.severity = "info"; })
      )
      && !(evalFails (
        rules (one "prometheus-default-rules" { ruleOverrides.Watchdog.labels.severity = "info"; })
      ))
    )
    || throw "default rules: ${text full "kube-state-metrics"}";

  # kube-state-metrics refuses the flags its probes and Service read.
  monitoring-stack-kube-state-metrics-owned-flags =
    (
      !(evalFails (clusterWith {
        instances = one "kube-state-metrics" { extraArgs = [ "--resources=pods" ]; };
      }))
      && evalFails (clusterWith {
        instances = one "kube-state-metrics" { extraArgs = [ "--port=9000" ]; };
      })
    )
    || throw "the kube-state-metrics flag refusal did not fire";
}

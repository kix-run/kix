# Tests for the monitoring packages: prometheus-operator, prometheus,
# alertmanager, grafana, node-exporter, kube-state-metrics, and
# prometheus-default-rules.
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
  eval,
  storageClassImport,
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
      && !(evalFails (clusterWith {
        instances.prometheus-operator.config.extraArgs = [ "--kubelet-endpointslice=false" ];
      }))
      && evalFails (clusterWith {
        instances.prometheus-operator.config.extraArgs = [ "--kubelet-endpointslice" ];
      })
      && evalFails (clusterWith {
        instances.prometheus-operator.config.extraArgs = [ "--kubelet-endpointslice=true" ];
      })
    )
    || throw "operator args: ${show (args plus)}";

  # Prometheus names the Alertmanager it binds, and only then; a dependency
  # that is not an alertmanager instance is refused.
  monitoring-stack-prometheus-alerting-from-dependency =
    let
      alone = prometheusCr (clusterWith {
        instances = server { };
      });
      paired = prometheusCr (clusterWith {
        instances = server { } // one "alertmanager" { };
      });
      imported =
        out:
        clusterWith {
          instances = server { } // {
            external-am = {
              package = eval.mkImport { inherit out; };
              aliases = [ "alertmanager" ];
            };
          };
        };
    in
    (
      !(alone.spec ? alerting)
      && alone.spec.enableAdminAPI == false
      &&
        paired.spec.alerting.alertmanagers == [
          {
            name = "alertmanager";
            namespace = "monitoring";
            port = "web";
            apiVersion = "v2";
          }
        ]
      && !(evalFails (imported {
        name = "am";
        namespace = "monitoring";
        portName = "web";
      }))
      && evalFails (imported {
        name = "am";
        serviceUrl = "http://am.example.com:9093";
      })
    )
    || throw "prometheus alerting: ${show paired.spec}";

  # Each instance renders its own governing Service over its own pods, so
  # two instances in one namespace do not share a Service, a self-scrape
  # target, or an Alertmanager.
  monitoring-stack-two-instances-in-one-namespace =
    let
      cluster = clusterWith {
        instances = {
          prom-a.package = pkg "prometheus";
          prom-b.package = pkg "prometheus";
          am-a.package = pkg "alertmanager";
          am-b.package = pkg "alertmanager";
        };
        # Each Prometheus binds one Alertmanager.
        extra =
          { ref, ... }:
          {
            instances.monitoring = {
              prom-a.deps.alertmanager = ref.monitoring.am-a;
              prom-b.deps.alertmanager = ref.monitoring.am-b;
            };
          };
      };
      ms = manifests cluster;
      svc = n: byName n (ofKind "Service" ms);
      cr = kind: n: byName n (ofKind kind ms);
      monitorSelector = n: (byName n (ofKind "ServiceMonitor" ms)).spec.selector.matchLabels;
    in
    (
      (svc "prom-a").spec.selector."operator.prometheus.io/name" == "prom-a"
      && (svc "prom-b").spec.selector."operator.prometheus.io/name" == "prom-b"
      && (svc "am-b").spec.selector.alertmanager == "am-b"
      && (svc "am-a").spec.publishNotReadyAddresses
      && (cr "Prometheus" "prom-a").spec.serviceName == "prom-a"
      && (cr "Alertmanager" "am-b").spec.serviceName == "am-b"
      && monitorSelector "prom-a" != monitorSelector "prom-b"
      && (builtins.head (cr "Prometheus" "prom-b").spec.alerting.alertmanagers).name == "am-b"
      && byName "prometheus-operated" (ofKind "Service" ms) == null
    )
    || throw "two instances: ${show (map (m: m.metadata.name) (ofKind "Service" ms))}";

  # The governing Service selects pods no Kix workload renders; its
  # operand-of annotation keeps the selectorCoherence rule quiet.
  monitoring-stack-operand-service-not-flagged =
    let
      cluster = clusterWith { instances = server { } // one "alertmanager" { }; };
      findings = builtins.filter (f: lib.hasSuffix "selectorCoherence" (f.rule or "")) (
        (cluster.scorecardReport or { findings = [ ]; }).findings
      );
    in
    findings == [ ] || throw "selectorCoherence findings: ${show findings}";

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
      && evalFails (clusterWith {
        instances = server { extraSpec.serviceName = "prometheus-operated"; };
      })
      && evalFails (clusterWith {
        instances = server { extraSpec.topologySpreadConstraints = [ ]; };
      })
    )
    || throw "prometheus extraSpec: ${show spec}";

  # storage.size gives a claim template, in the storageClasses
  # dependency's class when there is one.
  monitoring-stack-prometheus-storage =
    let
      specWith =
        instances:
        (prometheusCr (clusterWith {
          inherit instances;
        })).spec;
      withClass = specWith (
        server { storage.size = "20Gi"; }
        // {
          fast = storageClassImport "fast" // {
            aliases = [ "storageClasses" ];
          };
        }
      );
      withoutClass = specWith (server {
        storage.size = "20Gi";
      });
    in
    (
      withClass.storage.volumeClaimTemplate.spec == {
        accessModes = [ "ReadWriteOnce" ];
        resources.requests.storage = "20Gi";
        storageClassName = "fast";
      }
      && !(withoutClass.storage.volumeClaimTemplate.spec ? storageClassName)
      && !((specWith (server { })) ? storage)
    )
    || throw "prometheus storage: ${show withClass}";

  # The receivers in settings decide the world egress ports: the keys each
  # integration dials, then `global`'s, then its built-in address. Links in
  # the message (icon_url, client_url, Pushover's url) are not read. The
  # stub enforcer translates intents to nothing, so the derivation is
  # checked through its pure function and the policy through its presence.
  monitoring-stack-alertmanager-receiver-ports =
    let
      portsOf = import ../../../packages/alertmanager/receiver-ports.nix {
        inherit lib;
        who = "alertmanager test/test";
      };
      fails = settings: !(builtins.tryEval (builtins.deepSeq (portsOf settings) true)).success;
      only = name: configs: {
        receivers = [ ({ inherit name; } // configs) ];
      };
      routed = {
        global.smtp_smarthost = "smtp.example.com:25";
        receivers = [
          { name = "null"; }
          {
            name = "team";
            slack_configs = [ { api_url_file = "/etc/alertmanager/secrets/slack/url"; } ];
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
      # A Slack webhook from a file, beside an icon on another port.
      &&
        portsOf (
          only "slack" {
            slack_configs = [
              {
                api_url_file = "/etc/alertmanager/secrets/s/url";
                icon_url = "https://cdn.example.com:8443/icon.png";
              }
            ];
          }
        ) == [ 443 ]
      # PagerDuty's documented templated client_url is a link, not an address.
      &&
        portsOf (
          only "pd" {
            pagerduty_configs = [
              {
                routing_key_file = "/etc/alertmanager/secrets/pd/key";
                client_url = ''{{ template "pagerduty.default.clientURL" . }}'';
              }
            ];
          }
        ) == [ 443 ]
      &&
        portsOf (
          {
            global.pagerduty_url = "https://events.example.com:8443/v2/enqueue";
          }
          // only "pd" { pagerduty_configs = [ { routing_key_file = "/k"; } ]; }
        ) == [ 8443 ]
      &&
        portsOf (
          only "push" {
            pushover_configs = [
              {
                user_key_file = "/u";
                token_file = "/t";
                url = "https://status.example.com:9999";
              }
            ];
          }
        ) == [ 443 ]
      && egress (am null) == null
      && egress (am routed) != null
      && fails (only "mail" { email_configs = [ { to = "ops@example.com"; } ]; })
      && fails (only "hook" { webhook_configs = [ { url = "hooks.example.com/alert"; } ]; })
      && fails (only "hook" { webhook_configs = [ { url = "https://{{ .x }}:8443/alert"; } ]; })
      && fails (only "hook" { webhook_configs = [ { send_resolved = true; } ]; })
      && fails (only "x" { carrier_pigeon_configs = [ { } ]; })
    )
    || throw "alertmanager receiver ports: ${show (portsOf routed)}";

  # A credential written inline in settings is refused; its `_file` form is
  # not.
  monitoring-stack-alertmanager-inline-secrets =
    let
      am =
        receiver:
        clusterWith {
          instances = one "alertmanager" {
            settings = {
              route.receiver = "r";
              receivers = [ ({ name = "r"; } // receiver) ];
            };
          };
        };
    in
    (
      !(evalFails (am {
        slack_configs = [
          {
            api_url_file = "/etc/alertmanager/secrets/slack/url";
            http_config.basic_auth = {
              username = "u";
              password_file = "/etc/alertmanager/secrets/slack/password";
            };
          }
        ];
      }))
      && evalFails (am {
        slack_configs = [ { api_url = "https://hooks.slack.com/services/x"; } ];
      })
      && evalFails (am {
        email_configs = [
          {
            to = "ops@example.com";
            smarthost = "smtp.example.com:587";
            auth_password = "x";
          }
        ];
      })
      && evalFails (am {
        webhook_configs = [
          {
            url = "https://hooks.example.com/";
            http_config.basic_auth.password = "x";
          }
        ];
      })
    )
    || throw "the inline-credential refusal did not fire";

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
      && evalFails (clusterWith {
        instances = one "alertmanager" { extraSpec.alertmanagerConfiguration.name = "other"; };
      })
      && evalFails (clusterWith {
        instances = one "alertmanager" { extraSpec.serviceName = "alertmanager-operated"; };
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

  # A secureJsonData value must be a reference Grafana expands, because the
  # datasources ConfigMap is not secret.
  monitoring-stack-grafana-datasource-inline-secret =
    let
      withSecure =
        secureJsonData:
        grafanaWith {
          datasources = [
            {
              name = "Tempo";
              type = "tempo";
              inherit secureJsonData;
            }
          ];
        };
    in
    (
      !(evalFails (withSecure {
        httpHeaderValue1 = "Bearer $TEMPO_TOKEN";
        tlsClientKey = "$__file{/etc/secrets/tempo/key}";
      }))
      && evalFails (withSecure {
        httpHeaderValue1 = "Bearer abc";
      })
    )
    || throw "the inline datasource secret refusal did not fire";

  # A wired datasource from a kix.mkImport needs out.serviceUrl.
  monitoring-stack-grafana-imported-datasources =
    let
      withImport =
        alias: out:
        clusterWith {
          instances =
            one "grafana" { }
            // grafanaAdmin [
              "admin-user"
              "admin-password"
            ]
            // {
              external = {
                package = eval.mkImport { inherit out; };
                aliases = [ alias ];
              };
            };
        };
    in
    (
      !(evalFails (withImport "alertmanager" { serviceUrl = "http://am.example.com:9093"; }))
      && evalFails (withImport "alertmanager" { name = "am"; })
      && !(evalFails (withImport "prometheusServer" { serviceUrl = "http://prom.example.com:9090"; }))
      && evalFails (withImport "prometheusServer" { name = "prom"; })
    )
    || throw "the imported datasource checks did not fire";

  # The sidecars need a source to read.
  monitoring-stack-grafana-sidecar-sources =
    let
      noSources = {
        configMaps = false;
        secrets = false;
      };
    in
    (
      !(evalFails (grafanaWith {
        sidecar = {
          sources = noSources;
          dashboards.enabled = false;
          datasources.enabled = false;
        };
      }))
      && evalFails (grafanaWith {
        sidecar.sources = noSources;
      })
    )
    || throw "the sidecar source assertion did not fire";

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
      # A line break would add sections past the locks.
      && evalFails (grafanaWith {
        settings.server.domain = "x\n[security]\nadmin_password = y";
      })
      && evalFails (grafanaWith {
        settings."auth]\n[security" = { };
      })
      && evalFails (grafanaWith {
        settings.server."a = b" = "c";
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
          nx.package = pkg "node-exporter";
        }
      );
      text = cluster: name: builtins.toJSON (ruleNamed "prometheus-default-rules-${name}" cluster);
    in
    (
      lib.hasInfix ''job=\"ksm\"'' (text full "kube-state-metrics")
      && lib.hasInfix ''job=\"nx\"'' (text full "node-exporter")
      && !(lib.hasInfix ''job=\"node-exporter\"'' (text full "node-exporter"))
      && lib.hasInfix ''job=\"prometheus-server\",namespace=\"monitoring\"'' (text full "prometheus")
      && lib.hasInfix ''job=\"alertmanager\",namespace=\"monitoring\"'' (text full "alertmanager.rules")
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

  # A monitor's endpoint merges over the package's, and the port and path
  # the bridge Service and the rules read are refused.
  monitoring-stack-default-rules-endpoint-lock =
    let
      rules =
        endpoint:
        clusterWith {
          instances = one "prometheus-default-rules" { monitors.coredns = { inherit endpoint; }; };
          extra.instances.kube-system.placeholder = {
            package = pkg "secret";
            config.stringData.unused = "test-only";
          };
        };
      monitor = byName "prometheus-default-rules-coredns" (
        kindIn "ServiceMonitor" (rules {
          interval = "1m";
        })
      );
    in
    (
      (builtins.head monitor.spec.endpoints).interval == "1m"
      && evalFails (rules {
        port = "metrics";
      })
      && evalFails (rules {
        path = "/other";
      })
    )
    || throw "default-rules endpoint: ${show monitor}";

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

  # node-exporter refuses the flags its probes, Service, and host mounts
  # read.
  monitoring-stack-node-exporter-owned-flags =
    let
      withArgs = extraArgs: clusterWith { instances = one "node-exporter" { inherit extraArgs; }; };
    in
    (
      !(evalFails (withArgs [ "--collector.systemd" ]))
      && evalFails (withArgs [ "--web.listen-address=:9200" ])
      && evalFails (withArgs [ "--path.sysfs=/sys" ])
      && evalFails (withArgs [ "--collector.textfile.directory=/tmp" ])
    )
    || throw "the node-exporter flag refusal did not fire";
}

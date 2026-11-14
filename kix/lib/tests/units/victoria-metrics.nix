# Tests for the alert rules of kix/packages/stable/victoria-metrics-operator,
# victoria-metrics-cluster, victoria-metrics-agent, and
# victoria-metrics-alert. Each renders a VMRule `<instance>-alerts`, and the
# last three render it only while their `prometheus` dependency is the
# VictoriaMetrics operator. Everything runs in namespace `monitoring`.
#
# Also the stack's network policy under the stub enforcer: the packages'
# policies for the operator's pods, and the scrape join's paths from
# vmagent to the scrape objects it selects (VMServiceScrapes, converted
# ServiceMonitors, and the operator's own VMServiceScrapes).

{
  lib,
  mkCluster,
  manifests,
  ofKind,
  byName,
  alertRulesOf,
  allSelect,
  prometheusStub,
  baseInstances,
  netpolOn,
  containerBase,
  ...
}:

let
  operatorPackage = import ../../../packages/stable/victoria-metrics-operator;
  clusterPackage = import ../../../packages/stable/victoria-metrics-cluster;
  agentPackage = import ../../../packages/stable/victoria-metrics-agent;
  alertPackage = import ../../../packages/stable/victoria-metrics-alert;

  ns = ''namespace="monitoring"'';

  # The operator `vm-operator`, which holds the `prometheus` alias, and the
  # three operand packages with their configs. `prometheus` is the
  # operands' `prometheus` dependency: "operator" leaves the alias to
  # resolve to the operator, "stub" wires a prometheus-operator stand-in,
  # and "none" takes the alias off the operator so nothing provides it.
  vmStack = args: manifests (vmCluster args);
  vmCluster =
    {
      operatorConfig ? { },
      clusterConfig ? { },
      agentConfig ? { },
      alertConfig ? { },
      prometheus ? "operator",
      extra ? [ ],
    }:
    let
      deps = ref: if prometheus == "stub" then { prometheus = ref.monitoring.prom; } else { };
    in
    mkCluster (
      extra
      ++ [
        (
          { ref, ... }:
          {
            instances.monitoring = {
              vm-operator = {
                package = operatorPackage;
                config = operatorConfig;
              }
              // lib.optionalAttrs (prometheus == "none") {
                aliases = lib.mkForce [ "vmOperator" ];
              };
              vm-cluster = {
                package = clusterPackage;
                config = clusterConfig;
                deps = deps ref;
              };
              vm-agent = {
                package = agentPackage;
                config = agentConfig;
                deps = deps ref;
              };
              vm-alert = {
                package = alertPackage;
                config = alertConfig;
                deps = deps ref;
              };
            }
            // lib.optionalAttrs (prometheus == "stub") {
              prom = {
                package = prometheusStub;
                aliases = lib.mkForce [ ];
              };
            };
          }
        )
      ]
    );

  vmRules = alertRulesOf "VMRule";
  hasAll = names: rules: lib.all (n: rules ? ${n}) names;
  hasNone = names: rules: !lib.any (n: rules ? ${n}) names;

  # An app in namespace `apps` with a Deployment, a Service over it, and a
  # ServiceMonitor over the Service on port 8080.
  # A Deployment whose container sets the environment variables `env`.
  envWorkload = env: {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        deployment = scope.mkDeployment {
          name = "other";
          spec = {
            selector.matchLabels = scope.selectorLabels;
            template = {
              metadata.labels = scope.selectorLabels;
              spec.containers = [
                (
                  {
                    name = "other";
                    image = "example/other:1";
                    env = lib.mapAttrsToList (name: value: { inherit name value; }) env;
                  }
                  // containerBase
                )
              ];
            };
          };
        };
        root.resource = self.deployment;
      };
  };

  scrapedApp = {
    meta.version = "test";
    build =
      {
        self,
        scope,
        prometheus,
        ...
      }:
      {
        deployment = scope.mkDeployment {
          name = "web";
          spec = {
            selector.matchLabels = scope.selectorLabels;
            template = {
              metadata.labels = scope.selectorLabels;
              spec.containers = [
                (
                  {
                    name = "web";
                    image = "example/web:1";
                    ports = [ { containerPort = 8080; } ];
                  }
                  // containerBase
                )
              ];
            };
          };
        };
        service = scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = "web";
          labels = scope.selectorLabels;
          spec = {
            selector = scope.selectorLabels;
            ports = [ { port = 8080; } ];
          };
        };
        serviceMonitor = prometheus.out.mkServiceMonitor scope {
          name = "web";
          labels.team = "apps";
          spec = {
            selector.matchLabels = scope.selectorLabels;
            endpoints = [ { targetPort = 8080; } ];
          };
        };
        root = {
          resource = self.deployment;
          requires = [
            self.service
            self.serviceMonitor
          ];
        };
      };
  };

  # The stack under the stub enforcer, with `scrapedApp` in `apps`.
  netpolStack =
    args:
    vmCluster (
      args
      // {
        extra = [
          { instances.dns = baseInstances.instances.dns; }
          netpolOn
          { instances.apps.web.package = scrapedApp; }
        ];
      }
    );
  cnps = cluster: ofKind "CiliumNetworkPolicy" (manifests cluster);
  policy = name: cluster: byName name (cnps cluster);
  scrapeEgress = policy "vmagent-vm-agent-scrape-egress";
  # The service egress rule of a policy to pods with `app.kubernetes.io/name`
  # `app`, or null.
  egressTo =
    app: p:
    if p == null then
      null
    else
      lib.findFirst (
        r: r.stubRule == "service-egress" && (r.selector."app.kubernetes.io/name" or null) == app
      ) null (p.spec.egress or [ ]);
  portsOf = r: map (p: p.port) r.ports;
  warningsOf = cluster: map (w: w.message) cluster.diagnostics.warnings;
  show = builtins.toJSON;
in
{
  # The operator is the `prometheus` provider itself, so its rules need
  # only metrics on.
  victoria-metrics-operator-alerts =
    let
      on = vmRules "vm-operator" (vmStack { });
    in
    (
      allSelect ''${ns},job="vm-operator"'' on
      && hasAll [ "VMOperatorDown" "VMOperatorReconcileErrors" ] on
      &&
        vmRules "vm-operator" (vmStack {
          operatorConfig.metrics.enabled = false;
        }) == null
    )
    || throw "victoria-metrics-operator alerts: ${builtins.toJSON (builtins.attrNames on)}";

  # Each rule selects vmstorage or vminsert by job. VMStorageReplicationLost
  # needs more vmstorage nodes than the replication factor, and
  # VMInsertIncompleteReplication a factor above 1.
  victoria-metrics-cluster-alerts =
    let
      rulesOf = clusterConfig: args: vmRules "vm-cluster" (vmStack ({ inherit clusterConfig; } // args));
      sized =
        rf: nodes:
        rulesOf {
          replicationFactor = rf;
          vmstorage.replicaCount = nodes;
        } { };
      wide = sized 2 3;
      selects =
        r:
        lib.hasInfix ''${ns},job="vmstorage-vm-cluster"'' r.expr
        || lib.hasInfix ''${ns},job="vminsert-vm-cluster"'' r.expr;
    in
    (
      wide != null
      && lib.all selects (lib.attrValues wide)
      && hasAll [
        "VMStorageDown"
        "VMInsertDown"
        "VMStorageReplicationLost"
        "VMInsertIncompleteReplication"
      ] wide
      && hasNone [ "VMStorageReplicationLost" ] (sized 2 2)
      && (sized 2 2) ? VMInsertIncompleteReplication
      && (sized 1 3) ? VMStorageReplicationLost
      && hasNone [ "VMInsertIncompleteReplication" ] (sized 1 3)
      && hasNone [ "VMStorageReplicationLost" "VMInsertIncompleteReplication" ] (sized 1 1)
      && rulesOf { metrics.enabled = false; } { } == null
      && rulesOf { } { prometheus = "stub"; } == null
      && rulesOf { } { prometheus = "none"; } == null
    )
    || throw "victoria-metrics-cluster alerts: ${builtins.toJSON (builtins.attrNames wide)}";

  victoria-metrics-agent-alerts =
    let
      rulesOf = args: vmRules "vm-agent" (vmStack args);
      on = rulesOf { };
    in
    (
      allSelect ''${ns},job="vmagent-vm-agent"'' on
      && on ? VMAgentDown
      && rulesOf { agentConfig.metrics.enabled = false; } == null
      && rulesOf { prometheus = "stub"; } == null
      && rulesOf { prometheus = "none"; } == null
    )
    || throw "victoria-metrics-agent alerts: ${builtins.toJSON (builtins.attrNames on)}";

  # Every rule but Watchdog selects vmalert or Alertmanager by job; Watchdog
  # is `vector(1)` and carries the namespace as a label instead.
  # VMAlertmanagerMembersInconsistent needs more than one Alertmanager.
  victoria-metrics-alert-alerts =
    let
      rulesOf = args: vmRules "vm-alert" (vmStack args);
      pair = rulesOf { alertConfig.alertmanager.replicaCount = 2; };
      single = rulesOf { alertConfig.alertmanager.replicaCount = 1; };
      selects =
        r:
        lib.hasInfix ''${ns},job="vmalert-vm-alert"'' r.expr
        || lib.hasInfix ''${ns},job="vmalertmanager-vm-alert"'' r.expr;
    in
    (
      lib.all selects (lib.attrValues (removeAttrs pair [ "Watchdog" ]))
      && pair.Watchdog.labels.namespace == "monitoring"
      && pair ? VMAlertmanagerMembersInconsistent
      && single ? VMAlertRuleErrors
      && !(single ? VMAlertmanagerMembersInconsistent)
      && rulesOf { alertConfig.metrics.enabled = false; } == null
      && rulesOf { prometheus = "stub"; } == null
      && rulesOf { prometheus = "none"; } == null
    )
    || throw "victoria-metrics-alert alerts: ${builtins.toJSON (builtins.attrNames pair)}";

  # vminsert and vmselect reach vmstorage on their own ports, and vmstorage
  # admits each from its own component only.
  victoria-metrics-cluster-component-policies =
    let
      c = netpolStack { };
      storage = policy "vm-cluster-vmstorage" c;
      insert = egressTo "vmstorage" (policy "vm-cluster-vminsert" c);
      select = egressTo "vmstorage" (policy "vm-cluster-vmselect" c);
      callers = map (r: {
        caller = r.callerSelector."app.kubernetes.io/name";
        ports = portsOf r;
      }) storage.spec.ingress;
    in
    (
      portsOf insert == [ 8400 ]
      && portsOf select == [ 8401 ]
      &&
        callers == [
          {
            caller = "vminsert";
            ports = [ 8400 ];
          }
          {
            caller = "vmselect";
            ports = [ 8401 ];
          }
        ]
    )
    || throw "vmcluster policies: ${
      show [
        insert
        select
        storage
      ]
    }";

  # With vmstorage.vmBackup, vmbackupmanager in the vmstorage pods reaches
  # the store outside the cluster: on customS3Endpoint's port, else 443. A
  # local `fs://` destination and a cluster without backups open nothing.
  victoria-metrics-cluster-backup-egress =
    let
      worldPorts =
        vmBackup:
        let
          storage = policy "vm-cluster-vmstorage" (
            netpolStack (
              lib.optionalAttrs (vmBackup != null) { clusterConfig.extraSpec.vmstorage.vmBackup = vmBackup; }
            )
          );
        in
        builtins.concatMap (
          r: lib.optionals (r.stubRule == "intent-egress" && r.to == "world") (portsOf r)
        ) storage.spec.egress;
      s3 = worldPorts { destination = "s3://backups/vm"; };
      custom = worldPorts {
        destination = "s3://backups/vm";
        customS3Endpoint = "http://minio.example.com:9000";
      };
      local = worldPorts { destination = "fs:///backups"; };
      none = worldPorts null;
    in
    (s3 == [ 443 ] && custom == [ 9000 ] && local == [ ] && none == [ ])
    || throw "vmstorage backup egress: ${
      show [
        s3
        custom
        local
        none
      ]
    }";

  # The agent reaches the operator's own scrape objects for every operand,
  # with the config-reloader port where a sidecar runs, and each operand
  # admits the agent. A disabled self-scrape opens nothing.
  victoria-metrics-agent-scrapes-operand-self-scrapes =
    let
      c = netpolStack { };
      p = scrapeEgress c;
      ports = app: portsOf (egressTo app p);
      off = scrapeEgress (netpolStack {
        clusterConfig.extraSpec.vmstorage.disableSelfServiceScrape = true;
      });
      storageIngress = builtins.filter (
        m: lib.hasPrefix "monitoring-vmagent-vm-agent-scrape-svc-vmstorage-vm-cluster-" m.metadata.name
      ) (cnps c);
    in
    (
      ports "vmstorage" == [ "8482" ]
      && ports "vmselect" == [ "8481" ]
      && ports "vminsert" == [ "8480" ]
      &&
        ports "vmagent" == [
          "8429"
          "8435"
        ]
      &&
        ports "vmalert" == [
          "8080"
          "8435"
        ]
      &&
        ports "vmalertmanager" == [
          "9093"
          "8435"
        ]
      && builtins.length storageIngress == 1
      && egressTo "vmstorage" off == null
      && egressTo "vmselect" off != null
    )
    || throw "vmagent self scrapes: ${show p}";

  # A ServiceMonitor reaches the agent through the operator's converter,
  # and not once the converter is off.
  victoria-metrics-agent-scrapes-converted-service-monitor =
    let
      on = egressTo "web" (scrapeEgress (netpolStack { }));
      off = egressTo "web" (
        scrapeEgress (netpolStack {
          operatorConfig.convert.serviceMonitors = false;
        })
      );
    in
    (on != null && on.namespace == "apps" && portsOf on == [ "8080" ] && off == null)
    || throw "converted ServiceMonitor: on ${show on}, off ${show off}";

  # The operator reads its boolean variables with Go's strconv.ParseBool.
  # A workload outside the package, such as another operator install, may
  # write the converter variable as "T"; the package's own operator turns
  # the converter off here.
  victoria-metrics-operator-variables-read-as-go-booleans =
    let
      converterSetTo =
        value:
        egressTo "web" (
          scrapeEgress (vmCluster {
            operatorConfig.convert.serviceMonitors = false;
            extra = [
              { instances.dns = baseInstances.instances.dns; }
              netpolOn
              { instances.apps.web.package = scrapedApp; }
              {
                instances.apps.other-operator.package = envWorkload {
                  VM_ENABLEDPROMETHEUSCONVERTER_SERVICESCRAPE = value;
                };
              }
            ];
          })
        );
      selfScrapesSetTo =
        value:
        egressTo "vmstorage" (
          scrapeEgress (netpolStack {
            operatorConfig.env = [
              {
                name = "VM_DISABLESELFSERVICESCRAPECREATION";
                inherit value;
              }
            ];
          })
        );
    in
    (
      converterSetTo "T" != null
      && converterSetTo "1" != null
      && converterSetTo "0" == null
      && selfScrapesSetTo "TRUE" == null
      && selfScrapesSetTo "1" == null
      && selfScrapesSetTo "false" != null
    )
    || throw "operator variables are not read as Go booleans";

  # With both selectors unset, selectAllByDefault decides. An object
  # selector alone reads only the agent's namespace, and a namespace
  # selector reads the namespaces it matches.
  victoria-metrics-agent-scrape-selection =
    let
      webWith =
        agentConfig:
        egressTo "web" (
          scrapeEgress (netpolStack {
            inherit agentConfig;
          })
        );
      none = scrapeEgress (netpolStack {
        agentConfig.selectAllByDefault = false;
      });
      ownNamespace = webWith {
        extraSpec.serviceScrapeSelector.matchLabels.team = "apps";
      };
      appsNamespace = webWith {
        extraSpec = {
          serviceScrapeSelector.matchLabels.team = "apps";
          serviceScrapeNamespaceSelector = { };
        };
      };
      otherTeam = webWith {
        extraSpec = {
          serviceScrapeSelector.matchLabels.team = "platform";
          serviceScrapeNamespaceSelector = { };
        };
      };
    in
    (none == null && ownNamespace == null && appsNamespace != null && otherTeam == null)
    || throw "selection: ${
      show [
        none
        ownNamespace
        appsNamespace
        otherTeam
      ]
    }";

  # vmalert notifies Alertmanager on its port, 9093 unless
  # alertmanager.extraSpec sets another, and Alertmanager admits it.
  victoria-metrics-alert-notifier-policies =
    let
      c = netpolStack { };
      notify = egressTo "vmalertmanager" (policy "vm-alert-vmalert" c);
      am = policy "vm-alert-vmalertmanager" c;
      fromAlertIn =
        p:
        lib.findFirst (
          r: r.stubRule == "caller-ingress" && r.callerSelector."app.kubernetes.io/name" == "vmalert"
        ) null p.spec.ingress;
      fromAlert = fromAlertIn am;
      # alertmanager.extraSpec moves the port, as the self-scrape reads it.
      moved = netpolStack { alertConfig.alertmanager.extraSpec.port = "9095"; };
      movedNotify = egressTo "vmalertmanager" (policy "vm-alert-vmalert" moved);
      movedFromAlert = fromAlertIn (policy "vm-alert-vmalertmanager" moved);
    in
    (
      notify != null
      && portsOf notify == [ 9093 ]
      && fromAlert != null
      && portsOf fromAlert == [ 9093 ]
      && portsOf movedNotify == [ 9095 ]
      && portsOf movedFromAlert == [ 9095 ]
    )
    || throw "notifier policies: ${
      show [
        notify
        am
      ]
    }";

  # Targets Kix does not read are named in a warning.
  victoria-metrics-agent-warns-on-inline-scrape-config =
    let
      warned = warningsOf (netpolStack {
        agentConfig.extraSpec.inlineScrapeConfig = "- job_name: static";
      });
      plain = warningsOf (netpolStack { });
      says = builtins.any (lib.hasInfix "VMAgent monitoring/vm-agent sets spec.inlineScrapeConfig");
    in
    (says warned && !(says plain)) || throw "inline scrape config warnings: ${show warned}";
}

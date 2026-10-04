# Tests for the alert rules of kix/packages/victoria-metrics-operator,
# victoria-metrics-cluster, victoria-metrics-agent, and
# victoria-metrics-alert. Each renders a VMRule `<instance>-alerts`, and the
# last three render it only while their `prometheus` dependency is the
# VictoriaMetrics operator. Everything runs in namespace `monitoring`.

{
  lib,
  mkCluster,
  manifests,
  ofKind,
  alertRulesOf,
  allSelect,
  prometheusStub,
  ...
}:

let
  operatorPackage = import ../../../packages/victoria-metrics-operator;
  clusterPackage = import ../../../packages/victoria-metrics-cluster;
  agentPackage = import ../../../packages/victoria-metrics-agent;
  alertPackage = import ../../../packages/victoria-metrics-alert;

  ns = ''namespace="monitoring"'';

  # The operator `vm-operator`, which holds the `prometheus` alias, and the
  # three operand packages with their configs. `prometheus` is the
  # operands' `prometheus` dependency: "operator" leaves the alias to
  # resolve to the operator, "stub" wires a prometheus-operator stand-in,
  # and "none" takes the alias off the operator so nothing provides it.
  vmStack =
    {
      operatorConfig ? { },
      clusterConfig ? { },
      agentConfig ? { },
      alertConfig ? { },
      prometheus ? "operator",
    }:
    let
      deps = ref: if prometheus == "stub" then { prometheus = ref.monitoring.prom; } else { };
    in
    manifests (mkCluster [
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
    ]);

  vmRules = alertRulesOf "VMRule";
  hasAll = names: rules: lib.all (n: rules ? ${n}) names;
  hasNone = names: rules: !lib.any (n: rules ? ${n}) names;
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
}

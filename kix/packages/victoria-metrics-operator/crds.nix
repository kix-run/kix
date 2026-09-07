# VictoriaMetrics Operator CRD definitions.
#
# Two families:
#   VM-native CRDs — every kind in ./kinds.nix, derived from that table so
#     the set stays complete: the operator crashes at startup if any kind
#     it indexes is missing (see the invariant note in kinds.nix; enforced
#     below with an eval-time throw).
#   prometheus-operator compat CRDs — ServiceMonitor, PodMonitor,
#     PrometheusRule, Probe (monitoring.coreos.com). CRDs only, no
#     prometheus-operator controller: the VM operator's built-in converter
#     watches these and materializes VM equivalents, so existing kix.monitor
#     callers and app-package ServiceMonitors work unchanged.
#
# VMSingle / VMAuth and the logs/traces kinds are still not shipped — the
# operator only gates on the indexed set; add the rest when a consumer
# appears (v2_discussions/133).

{
  self,
  config,
  scope,
  lib,
  ...
}:
let
  vmGroup = "operator.victoriametrics.com";
  inherit (import ./kinds.nix) vmCrdDefs indexedKinds;

  # ── Compile-time guard for the runtime invariant (kinds.nix) ─────────
  shippedKinds = lib.mapAttrsToList (_: def: def.kind) vmCrdDefs;
  missingIndexed = builtins.filter (k: !(builtins.elem k shippedKinds)) indexedKinds;
  guard =
    if missingIndexed == [ ] then
      null
    else
      throw (
        "victoria-metrics-operator: kinds.nix no longer covers the operator's "
        + "startup indexer set — missing: ${builtins.concatStringsSep ", " missingIndexed}. "
        + "The operator crashes at startup (\"cannot register status condition "
        + "indexers\") when any of these CRDs is absent; restore them in kinds.nix."
      );

  labels = {
    "app.kubernetes.io/part-of" = "victoria-metrics-operator";
    "app.kubernetes.io/version" = config.image.tag;
  };

  annotations = {
    "operator.victoriametrics.com/version" = lib.removePrefix "v" config.image.tag;
  };

  ageColumn = [
    {
      jsonPath = ".metadata.creationTimestamp";
      name = "Age";
      type = "date";
    }
  ];

  mkVMOperatorCRD =
    attrs: scope.mkCRD (attrs |> scope.crd.withLabels labels |> scope.crd.withAnnotations annotations);

  # Per-kind extras merged onto the table-derived base.
  #
  # factBehavior — kinds whose operator-created operand pods dial endpoints
  # embedded in the CR spec declare terminate + the operand podSelector so
  # netpol opens egress for the operands, not for whoever references the CR:
  #   VMAgent         remoteWrite[].url
  #   VMAlert         datasource.url, remoteWrite.url, remoteRead.url,
  #                   notifier[].url
  #   VMAlertmanager  receiver endpoints carried in the routing config
  # VMCluster carries no external endpoints (vminsert/vmselect/vmstorage
  # only dial each other, operator-wired — the doc 96 blindspot): explicit
  # conduct so a fact flowing through the CR never warns as undeclared.
  operandFactBehavior = component: {
    endpoint = "terminate";
    podSelector = cr: {
      "app.kubernetes.io/name" = component;
      "app.kubernetes.io/instance" = cr.metadata.name;
    };
  };

  kindExtras = {
    VMCluster = {
      factBehavior.endpoint = "conduct";
      printerColumns = [
        {
          jsonPath = ".spec.retentionPeriod";
          name = "Retention";
          type = "string";
        }
        {
          jsonPath = ".status.updateStatus";
          name = "Status";
          type = "string";
        }
      ]
      ++ ageColumn;
    };
    VMAgent.factBehavior = operandFactBehavior "vmagent";
    VMAlert.factBehavior = operandFactBehavior "vmalert";
    VMAlertmanager.factBehavior = operandFactBehavior "vmalertmanager";
  };

  mkVMKindCRD =
    def:
    let
      extras = kindExtras.${def.kind} or { };
      base =
        scope.crd.fromKind def.kind {
          spec.group = vmGroup;
          spec.names.plural = def.plural;
        }
        |> scope.crd.withVersion def.version
        |> scope.crd.withPrinterColumns (extras.printerColumns or ageColumn);
    in
    mkVMOperatorCRD (
      base
      // lib.optionalAttrs (extras ? factBehavior) {
        inherit (extras) factBehavior;
      }
    );

  vmCrds = lib.mapAttrs (_: mkVMKindCRD) vmCrdDefs;
in
builtins.seq guard {
  crds = vmCrds // {
    # ── prometheus-operator compat CRDs (converter input) ──────────────
    # Same slim schemas as prometheus-operator/crds.nix; shipped here so the
    # converter has something to watch when that package isn't installed.

    serviceMonitors = mkVMOperatorCRD (
      scope.crd.fromKind "ServiceMonitor" { spec.group = "monitoring.coreos.com"; }
      |> scope.crd.withShortNames [ "smon" ]
      |> scope.crd.withPrinterColumns ageColumn
    );

    podMonitors = mkVMOperatorCRD (
      scope.crd.fromKind "PodMonitor" { spec.group = "monitoring.coreos.com"; }
      |> scope.crd.withShortNames [ "pmon" ]
      |> scope.crd.withPrinterColumns ageColumn
    );

    prometheusRules = mkVMOperatorCRD (
      scope.crd.fromKind "PrometheusRule" { spec.group = "monitoring.coreos.com"; }
      |> scope.crd.withShortNames [ "promrule" ]
      |> scope.crd.withPrinterColumns ageColumn
    );

    probes = mkVMOperatorCRD (
      scope.crd.fromKind "Probe" { spec.group = "monitoring.coreos.com"; }
      |> scope.crd.withShortNames [ "prb" ]
      |> scope.crd.withPrinterColumns ageColumn
    );
  };
}

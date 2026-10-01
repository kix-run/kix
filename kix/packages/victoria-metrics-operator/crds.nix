# VictoriaMetrics Operator CRD definitions.
#
# Two families:
#   VM-native CRDs: every kind in ./kinds.nix, derived from that table so
#     the set stays complete: the operator crashes at startup if any kind
#     it indexes is missing (see the invariant note in kinds.nix; enforced
#     below with an eval-time throw).
#   prometheus-operator compat CRDs: ServiceMonitor, PodMonitor,
#     PrometheusRule, Probe (monitoring.coreos.com). CRDs only, no
#     prometheus-operator controller: the VM operator's built-in converter
#     watches these and materializes VM equivalents, so existing kix.monitor
#     callers and app-package ServiceMonitors work unchanged. On a cluster
#     that already has them, `prometheusOperatorCRDs = "reference"` waits
#     for the real ones instead of declaring a second opinion.
#
# VMSingle / VMAuth and the logs/traces kinds are still not shipped. The
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
  promGroup = "monitoring.coreos.com";
  inherit (import ./kinds.nix) vmCrdDefs indexedKinds promCompatDefs;

  # ── Compile-time guard for the runtime invariant (kinds.nix) ─────────
  shippedKinds = lib.mapAttrsToList (_: def: def.kind) vmCrdDefs;
  missingIndexed = builtins.filter (k: !(builtins.elem k shippedKinds)) indexedKinds;
  guard =
    if missingIndexed == [ ] then
      null
    else
      throw (
        "victoria-metrics-operator: kinds.nix no longer covers the operator's "
        + "startup indexer set. Missing: ${builtins.concatStringsSep ", " missingIndexed}. "
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
  # factBehavior: kinds whose operator-created operand pods dial endpoints
  # embedded in the CR spec declare terminate + the operand podSelector so
  # netpol opens egress for the operands, not for whoever references the CR:
  #   VMAgent         remoteWrite[].url
  #   VMAlert         datasource.url, remoteWrite.url, remoteRead.url,
  #                   notifier[].url
  #   VMAlertmanager  receiver endpoints carried in the routing config
  # VMCluster carries no external endpoints (vminsert/vmselect/vmstorage
  # only dial each other, operator-wired; the doc 96 blindspot): explicit
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

  # The operator's uniform health convention, declared once for the whole
  # group: every VM CR is ready when status.updateStatus == "operational"
  # (conditions are consumer-prefixed, never Ready/Available, so a generic
  # condition check waits forever, as it does for VMServiceScrape). Rides
  # the typed chain into every CR as the `kix.run/readiness` annotation,
  # which the kix CLI evaluates at deploy time, so no kind list in the CLI
  # to keep in sync.
  #
  # The claim is verified against a running operator only for the
  # consumer kinds; the parked kinds (VTCluster, VLAgent, ...) inherit it
  # on the operator's convention alone. If the operator never writes
  # updateStatus for some kind, a CR of it waits until timeout. That is the
  # visible, self-diagnosing failure, preferred over generic
  # ready-on-empty racing the operator. Re-verify per-kind when adding
  # out.mk* builders for parked kinds.
  vmReadiness = {
    path = "/status/updateStatus";
    equals = "operational";
  };

  # ── Vendored upstream spec schemas ──────────────────────────────────
  # `fromKind` mints a stub whose spec is x-kubernetes-preserve-unknown-
  # fields, which registers the kind and validates nothing. A mistyped
  # field in a CR then reaches the operator instead of being refused at
  # apply time, and `kix deploy --dry-run` cannot see it either.
  #
  # So every kind with a consumer surface (`consumer = true` in kinds.nix:
  # the out.mk* builders and the sibling packages) carries the real
  # upstream schema, vendored under ./crds by scripts/vendor-crds.py from
  # the URL in crds/sources.txt. The indexer-floor kinds keep the stub:
  # nothing in kix writes one, and their only job is to exist.
  #
  # The file is the whole upstream CRD document; only its spec subtree is
  # read here. A missing file is an error rather than a silent fall back
  # to the stub, because the point is that consumer kinds are checked.
  vendoredSpec =
    def:
    let
      path = ./crds + "/${def.plural}.${vmGroup}.json";
    in
    if !(def.consumer or false) then
      null
    else if !builtins.pathExists path then
      throw (
        "victoria-metrics-operator: ${def.kind} has a consumer surface but no "
        + "vendored schema at crds/${def.plural}.${vmGroup}.json. Add it to "
        + "crds/sources.txt and run scripts/vendor-crds.py."
      )
    else
      (builtins.elemAt (builtins.fromJSON (builtins.readFile path)).spec.versions 0)
      .schema.openAPIV3Schema.properties.spec;

  mkVMKindCRD =
    def:
    let
      extras = kindExtras.${def.kind} or { };
      spec = vendoredSpec def;
      base =
        scope.crd.fromKind def.kind {
          spec.group = vmGroup;
          spec.names.plural = def.plural;
        }
        |> scope.crd.withVersion def.version
        |> scope.crd.withPrinterColumns (extras.printerColumns or ageColumn);
      schemed = if spec == null then base else base |> scope.crd.withSchema spec;
    in
    mkVMOperatorCRD (
      schemed
      // {
        readiness = vmReadiness;
      }
      // lib.optionalAttrs (extras ? factBehavior) {
        inherit (extras) factBehavior;
      }
    );

  vmCrds = lib.mapAttrs (_: mkVMKindCRD) vmCrdDefs;

  # ── prometheus-operator compat CRDs (converter input) ────────────────
  # ServiceMonitor, PodMonitor, PrometheusRule, Probe. The same slim
  # schemas as prometheus-operator/crds.nix, so the converter has
  # something to watch when that package isn't installed.
  #
  # On a cluster that already runs prometheus-operator, these four names
  # are taken: the real CRDs are there at the upstream schemas, owned by
  # whatever installed them. `prometheusOperatorCRDs = "reference"` swaps
  # each declaration for an import marker that waits for the CRD instead.
  # See the option in default.nix for why there is no safe default.
  mkPromCompatCRD =
    def:
    mkVMOperatorCRD (
      scope.crd.fromKind def.kind {
        spec.group = promGroup;
        spec.names.plural = def.plural;
      }
      |> scope.crd.withVersion def.version
      |> scope.crd.withShortNames def.shortNames
      |> scope.crd.withPrinterColumns ageColumn
    );

  # No labels, annotations, short names or printer columns: this marker
  # names a CRD somebody else installed and does not get to restyle it.
  # The plural is spelled out in the table above rather than derived,
  # because `<plural>.<group>` has to match the name already on the
  # cluster exactly.
  mkPromCompatRef =
    def:
    scope.mkCRDRef {
      group = promGroup;
      inherit (def) kind plural version;
    };

  mkPromCompat =
    if config.prometheusOperatorCRDs == "reference" then mkPromCompatRef else mkPromCompatCRD;

  # A compat CRD is here when the package exposes a builder for it, or
  # when its converter is on. Deriving it this way is what stops a
  # converter ever running without its CRD (kinds.nix promCompatDefs).
  neededCompat = lib.filterAttrs (name: def: def.builder || config.convert.${name}) promCompatDefs;

  promCompatCrds = lib.mapAttrs (_: mkPromCompat) neededCompat;
in
builtins.seq guard {
  crds = vmCrds // promCompatCrds;
}

# Altinity clickhouse-operator CRD definitions.
#
# Four kinds, every one from ./kinds.nix (see the note there on why none is
# left out). Each is built through the typed chain, so a CR made with
# `out.mkCR` waits for its CRD and inherits the readiness convention and the
# fact behavior declared here.
#
# The spec schema and the printer columns come from the upstream CRD
# documents, vendored per kind under ./schemas by
# scripts/vendor-clickhouse-crd-schemas.py. `fromKind` alone mints a stub
# whose spec accepts anything, and then a mistyped field in a
# ClickHouseInstallation reaches the operator when the apiserver could have
# refused it at apply time, and `kix deploy --dry-run` cannot see it either.
# ClickHouseOperatorConfiguration keeps
# `x-kubernetes-preserve-unknown-fields` on its spec because upstream
# declares it that way; it arrives with the vendored subtree.
#
# `status` stays the stub's open object. Upstream types it, and the operator
# is its only writer, so a closed schema there guards nothing Kix writes and
# would prune a status field the day the binary and the vendored file
# disagree. What readiness reads, `status.status`, is a plain string either
# way.

{
  config,
  scope,
  lib,
  ...
}:
let
  inherit (import ./kinds.nix) crdDefs;

  labels = {
    "app.kubernetes.io/part-of" = "clickhouse-operator";
    "app.kubernetes.io/version" = config.image.tag;
  };

  # The operator's health convention, the same for both operand kinds:
  # status.status walks InProgress to Completed (or Aborted) on every
  # reconcile, and no Ready or Available condition is ever written, so the
  # generic condition check would wait forever. Rides the typed chain into
  # every CR as Kix's readiness annotation, which `kix deploy` evaluates.
  #
  # UNVERIFIED on a live cluster (doc 148, phase 4): that the operator moves
  # the status back to InProgress on a spec change before the previous
  # generation's Completed can be read as the new one's verdict.
  operandReadiness = {
    path = "/status/status";
    equals = "Completed";
  };

  # The operand pods are the ones that dial what the CR spec carries. A CHI
  # names its Keeper (`spec.configuration.zookeeper`) and the ClickHouse
  # servers connect to it; the operator only renders that address into their
  # config. So both operand kinds terminate the fact at the pods the
  # operator labels with the CR's name, and netpol opens egress for those
  # pods. A Keeper spec carries no outside address today; it declares the
  # same shape so a fact that does flow into one lands on the right pods.
  #
  # The two kinds that configure the operator run no pods and dial nothing.
  # Explicit conduct, so a fact flowing through one never warns as
  # undeclared.
  factBehaviorFor =
    def:
    if def.operand then
      {
        endpoint = "terminate";
        podSelector = cr: { ${def.operandLabel} = cr.metadata.name; };
      }
    else
      { endpoint = "conduct"; };

  # The file is the whole upstream CRD document. A missing file is an error
  # and not a fall back to the stub, because the point is that these kinds
  # are checked.
  vendored =
    def:
    let
      path = ./schemas + "/${def.plural}.json";
    in
    if !builtins.pathExists path then
      throw (
        "clickhouse-operator: ${def.kind} has no vendored CRD document at "
        + "schemas/${def.plural}.json. Run scripts/vendor-clickhouse-crd-schemas.py."
      )
    else
      builtins.fromJSON (builtins.readFile path);

  # kinds.nix is what the RBAC is derived from, the vendored document is
  # what the operator was built against. If they name the kind differently
  # the operator is granted a resource that is not the one it watches, and
  # that surfaces as a watch that never syncs. Refuse at eval time.
  checkedVersion =
    def: upstream:
    let
      names = upstream.spec.names;
      version = builtins.head upstream.spec.versions;
      agree =
        upstream.spec.group == def.group
        && names.kind == def.kind
        && names.plural == def.plural
        && (names.shortNames or [ ]) == def.shortNames
        && builtins.length upstream.spec.versions == 1
        && version.name == def.version;
    in
    if agree then
      version
    else
      throw (
        "clickhouse-operator: kinds.nix and schemas/${def.plural}.json disagree on "
        + "${def.kind} (group, kind, plural, short names or version). Fix kinds.nix "
        + "to match the vendored upstream document."
      );

  mkKindCRD =
    def:
    let
      version = checkedVersion def (vendored def);
    in
    scope.mkCRD (
      scope.crd.fromKind def.kind {
        spec.group = def.group;
        spec.names.plural = def.plural;
      }
      |> scope.crd.withVersion def.version
      |> scope.crd.withShortNames def.shortNames
      |> scope.crd.withPrinterColumns version.additionalPrinterColumns
      |> scope.crd.withSchema version.schema.openAPIV3Schema.properties.spec
      |> scope.crd.withLabels labels
      |> (
        crd:
        crd
        // {
          factBehavior = factBehaviorFor def;
        }
        // lib.optionalAttrs def.operand { readiness = operandReadiness; }
      )
    );
in
{
  crds = lib.mapAttrs (_: mkKindCRD) crdDefs;
}

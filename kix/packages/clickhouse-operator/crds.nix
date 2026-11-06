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
  kix,
  ...
}:
let
  inherit (import ./kinds.nix) crdDefs;

  labels = {
    "app.kubernetes.io/part-of" = "clickhouse-operator";
    "app.kubernetes.io/version" = builtins.unsafeDiscardStringContext config.image.tag;
  };

  # The operator's health convention, the same for both operand kinds:
  # status.status walks InProgress to Completed (or Aborted) on every
  # reconcile, and no Ready or Available condition is ever written, so the
  # generic condition check would wait forever. Rides the typed chain into
  # every CR as Kix's readiness annotation, which `kix deploy` evaluates.
  #
  # UNVERIFIED on a live cluster: whether the operator moves status.status
  # back to InProgress on a spec change before the previous generation's
  # Completed can be read as the new one's verdict.
  operandReadiness = {
    path = "/status/status";
    equals = "Completed";
  };

  # Route endpoint facts to operand pods for operand kinds, or conduct them
  # for operator configuration kinds. A CHI names its Keeper
  # (`spec.configuration.zookeeper`) and the ClickHouse servers connect to
  # it; the operator only renders that address into their config. Both
  # operand kinds terminate the fact at the pods the operator labels with
  # the CR's name so netpol opens egress for those pods. The two kinds that
  # configure the operator run no pods and dial nothing, so they conduct
  # facts without warning as undeclared.
  factBehaviorFor =
    def:
    if def.operand then
      {
        endpoint = "terminate";
        podSelector = cr: { ${def.operandLabel} = cr.metadata.name; };
      }
    else
      { endpoint = "conduct"; };

  # Return the least an installation CR uses. Each cluster runs
  # `layout.shardsCount` * `layout.replicasCount` hosts (each at least 1 and
  # at least the length of `layout.shards` or `layout.replicas`), defaulting
  # to a single 1x1 cluster when `spec.configuration.clusters` is empty.
  # When `spec.stop` or `spec.suspend` is truthy, the operator runs nothing.
  #
  # Every host is one pod with its own Service. The pod has every container
  # in the cluster's `templates.podTemplate` (falling back to
  # `spec.defaults.templates.podTemplate`), and one claim for each
  # `dataVolumeClaimTemplate` and `logVolumeClaimTemplate` the cluster or
  # `spec.defaults` names, sized by that volume claim template. If any
  # shard, replica, or host overrides `templates`, or if
  # `spec.templates.hostTemplates` is non-empty, only the pods and Services
  # are counted, because hosts may use different templates. External
  # `ClickHouseInstallationTemplate` resources are not read.
  usesAtLeastFor =
    cr:
    let
      spec = cr.spec or { };
      off =
        v:
        builtins.elem (lib.toLower (toString v)) [
          ""
          "0"
          "false"
          "no"
          "off"
          "disable"
          "disabled"
        ];
      named =
        list: name: lib.findFirst (t: (t.name or null) == name) null (if name == null then [ ] else list);
      useOf =
        cluster:
        let
          layout = cluster.layout or { };
          shards = layout.shards or [ ];
          replicas = layout.replicas or [ ];
          nested =
            shards
            ++ replicas
            ++ builtins.concatMap (s: s.replicas or [ ]) shards
            ++ builtins.concatMap (r: r.shards or [ ]) replicas;
          ownTemplates =
            builtins.any (e: e ? templates) nested || (spec.templates.hostTemplates or [ ]) != [ ];
          templateOf = field: cluster.templates.${field} or spec.defaults.templates.${field} or null;
          podTemplate = named (spec.templates.podTemplates or [ ]) (templateOf "podTemplate");
          claims = builtins.filter (t: t != null) (
            map (named (spec.templates.volumeClaimTemplates or [ ])) (
              lib.unique (
                builtins.filter (n: n != null) [
                  (templateOf "dataVolumeClaimTemplate")
                  (templateOf "logVolumeClaimTemplate")
                ]
              )
            )
          );
          hosts =
            lib.max 1 (lib.max (layout.shardsCount or 0) (builtins.length shards))
            * lib.max 1 (lib.max (layout.replicasCount or 0) (builtins.length replicas));
          perHost =
            if ownTemplates then
              {
                pods = 1;
                services = 1;
              }
            else
              kix.usage.add (
                [
                  (kix.usage.ofPod (if podTemplate == null then [ ] else podTemplate.spec.containers or [ ]))
                  { services = 1; }
                ]
                ++ map (t: {
                  persistentvolumeclaims = 1;
                  "requests.storage" = t.spec.resources.requests.storage or null;
                }) claims
              );
        in
        kix.usage.times hosts perHost;
      clusters = spec.configuration.clusters or [ ];
    in
    if off (spec.stop or null) && off (spec.suspend or null) then
      kix.usage.add (map useOf (if clusters == [ ] then [ { } ] else clusters))
    else
      { };

  # Read the vendored upstream CRD document, or throw if the file is missing.
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

  # Verify that kinds.nix (which drives RBAC) matches the vendored CRD
  # document (which the operator watches), and return its single version.
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
          # The installations keep their tables on their volumes. Templates
          # and the operator configuration are settings.
          holdsData = def.operand;
        }
        // lib.optionalAttrs def.operand {
          readiness = operandReadiness;
          usesAtLeast = usesAtLeastFor;
        }
      )
    );
in
{
  crds = lib.mapAttrs (_: mkKindCRD) crdDefs;
}

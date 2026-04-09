# Built-in scorecard rules: Architecture / Dependency-Injection hygiene
#
# These rules catch "code smells" where a package builds resources that
# belong to another capability instead of requesting that capability via
# DI. The principle: resources are owned by the capability that provides
# them (storage provider owns PVCs, reflector owns reflection wiring,
# prometheus-operator owns ServiceMonitors, …). Consumers request these
# via dep args and call the owner's `out.mk*` builders; they do not
# hand-roll equivalents.
#
# Detection is "fingerprint → capability" driven:
#
#   - A resource matches a fingerprint if its kind (or annotation/label
#     domain) belongs to that capability.
#   - The package "owns" the capability iff either:
#       a) `meta.provides` contains the capability name, or
#       b) one of its emitted resources is tagged with
#          `kix.dev/capability: <name>` (set by the owner's builder when
#          the resource was constructed through DI).
#
# If a resource matches a fingerprint and the package does not own the
# capability, the rule fires with a suggestion to use DI.
#
# Gotchas / non-obvious bits:
#
#   - The `kix.dev/capability` annotation is what lets consumers pass the
#     rule post-migration: when a consumer calls `reflector.out.reflectSecret`
#     the builder stamps this annotation on the resources it returns, so
#     this rule can distinguish "built inline" from "built via the owner's
#     DI builder" without needing any provenance machinery.
#
#   - We check `resources` (the package's emitted manifests), not the
#     resolved dep graph — having a `reflector` dep resolved is not proof
#     of good hygiene, the package might still hand-roll the annotator
#     resources. Provenance has to be explicit via the annotation.
#
# Adding a new fingerprint: append a record to `fingerprints` below.

{ lib }:

let
  # Read a resource's capability annotation (returns null if absent).
  getCapAnnotation =
    r:
    let
      ann = r.metadata.annotations or { };
    in
    ann."kix.dev/capability" or null;

  # Does the resource look like a raw JSON blob that contains the given
  # substring anywhere? Used for annotation-domain fingerprints where the
  # string may appear in metadata, args, scripts, env, etc.
  containsString = needle: r: lib.hasInfix needle (builtins.toJSON r);

  fingerprints = [
    {
      capability = "storage";
      detect = r: (r.kind or "") == "PersistentVolumeClaim";
      describe = r: "PersistentVolumeClaim '${r.metadata.name or "?"}'";
      rationale = ''
        Storage should be a DI concern: cluster operators compose PVC size,
        storageClass, and lifecycle independently of the consuming workload.
        Hand-rolled PVCs prevent teams from swapping backends, sharing volumes
        across workloads, or migrating storage without rebuilding the consumer.
      '';
      suggest = ''
        Declare a `storage` dep arg and mount it via
        `kix.mount.pvc storage { mountPath = "..."; }`. Provision the PVC as
        a sibling instance using `packages.persistent-volume-claim` so the
        cluster definition owns size / storageClass.
      '';
    }
    {
      capability = "reflection";
      # Reflector annotations have a well-known domain. The substring also
      # appears in the annotator Job's `kubectl annotate ...` command, so
      # even the indirect wiring (RBAC + Job that patches a secret) is
      # caught, not just the annotated secret itself.
      detect = containsString "reflector.v1.k8s.emberstack.com";
      describe = r: "${r.kind or "Resource"} '${r.metadata.name or "?"}' carries reflector wiring";
      rationale = ''
        Cross-namespace secret reflection belongs to the reflector package.
        Building the annotator Job, its RBAC, or the annotations inline
        duplicates logic that the reflector owner should expose through a
        builder — otherwise every consumer reimplements the same contract.
      '';
      suggest = ''
        Declare a `reflector` dep arg and call
        `reflector.out.reflectSecret scope { secretName = ...; requires = [...]; }`
        instead of building the annotator bundle by hand. The builder
        stamps `kix.dev/capability: reflection` on its resources so this
        rule sees the consumer as compliant.
      '';
    }
  ];

in
{
  # Single generic rule driven by the fingerprint registry above.
  # Package-level: needs `resources` + `meta` to decide ownership.
  capabilityOwnership = {
    description = "Resources whose capability is owned by another package should be requested via DI, not hand-rolled";
    level = "package";
    severity = "warning";
    tags = [
      "architecture"
      "di"
    ];
    check =
      {
        resources,
        meta,
        instanceName,
        ...
      }:
      let
        providedCaps = meta.provides or [ ];
        ownsCapability = cap: builtins.elem cap providedCaps;

        offendingFor =
          fp:
          if ownsCapability fp.capability then
            [ ]
          else
            let
              matching = builtins.filter (r: fp.detect r && (getCapAnnotation r) != fp.capability) resources;
            in
            map (r: {
              message =
                "${fp.describe r} is hand-rolled in '${instanceName}' but belongs to capability '${fp.capability}'. "
                + lib.replaceStrings [ "\n" ] [ " " ] fp.rationale
                + "→ "
                + lib.replaceStrings [ "\n" ] [ " " ] fp.suggest;
            }) matching;
      in
      builtins.concatLists (map offendingFor fingerprints);
  };
}

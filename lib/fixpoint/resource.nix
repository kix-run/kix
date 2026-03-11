# Fixpoint-aware resource constructor.
#
# This is the core building block: creates a K8s resource with automatic
# dependency tracking via refs. The tree walker runs on spec/data/annotations
# at construction time, collecting deps from any refs found. The resource
# exposes .ref and .out for other resources to reference, .deps for the
# inferred dependency list, and .closure for the full transitive closure.
#
# The .manifest field contains the resolved attrset (refs replaced with plain
# values) ready for serialization through the existing kixlib pipeline
# (removeNulls -> preprocessors -> YAML).

{
  lib,
  refs,
  resolver,
  closure,
}:

let
  inherit (refs) mkRef;
  inherit (resolver) resolve;
  inherit (closure) computeClosure;
in
rec {

  # Creates a K8s resource with ref tracking and automatic dependency inference.
  #
  # Required arguments:
  #   apiVersion — K8s API version (e.g., "v1", "apps/v1")
  #   kind       — resource kind (e.g., "Deployment", "Service")
  #   name       — resource name (human-readable, used in metadata.name)
  #
  # Optional arguments:
  #   namespace    — K8s namespace (default: "default")
  #   labels       — metadata.labels (merged with app.kubernetes.io/name)
  #   annotations  — metadata.annotations
  #   spec         — resource spec (tree walker extracts deps from refs here)
  #   data         — resource data (for ConfigMaps)
  #   stringData   — resource stringData (for Secrets)
  #   rules        — for ClusterRole/Role (lives at top level, not under spec)
  #   subjects     — for ClusterRoleBinding/RoleBinding (top level)
  #   roleRef      — for ClusterRoleBinding/RoleBinding (top level)
  #   outputs      — named outputs exposed as refs (e.g., { port = 80; clusterIP = "10.96.0.10"; })
  #   requires     — inverted deps: resources I need that reference me (e.g., SA requires its binding)
  #   extraDeps    — ordering-only deps (deploy X before me, but don't include in closure)
  #   extra        — additional top-level fields passed through to manifest (webhooks, volumeClaimTemplates, etc.)
  mkResource =
    {
      apiVersion,
      kind,
      name,
      namespace ? "default",
      labels ? { },
      annotations ? { },
      spec ? { },
      data ? { },
      stringData ? { },
      rules ? null,
      subjects ? null,
      roleRef ? null,
      webhooks ? null,
      outputs ? { },
      requires ? [ ],
      extraDeps ? [ ],
      extra ? { },
    }:
    let
      resolvedSpec = resolve spec;
      resolvedData = resolve data;
      resolvedStringData = resolve stringData;
      resolvedAnnotations = resolve annotations;
      resolvedRules =
        if rules != null then
          resolve rules
        else
          {
            resolved = null;
            deps = [ ];
          };
      resolvedSubjects =
        if subjects != null then
          resolve subjects
        else
          {
            resolved = null;
            deps = [ ];
          };
      resolvedRoleRef =
        if roleRef != null then
          resolve roleRef
        else
          {
            resolved = null;
            deps = [ ];
          };
      resolvedWebhooks =
        if webhooks != null then
          resolve webhooks
        else
          {
            resolved = null;
            deps = [ ];
          };

      # Deduplicate deps by resource identity (kind/name@namespace).
      # Cannot use lib.unique here because resource attrsets contain `closure`
      # fields that reference other resources with `closure` fields — structural
      # comparison would cause infinite recursion.
      allDeps =
        resolvedSpec.deps
        ++ resolvedData.deps
        ++ resolvedStringData.deps
        ++ resolvedAnnotations.deps
        ++ resolvedRules.deps
        ++ resolvedSubjects.deps
        ++ resolvedRoleRef.deps
        ++ resolvedWebhooks.deps
        ++ extraDeps;

      uniqueByIdentity =
        resources:
        let
          go =
            {
              seen,
              result,
              queue,
            }:
            if queue == [ ] then
              result
            else
              let
                head = builtins.head queue;
                rest = builtins.tail queue;
                ns = if head.namespace or null == null then "_cluster_" else head.namespace;
                id = "${head.kind}/${head.name}@${ns}";
              in
              if builtins.hasAttr id seen then
                go {
                  inherit seen result;
                  queue = rest;
                }
              else
                go {
                  seen = seen // {
                    ${id} = true;
                  };
                  result = result ++ [ head ];
                  queue = rest;
                };
        in
        go {
          seen = { };
          result = [ ];
          queue = resources;
        };

      inferredDeps = uniqueByIdentity allDeps;

      self = {
        _type = "k8s-resource";
        inherit
          apiVersion
          kind
          name
          namespace
          ;
        inherit requires;

        # Primary identity ref — use this when another resource needs this
        # resource's name (e.g., configMapRef.name = configmap.ref).
        ref = mkRef self "ref" name;

        # Named outputs — use for port numbers, clusterIPs, etc.
        # Each output is a Ref that tracks back to this resource.
        out = lib.mapAttrs (k: v: mkRef self k v) outputs;

        # Automatic deps from tree walker + manual extraDeps.
        deps = inferredDeps;

        # Full transitive closure (all resources needed to deploy this one).
        closure = computeClosure self;

        # The resolved manifest — refs replaced with plain values, ready for
        # serialization. This attrset can go directly into the existing
        # kixlib.mkManifest pipeline (removeNulls -> preprocessors -> YAML).
        # Deep merge `extra` into the manifest so nested fields (e.g.,
        # spec.volumeClaimTemplates) don't clobber the resolved spec.
        # Shallow `//` would replace the entire `spec` key, losing the
        # resolved template/selector/etc.
        manifest = lib.recursiveUpdate ({
          inherit apiVersion kind;
          metadata = {
            inherit name;
            # namespace = null for cluster-scoped resources (removeNulls strips it)
            namespace = if namespace != null then namespace else null;
          }
          // lib.optionalAttrs (labels != { }) {
            labels = labels;
          }
          // lib.optionalAttrs (resolvedAnnotations.resolved != { }) {
            annotations = resolvedAnnotations.resolved;
          };
        }
        // lib.optionalAttrs (resolvedSpec.resolved != { }) {
          spec = resolvedSpec.resolved;
        }
        // lib.optionalAttrs (resolvedData.resolved != { }) {
          data = resolvedData.resolved;
        }
        // lib.optionalAttrs (resolvedStringData.resolved != { }) {
          stringData = resolvedStringData.resolved;
        }
        // lib.optionalAttrs (resolvedRules.resolved != null) {
          rules = resolvedRules.resolved;
        }
        // lib.optionalAttrs (resolvedSubjects.resolved != null) {
          subjects = resolvedSubjects.resolved;
        }
        // lib.optionalAttrs (resolvedRoleRef.resolved != null) {
          roleRef = resolvedRoleRef.resolved;
        }
        // lib.optionalAttrs (resolvedWebhooks.resolved != null) {
          webhooks = resolvedWebhooks.resolved;
        }) extra;
      };
    in
    self;

  # Wraps an existing resource with additional requires, recomputing closure.
  #
  # This is the correct way to create a `main` entry that adds inverted deps
  # to an existing resource. Using `//` directly would NOT recompute the
  # closure (it inherits the original resource's pre-computed closure).
  #
  # Example:
  #   main = k8s.withRequires [ self.workload self.metricsService ] self.service;
  #
  # The returned resource has:
  #   - All fields from the original resource
  #   - requires = original requires ++ additionalRequires
  #   - closure recomputed to include the new requires
  withRequires =
    additionalRequires: resource:
    let
      newSelf = resource // {
        requires = (resource.requires or [ ]) ++ additionalRequires;
        closure = computeClosure newSelf;
      };
    in
    newSelf;

}

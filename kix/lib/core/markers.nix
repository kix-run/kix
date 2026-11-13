# Context markers (`toFile` store paths carried in string context) that record
# metadata about a string without representing a deployable resource.
# `core/resource.nix` excludes them from `kix.run/depends-on`.
#
# An untracked-reference marker names an object created outside the cluster
# definition so reference validators accept it. When a marker includes `kind`,
# deploy waits for the object before applying the referring resource.
#
# A load-balancer-class marker records that an in-cluster provider serves a
# Service's `spec.loadBalancerClass`.
{ lib }:

let
  inherit (import ./error.nix { inherit lib; }) fail;
in
rec {
  # Strip the 44-character "/nix/store/<32-char-hash>-" prefix from a store path.
  pathName = p: builtins.substring 44 (builtins.stringLength p) p;

  untrackedRefName = "kix-untracked-ref";
  loadBalancerClassName = "kix-load-balancer-class";

  # Built-in kinds (by API group) that cannot create other named objects and
  # therefore cannot be used as `by` targets or carry `by = "self"` references.
  # Namespace is excluded because the control plane creates `kube-root-ca.crt`
  # and the `default` ServiceAccount in each namespace. Custom kinds with the
  # same name in another API group (such as `serving.knative.dev` Service) are
  # allowed.
  passiveKinds = {
    "" = [
      "ConfigMap"
      "Secret"
      "Service"
      "Endpoints"
      "PersistentVolumeClaim"
      "PersistentVolume"
      "ServiceAccount"
      "ResourceQuota"
      "LimitRange"
    ];
    "discovery.k8s.io" = [ "EndpointSlice" ];
    "rbac.authorization.k8s.io" = [
      "Role"
      "ClusterRole"
      "RoleBinding"
      "ClusterRoleBinding"
    ];
    "networking.k8s.io" = [
      "NetworkPolicy"
      "IngressClass"
    ];
    "policy" = [ "PodDisruptionBudget" ];
    "scheduling.k8s.io" = [ "PriorityClass" ];
    "storage.k8s.io" = [
      "StorageClass"
      "CSIDriver"
    ];
    "node.k8s.io" = [ "RuntimeClass" ];
    "apiextensions.k8s.io" = [ "CustomResourceDefinition" ];
    "admissionregistration.k8s.io" = [
      "ValidatingWebhookConfiguration"
      "MutatingWebhookConfiguration"
      "ValidatingAdmissionPolicy"
      "ValidatingAdmissionPolicyBinding"
      "MutatingAdmissionPolicy"
      "MutatingAdmissionPolicyBinding"
    ];
    "apiregistration.k8s.io" = [ "APIService" ];
    "flowcontrol.apiserver.k8s.io" = [
      "FlowSchema"
      "PriorityLevelConfiguration"
    ];
  };

  isPassiveKind =
    { apiVersion, kind }:
    let
      group = if lib.hasInfix "/" apiVersion then builtins.head (lib.splitString "/" apiVersion) else "";
    in
    builtins.elem kind (passiveKinds.${group} or [ ]);

  # Attach an untracked-reference marker to `ref` (a name or
  # `{ name; kind?; apiVersion?; by?; }`).
  #
  # In the attrset form, `by` attaches the creator resource's context for
  # deployment ordering, and `kind` (with `apiVersion` defaulting to `"v1"`)
  # records a `kix.run/expects` entry that deploy checks before applying the
  # referring resource.
  #
  # `by = "self"` marks an object created at runtime by the referring resource
  # itself (such as an optional Secret minted by an operator after startup).
  # It takes no `kind` and must only appear on `optional = true` pod references.
  mkUntrackedRef =
    ref:
    let
      spec = if builtins.isString ref then { name = ref; } else ref;
      name =
        spec.name or (fail "kix.untrackedRef: expected a name, or { name; kind?; apiVersion?; by? }.");
      kind = spec.kind or null;
      apiVersion = spec.apiVersion or "v1";
      by = spec.by or null;
      bySelf = by == "self";
      known = [
        "name"
        "kind"
        "apiVersion"
        "by"
      ];
      unknown = builtins.filter (k: !(builtins.elem k known)) (builtins.attrNames spec);
      _check =
        if !(builtins.isString name) then
          fail "kix.untrackedRef: name must be a string."
        else if unknown != [ ] then
          fail "kix.untrackedRef (${name}): unknown attribute(s) ${builtins.concatStringsSep ", " unknown}. It takes name, kind, apiVersion and by."
        else if kind != null && !(builtins.isString kind) then
          fail "kix.untrackedRef (${name}): kind must be a string, such as \"Secret\"."
        else if bySelf && (spec ? kind || spec ? apiVersion) then
          fail "kix.untrackedRef (${name}): `by = \"self\"` takes no kind or apiVersion. The resource holding the reference creates the object, so deploy cannot wait for it before applying that resource."
        else if by != null && !bySelf && !(builtins.isAttrs by && by ? outPath) then
          fail "kix.untrackedRef (${name}): `by` must be a resource, the Job or workload that creates the object, or \"self\" when the resource holding the reference creates it."
        else if
          by != null
          && !bySelf
          && isPassiveKind {
            apiVersion = by.apiVersion or "";
            kind = by.kind or "";
          }
        then
          fail {
            message = "kix.untrackedRef (${name}): `by` is ${by.kind} '${by.name or ""}', a built-in kind that creates no object a manifest refers to by name.";
            fix = "Name the Job, workload or operator custom resource that creates '${name}'.";
          }
        else
          null;
      content =
        if bySelf then
          builtins.toJSON {
            inherit name;
            selfCreated = true;
          }
        else if kind == null then
          name
        else
          builtins.toJSON (
            {
              inherit name kind apiVersion;
            }
            // lib.optionalAttrs (by != null) { hasCreator = true; }
          );
      marker = builtins.toFile untrackedRefName content;
      byCtx = if by == null || bySelf then { } else builtins.getContext "${by}";
    in
    builtins.seq _check (builtins.appendContext name (builtins.getContext "${marker}" // byCtx));

  isUntrackedRefPath = p: lib.hasPrefix untrackedRefName (pathName p);

  # Attach a load-balancer-class marker and the context of `by` (the controller
  # resource serving the class) to `class`. Services using this value depend on
  # `by`, bypass the cluster `load-balancer` role check, and receive no external
  # ingress in derived network policies.
  mkProvidedLoadBalancerClass =
    args:
    let
      who = "kix.providedLoadBalancerClass";
      class = args.class or (fail "${who}: expected { class; by; }.");
      by =
        args.by or (fail "${who} (${class}): `by` is required. It is the resource that serves the class.");
      unknown = builtins.attrNames (
        removeAttrs args [
          "class"
          "by"
        ]
      );
      _check =
        if !(builtins.isString class) || class == "" then
          fail "${who}: class must be a non-empty string."
        else if unknown != [ ] then
          fail "${who} (${class}): unknown attribute(s) ${builtins.concatStringsSep ", " unknown}. It takes class and by."
        else if !(builtins.isAttrs by && by ? outPath) then
          fail "${who} (${class}): `by` must be a resource, the controller that serves the class."
        else
          null;
      marker = builtins.toFile loadBalancerClassName (builtins.unsafeDiscardStringContext class);
    in
    builtins.seq _check (
      builtins.appendContext (builtins.unsafeDiscardStringContext class) (
        builtins.getContext "${marker}" // builtins.getContext "${by}"
      )
    );

  isLoadBalancerClassPath = p: lib.hasPrefix loadBalancerClassName (pathName p);

  # Return true when `s` carries a load-balancer-class marker matching `s`.
  # Comparing the marker content rejects derived strings such as
  # `"${class}-internal"` that inherit `class`'s string context.
  isProvidedLoadBalancerClass =
    s:
    builtins.isString s
    && builtins.any (
      p: isLoadBalancerClassPath p && builtins.readFile p == builtins.unsafeDiscardStringContext s
    ) (builtins.attrNames (builtins.getContext s));

  isMarkerPath = p: isUntrackedRefPath p || isLoadBalancerClassPath p;

  # Decode a marker's JSON record, or return null for a bare string marker.
  readMarker =
    p:
    let
      content = builtins.readFile p;
    in
    if lib.hasPrefix "{" content then builtins.fromJSON content else null;

  # Return `{ name; kind; apiVersion; hasCreator?; }` when the marker declares
  # an expected kind, or null otherwise.
  readExpectation =
    p:
    let
      m = readMarker p;
    in
    if m != null && m ? kind then m else null;

  isSelfCreated = p: (readMarker p).selfCreated or false;

  # Return the names of all `by = "self"` references in `s`'s string context.
  selfCreatedNames =
    s:
    map (p: (readMarker p).name) (
      builtins.filter (p: isUntrackedRefPath p && isSelfCreated p) (
        builtins.attrNames (builtins.getContext s)
      )
    );

  hasCreator = p: (readMarker p).hasCreator or false;
}

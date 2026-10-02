# Inert context markers: `toFile` paths in a string's context that record a
# claim about the string and are not resources. core/resource.nix excludes
# them from depends-on (`isMarkerPath`) because they have no deployable
# manifest.
#
# An untracked-reference marker names an object created outside this
# cluster definition. It supplies string context so reference validators
# accept the name, and a marker with a kind also supplies an expectation
# that deploy checks before applying the resource that refers to it.
#
# A load-balancer-class marker says a provider in the build serves the
# class a Service names in `spec.loadBalancerClass`.
{ lib }:

rec {
  # /nix/store/ = 11 chars, hash = 32, "-" = 1 → name starts at offset 44
  pathName = p: builtins.substring 44 (builtins.stringLength p) p;

  untrackedRefName = "kix-untracked-ref";
  loadBalancerClassName = "kix-load-balancer-class";

  # Built-in kinds that `by` rejects, keyed by API group ("" is the core
  # group), and that may not hold a `by = "self"` reference. None of them
  # creates an object a manifest refers to by name: what the control plane
  # derives from them (a Service's EndpointSlices, the PersistentVolume
  # bound to a claim) is not named in a pod or custom resource. Namespace is
  # not listed, because the control plane creates the kube-root-ca.crt
  # ConfigMap and the default ServiceAccount in each one and pods name both.
  # The group matters: a custom kind with the same name (Knative's
  # serving.knative.dev Service) is a creator. Kinds not listed here,
  # including every custom resource, are accepted.
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

  # Accept a name or { name; kind?; apiVersion?; by?; } and return the name
  # with marker context. A string alone adds no deployment existence check.
  #
  # The experimental attrset form supports two additional constraints:
  # by adds the creator's resource context for dependency ordering; kind adds
  # a kix.run/expects entry checked before applying the referring resource.
  # apiVersion defaults to "v1".
  #   kix.untrackedRef { kind = "Secret"; name = "x"; by = self.job; }
  #
  # `by = "self"` says the resource holding the reference creates the object,
  # such as an operator that mounts an optional Secret and then mints it. It
  # adds no dependency and no kix.run/expects entry, because the object
  # exists only after the referrer runs, so it takes no kind. A workload may
  # hold it only in an optional reference (core/resource.nix), and it names
  # the creator only while one resource carries it (eval/cluster.nix).
  #   kix.untrackedRef { name = "operator-certs"; by = "self"; }
  mkUntrackedRef =
    ref:
    let
      spec = if builtins.isString ref then { name = ref; } else ref;
      name =
        spec.name or (throw "kix.untrackedRef: expected a name, or { name; kind?; apiVersion?; by? }");
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
          throw "kix.untrackedRef: name must be a string"
        else if unknown != [ ] then
          throw "kix.untrackedRef (${name}): unknown attribute(s) ${builtins.concatStringsSep ", " unknown}; takes name, kind, apiVersion, by"
        else if kind != null && !(builtins.isString kind) then
          throw "kix.untrackedRef (${name}): kind must be a string, e.g. \"Secret\""
        else if bySelf && (spec ? kind || spec ? apiVersion) then
          throw "kix.untrackedRef (${name}): `by = \"self\"` takes no kind or apiVersion. The resource holding the reference creates the object, so deploy cannot wait for it before applying that resource"
        else if by != null && !bySelf && !(builtins.isAttrs by && by ? outPath) then
          throw "kix.untrackedRef (${name}): `by` must be a resource, the Job or workload that creates the object, or \"self\" when the resource holding the reference creates it"
        else if
          by != null
          && !bySelf
          && isPassiveKind {
            apiVersion = by.apiVersion or "";
            kind = by.kind or "";
          }
        then
          throw "kix.untrackedRef (${name}): `by` is ${by.kind} '${by.name or ""}', a built-in kind that creates no object a manifest refers to by name. Name the Job, workload or operator custom resource that creates '${name}'"
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

  # A `spec.loadBalancerClass` value served by a load balancer provider in
  # the build: `class` with a marker, and with the context of `by`, the
  # provider resource that serves it, so a Service naming the class depends
  # on that resource. The loadBalancer role check (scope/validators.nix
  # checkLoadBalancer) skips a Service whose class carries the marker, and
  # derived network policy gives that Service no ingress from outside the
  # cluster (plugins/netpol/derive.nix).
  #   kix.providedLoadBalancerClass { class = "tailscale"; by = self.deployment; }
  mkProvidedLoadBalancerClass =
    args:
    let
      who = "kix.providedLoadBalancerClass";
      class = args.class or (throw "${who}: expected { class; by; }");
      by = args.by or (throw "${who} (${class}): `by` is required: the resource that serves the class");
      unknown = builtins.attrNames (
        removeAttrs args [
          "class"
          "by"
        ]
      );
      _check =
        if !(builtins.isString class) || class == "" then
          throw "${who}: class must be a non-empty string"
        else if unknown != [ ] then
          throw "${who} (${class}): unknown attribute(s) ${builtins.concatStringsSep ", " unknown}; takes class and by"
        else if !(builtins.isAttrs by && by ? outPath) then
          throw "${who} (${class}): `by` must be a resource, the controller that serves the class"
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

  # Whether a string carries a load-balancer-class marker.
  isProvidedLoadBalancerClass =
    s:
    builtins.isString s
    && builtins.any isLoadBalancerClassPath (builtins.attrNames (builtins.getContext s));

  # Whether a context path is a marker rather than a resource.
  isMarkerPath = p: isUntrackedRefPath p || isLoadBalancerClassPath p;

  # A marker's JSON record, or null for a bare string reference.
  readMarker =
    p:
    let
      content = builtins.readFile p;
    in
    if lib.hasPrefix "{" content then builtins.fromJSON content else null;

  # What a marker expects to exist, when its reference named a kind:
  # { name; kind; apiVersion; hasCreator?; }, else null. hasCreator is true
  # when the reference also named `by`.
  readExpectation =
    p:
    let
      m = readMarker p;
    in
    if m != null && m ? kind then m else null;

  # Whether a marker's reference was made with `by = "self"`.
  isSelfCreated = p: (readMarker p).selfCreated or false;

  # Names of the `by = "self"` references in a string's context.
  selfCreatedNames =
    s:
    map (p: (readMarker p).name) (
      builtins.filter (p: isUntrackedRefPath p && isSelfCreated p) (
        builtins.attrNames (builtins.getContext s)
      )
    );

  # Whether a marker's reference was made with `kind` and `by`, so deploy
  # orders the referrer after the creator and waits for the object.
  hasCreator = p: (readMarker p).hasCreator or false;
}

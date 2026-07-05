{ lib }:

let
  mkRef = apiGroup: resource: {
    inherit apiGroup resource;
    resourceNames = null;
  };

  rule =
    ref: verbs:
    {
      apiGroups = [ ref.apiGroup ];
      resources = [ ref.resource ];
      inherit verbs;
    }
    // lib.optionalAttrs (ref.resourceNames != null) { inherit (ref) resourceNames; };

  mkIntent =
    f: refOrRefs: if builtins.isList refOrRefs then builtins.concatMap f refOrRefs else f refOrRefs;

  buildRoleSet =
    roleKind: bindingKind: mkRes:
    {
      subjects,
      labels ? { },
      roles,
    }:
    builtins.listToAttrs (
      lib.concatMap (
        roleName:
        let
          entry = roles.${roleName};
          rules = if builtins.isList entry then entry else entry.rules;
          bindingName = if builtins.isList entry then roleName else entry.bindingName or roleName;
          role = mkRes {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = roleKind;
            name = roleName;
            inherit labels;
            extra.rules = rules;
          };
          binding = mkRes {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = bindingKind;
            name = bindingName;
            inherit labels;
            extra = {
              roleRef = {
                apiGroup = "rbac.authorization.k8s.io";
                kind = roleKind;
                name = role.out.name;
              };
              inherit subjects;
            };
          };
        in
        [
          {
            name = roleName;
            value = role;
          }
          {
            name = "${roleName}-binding";
            value = binding;
          }
        ]
      ) (builtins.attrNames roles)
    );

in
rec {

  group =
    apiGroup: resources:
    lib.genAttrs resources (r: mkRef apiGroup r) // { __functor = _: r: mkRef apiGroup r; };

  core = group "" [
    "configmaps"
    "endpoints"
    "events"
    "namespaces"
    "nodes"
    "persistentvolumeclaims"
    "persistentvolumes"
    "pods"
    "secrets"
    "serviceaccounts"
    "services"
  ];

  restrictTo = names: ref: ref // { resourceNames = names; };

  sub =
    suffix: ref:
    ref
    // {
      resource = "${ref.resource}/${suffix}";
      resourceNames = null;
    };

  watch = mkIntent (ref: [
    (rule ref [
      "get"
      "list"
      "watch"
    ])
  ]);

  reconcile = mkIntent (ref: [
    (rule ref [
      "get"
      "list"
      "watch"
    ])
    (rule ref [
      "patch"
      "update"
    ])
    (rule (sub "status" ref) [
      "patch"
      "update"
    ])
  ]);

  finalize = mkIntent (ref: [ (rule (sub "finalizers" ref) [ "update" ]) ]);

  own = mkIntent (ref: [
    (rule ref [
      "get"
      "list"
      "watch"
      "create"
      "delete"
    ])
  ]);

  readWrite = mkIntent (ref: [
    (rule ref [
      "get"
      "list"
      "watch"
      "create"
      "update"
      "delete"
    ])
  ]);

  full = mkIntent (ref: [
    (rule ref [
      "get"
      "list"
      "watch"
      "create"
      "update"
      "delete"
      "patch"
    ])
  ]);

  emit = mkIntent (ref: [
    (rule ref [
      "create"
      "patch"
    ])
  ]);

  watchAndFinalize = mkIntent (ref: [
    (rule ref [
      "get"
      "list"
      "watch"
    ])
    (rule (sub "finalizers" ref) [ "update" ])
  ]);

  allow = verbs: mkIntent (ref: [ (rule ref verbs) ]);

  grant =
    intents:
    let
      flat = lib.concatLists intents;
      ruleKey =
        r:
        builtins.unsafeDiscardStringContext (
          builtins.toJSON {
            inherit (r) apiGroups verbs;
            resourceNames = r.resourceNames or null;
          }
        );
      grouped = builtins.foldl' (
        acc: r:
        let
          key = ruleKey r;
        in
        acc
        // {
          ${key} =
            if acc ? ${key} then
              acc.${key}
              // {
                resources = acc.${key}.resources ++ r.resources;
              }
            else
              r;
        }
      ) { } flat;
    in
    builtins.attrValues grouped;

  mkClusterRoleSet = scope: buildRoleSet "ClusterRole" "ClusterRoleBinding" scope.mkClusterResource;

  mkRoleSet = scope: buildRoleSet "Role" "RoleBinding" scope.mkResource;
}

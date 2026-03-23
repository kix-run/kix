# lib/rbac.nix — pipe-friendly RBAC DSL for kixpkgs.
#
# Concepts:
#   Ref    = { apiGroup; resource; resourceNames? }  — pointer to a K8s resource type
#   Intent = Ref | [Ref] -> [Rule]                    — permission pattern (single or list)
#   grant  = [[Rule]] -> [Rule]                       — flatten + merge intent results
#
# Pipe idiom:
#   cm.issuers |> reconcile                          ref  |> intent
#   cm.signers |> restrictTo [...] |> allow ["approve"]
#   [cm.issuers cm.signers] |> watch                 list |> intent (rules merged by grant)

{ lib }:

let
  mkRef = apiGroup: resource: {
    inherit apiGroup resource;
    resourceNames = null;
  };

  rule = ref: verbs:
    { apiGroups = [ ref.apiGroup ]; resources = [ ref.resource ]; inherit verbs; }
    // lib.optionalAttrs (ref.resourceNames != null) { inherit (ref) resourceNames; };

  # Lifts a single-ref intent to accept Ref | [Ref].
  mkIntent = f: refOrRefs:
    if builtins.isList refOrRefs
    then builtins.concatMap f refOrRefs
    else f refOrRefs;

in rec {

  # ── Ref constructors ─────────────────────────────────────────────────

  # group "api.group" ["res1" "res2"]
  #   → attrset with dot access (cm.res1) AND callable fallback (cm "res3")
  group = apiGroup: resources:
    lib.genAttrs resources (r: mkRef apiGroup r)
    // { __functor = _: r: mkRef apiGroup r; };

  # core — the "" API group, pre-populated with common resources.
  core = group "" [
    "configmaps" "endpoints" "events" "namespaces" "nodes"
    "persistentvolumeclaims" "persistentvolumes"
    "pods" "secrets" "serviceaccounts" "services"
  ];

  # ── Ref modifiers ────────────────────────────────────────────────────

  # restrictTo names — scope to specific resourceNames, chain before intent.
  restrictTo = names: ref: ref // { resourceNames = names; };

  # sub suffix — access a sub-resource (e.g., sub "status", sub "finalizers").
  # Works with map for lists: map (sub "status") refs |> allow [...]
  sub = suffix: ref:
    ref // { resource = "${ref.resource}/${suffix}"; resourceNames = null; };

  # ── Intents: Ref | [Ref] -> [Rule] ────────────────────────────────

  watch            = mkIntent (ref: [ (rule ref [ "get" "list" "watch" ]) ]);

  reconcile        = mkIntent (ref: [ (rule ref                    [ "get" "list" "watch" ])
                                       (rule ref                   [ "patch" "update" ])
                                       (rule (sub "status" ref)    [ "patch" "update" ]) ]);

  finalize         = mkIntent (ref: [ (rule (sub "finalizers" ref) [ "update" ]) ]);

  own              = mkIntent (ref: [ (rule ref [ "get" "list" "watch" "create" "delete" ]) ]);

  readWrite        = mkIntent (ref: [ (rule ref [ "get" "list" "watch" "create" "update" "delete" ]) ]);

  full             = mkIntent (ref: [ (rule ref [ "get" "list" "watch" "create" "update" "delete" "patch" ]) ]);

  emit             = mkIntent (ref: [ (rule ref [ "create" "patch" ]) ]);

  watchAndFinalize = mkIntent (ref: [ (rule ref                        [ "get" "list" "watch" ])
                                       (rule (sub "finalizers" ref)    [ "update" ]) ]);

  allow            = verbs: mkIntent (ref: [ (rule ref verbs) ]);

  # ── grant ────────────────────────────────────────────────────────────

  # [[Rule]] -> [Rule], merging rules with identical apiGroups + verbs + resourceNames.
  grant = intents:
    let
      flat = lib.concatLists intents;
      # Build a merge key from the parts that must match to combine rules.
      ruleKey = r:
        builtins.unsafeDiscardStringContext (builtins.toJSON {
          inherit (r) apiGroups verbs;
          resourceNames = r.resourceNames or null;
        });
      # Group by key, merge resources lists.
      grouped = builtins.foldl' (acc: r:
        let key = ruleKey r;
        in acc // {
          ${key} = if acc ? ${key}
            then acc.${key} // {
              resources = acc.${key}.resources ++ r.resources;
            }
            else r;
        }
      ) {} flat;
    in
    builtins.attrValues grouped;

  # ── mkClusterRoleSet ─────────────────────────────────────────────────

  # Creates paired ClusterRole + ClusterRoleBinding for every entry in `roles`.
  #
  # Returns a flat attrset of kix resources:
  #   { roleName = <ClusterRole>; "${roleName}-binding" = <ClusterRoleBinding>; ... }
  #
  # Merge onto self with //, list for requires with builtins.attrValues:
  #   self: let roles = mkClusterRoleSet scope { ... }; in {
  #     main.requires = builtins.attrValues roles ++ [...];
  #   } // roles
  mkClusterRoleSet = scope: { subjects, labels ? {}, roles }:
    builtins.listToAttrs (lib.concatMap (roleName:
      let
        entry = roles.${roleName};
        # Accept either plain rules list or { rules, bindingName? }.
        rules       = if builtins.isList entry then entry else entry.rules;
        bindingName = if builtins.isList entry then roleName else entry.bindingName or roleName;
        role = scope.mkClusterResource {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "ClusterRole";
          name = roleName;
          inherit labels;
          extra.rules = rules;
        };
        binding = scope.mkClusterResource {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "ClusterRoleBinding";
          name = bindingName;
          inherit labels;
          extra = {
            roleRef = {
              apiGroup = "rbac.authorization.k8s.io";
              kind = "ClusterRole";
              name = role.out.name;
            };
            inherit subjects;
          };
        };
      in [
        { name = roleName;              value = role; }
        { name = "${roleName}-binding"; value = binding; }
      ]
    ) (builtins.attrNames roles));

  # ── mkRoleSet (namespace-scoped) ─────────────────────────────────────

  mkRoleSet = scope: { subjects, labels ? {}, roles }:
    builtins.listToAttrs (lib.concatMap (roleName:
      let
        entry = roles.${roleName};
        # Accept either plain rules list or { rules, bindingName? }.
        rules       = if builtins.isList entry then entry else entry.rules;
        bindingName = if builtins.isList entry then roleName else entry.bindingName or roleName;
        role = scope.mkResource {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "Role";
          name = roleName;
          inherit labels;
          extra.rules = rules;
        };
        binding = scope.mkResource {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "RoleBinding";
          name = bindingName;
          inherit labels;
          extra = {
            roleRef = {
              apiGroup = "rbac.authorization.k8s.io";
              kind = "Role";
              name = role.out.name;
            };
            inherit subjects;
          };
        };
      in [
        { name = roleName;              value = role; }
        { name = "${roleName}-binding"; value = binding; }
      ]
    ) (builtins.attrNames roles));
}

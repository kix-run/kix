# lib/rbac.nix — pipe-friendly RBAC DSL for kixpkgs.
#
# Concepts:
#   Ref    = { apiGroup; resource; resourceNames? }  — pointer to a K8s resource type
#   Intent = Ref -> [Rule]                            — permission pattern
#   grant  = [[Rule]] -> [Rule]                       — flatten intent results
#
# Pipe idiom:
#   cm.issuers |> reconcile            ref |> intent
#   cm.signers |> restrictTo [...] |> allow ["approve"]

{ lib }:

let
  mkRef = apiGroup: resource: {
    inherit apiGroup resource;
    resourceNames = null;
  };

  rule = ref: verbs:
    { apiGroups = [ ref.apiGroup ]; resources = [ ref.resource ]; inherit verbs; }
    // lib.optionalAttrs (ref.resourceNames != null) { inherit (ref) resourceNames; };

  sub = suffix: ref:
    ref // { resource = "${ref.resource}/${suffix}"; resourceNames = null; };

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

  # ── Ref modifier ─────────────────────────────────────────────────────

  # restrictTo names — scope to specific resourceNames, chain before intent.
  restrictTo = names: ref: ref // { resourceNames = names; };

  # ── Intents: Ref -> [Rule] ──────────────────────────────────────────

  watch            = ref: [ (rule ref [ "get" "list" "watch" ]) ];

  reconcile        = ref: [ (rule ref                    [ "get" "list" "watch" ])
                             (rule (sub "status" ref)    [ "update" "patch" ]) ];

  finalize         = ref: [ (rule (sub "finalizers" ref) [ "update" ]) ];

  own              = ref: [ (rule ref [ "get" "list" "watch" "create" "delete" ]) ];

  readWrite        = ref: [ (rule ref [ "get" "list" "watch" "create" "update" "delete" ]) ];

  full             = ref: [ (rule ref [ "get" "list" "watch" "create" "update" "delete" "patch" ]) ];

  emit             = ref: [ (rule ref [ "create" "patch" ]) ];

  watchAndFinalize = ref: [ (rule ref                        [ "get" "list" "watch" ])
                             (rule (sub "finalizers" ref)    [ "update" ]) ];

  allow            = verbs: ref: [ (rule ref verbs) ];

  # ── grant ────────────────────────────────────────────────────────────

  grant = lib.concatLists;   # [[Rule]] -> [Rule]

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
        rules = roles.${roleName};
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
          name = roleName;
          inherit labels;
          extra = {
            roleRef = {
              apiGroup = "rbac.authorization.k8s.io";
              kind = "ClusterRole";
              name = "${role}";
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
        rules = roles.${roleName};
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
          name = roleName;
          inherit labels;
          extra = {
            roleRef = {
              apiGroup = "rbac.authorization.k8s.io";
              kind = "Role";
              name = "${role}";
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

# Tests for the `cluster-admin` unsafe grant and the
# `security.noClusterAdmin` rule that enforces its absence.

{
  lib,
  mkCluster,
  baseInstances,
  manifests,
  evalFails,
  netpolOn,
  ofKind,
  byName,
  kixKeys,
  ...
}:

let
  # A ServiceAccount bound to cluster-admin, a ClusterRole with an
  # all-wildcard rule, and two shapes the rule leaves alone: a wildcard
  # limited to one API group and a namespaced RoleBinding to cluster-admin.
  mkAdminPackage =
    {
      unsafe ? [ ],
    }:
    {
      meta = {
        version = "test";
        inherit unsafe;
      };
      build =
        { self, scope, ... }:
        {
          sa = scope.mkResource {
            apiVersion = "v1";
            kind = "ServiceAccount";
            name = "backup";
          };
          binding = scope.mkClusterResource {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = "ClusterRoleBinding";
            name = "backup-admin";
            extra = {
              roleRef = {
                apiGroup = "rbac.authorization.k8s.io";
                kind = "ClusterRole";
                name = "cluster-admin";
              };
              subjects = [
                {
                  kind = "ServiceAccount";
                  name = "backup";
                  namespace = scope.namespaceName;
                }
              ];
            };
          };
          wildcardRole = scope.mkClusterResource {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = "ClusterRole";
            name = "backup-everything";
            extra.rules = [
              {
                apiGroups = [ "*" ];
                resources = [ "*" ];
                verbs = [ "*" ];
              }
            ];
          };
          groupRole = scope.mkClusterResource {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = "ClusterRole";
            name = "backup-one-group";
            extra.rules = [
              {
                apiGroups = [ "example.com" ];
                resources = [ "*" ];
                verbs = [ "*" ];
              }
            ];
          };
          namespacedBinding = scope.mkResource {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = "RoleBinding";
            name = "backup-local-admin";
            extra = {
              roleRef = {
                apiGroup = "rbac.authorization.k8s.io";
                kind = "ClusterRole";
                name = "cluster-admin";
              };
              subjects = [
                {
                  kind = "ServiceAccount";
                  name = "backup";
                  namespace = scope.namespaceName;
                }
              ];
            };
          };
          root = {
            resource = self.sa;
            requires = [
              self.binding
              self.wildcardRole
              self.groupRole
              self.namespacedBinding
            ];
          };
        };
    };

  rules = import ../../rules { inherit lib; };

  # Only the rule under test and the audit rule, so the base instances'
  # other findings do not fail the cluster. Reading `scorecardReport` of a
  # cluster whose cap lets an error through raises the error, so findings
  # are read at the `warning` cap and failure is checked at `error`.
  mkAdminCluster =
    maxSeverity: unsafe:
    mkCluster [
      baseInstances
      {
        scorecard = {
          enable = true;
          inherit maxSeverity;
          rules = {
            security = { inherit (rules.security) noClusterAdmin; };
            architecture = { inherit (rules.architecture) unsafeGrants; };
          };
        };
        instances.backup.backup.package = mkAdminPackage { inherit unsafe; };
      }
    ];

  # The velero package with its two secrets, its store wired to the base
  # instances' db Service, under network policy.
  veleroCluster = mkCluster [
    baseInstances
    netpolOn
    (
      { ref, ... }:
      {
        instances.velero = {
          cloud = {
            package = import ../../../packages/secret;
            aliases = [ "cloudCredentials" ];
            config.stringData.cloud = "[default]";
          };
          velero-repo-credentials = {
            package = import ../../../packages/secret;
            aliases = [ "repositoryPassword" ];
            config.stringData.repository-password = "key";
          };
          velero = {
            package = import ../../../packages/velero;
            config.backupStorageLocation.objectStorage.bucket = "b";
            deps.objectStorage = ref.dbns.db;
          };
        };
      }
    )
  ];

  findingsOf =
    rule: cluster:
    builtins.filter (f: f.rule == rule && f.instance == "backup") cluster.scorecardReport.findings;
in
{
  # Without the grant, the binding and the all-wildcard ClusterRole each
  # produce a finding naming the resource (and, for the binding, its
  # subject), and the cluster fails at the `error` cap. The one-group
  # wildcard and the RoleBinding produce none.
  velero-no-cluster-admin-without-grant =
    let
      found = findingsOf "security.noClusterAdmin" (mkAdminCluster "warning" [ ]);
      messages = map (f: f.message) found;
      has = needle: builtins.any (lib.hasInfix needle) messages;
    in
    (
      builtins.length found == 2
      && rules.security.noClusterAdmin.severity == "error"
      && has "ClusterRoleBinding 'backup-admin' grants cluster-admin to ServiceAccount backup/backup"
      && has "ClusterRole 'backup-everything' grants every verb"
      && has "scope.rbac"
      && has "meta.unsafe"
      && evalFails (mkAdminCluster "error" [ ])
    )
    || throw "noClusterAdmin without the grant: ${builtins.toJSON found}";

  # With the grant, the rule reports nothing, the cluster builds, and the
  # grant is listed by architecture.unsafeGrants.
  velero-no-cluster-admin-with-grant =
    let
      cluster = mkAdminCluster "error" [ "cluster-admin" ];
      found = findingsOf "security.noClusterAdmin" cluster;
      audit = findingsOf "architecture.unsafeGrants" cluster;
    in
    (
      found == [ ]
      && builtins.any (f: f.severity == "info" && lib.hasInfix "'cluster-admin'" f.message) audit
      && builtins.length (manifests cluster) > 0
    )
    || throw "noClusterAdmin with the grant: findings ${builtins.toJSON found}, audit ${builtins.toJSON audit}";

  # The policies derived for a terminate-declared CR do not require the CR:
  # the location's readiness (Available) needs the store connection those
  # policies open, so requiring it would leave the deploy waiting until it
  # times out.
  velero-operand-policies-do-not-wait-for-cr =
    let
      ms = manifests veleroCluster;
      bslHash = builtins.unsafeDiscardStringContext veleroCluster.instances.velero.velero.raw.backupStorageLocation.out.identityHash;
      cnps = ofKind "CiliumNetworkPolicy" ms;
      egress = byName "velero-backupstoragelocation-default-egress" cnps;
      ingress = byName "velero-backupstoragelocation-default-to-db-ingress" cnps;
      dependsOn = m: (m.metadata.annotations or { }).${kixKeys.dependsOn} or "";
    in
    (
      egress != null
      && ingress != null
      && ingress.metadata.namespace == "dbns"
      && !(lib.hasInfix bslHash (dependsOn egress))
      && !(lib.hasInfix bslHash (dependsOn ingress))
    )
    || throw "operand policies: egress ${builtins.toJSON (egress.metadata or null)}, ingress ${
      builtins.toJSON (ingress.metadata or null)
    }";
}

# Tests for the ingress-nginx package: every RBAC object it builds reaches
# the manifest set, snippet annotations need the Critical risk level, the
# Service selector cannot be overridden, and `env` takes a Secret managed
# outside Kix.

{
  lib,
  kixlib,
  mkCluster,
  baseInstances,
  manifests,
  ofKind,
  byName,
  evalFails,
  ...
}:

let
  ingressNginx = import ../../../packages/ingress-nginx;

  # One instance in namespace `ingress`, beside the shared DNS provider.
  clusterWith =
    config:
    mkCluster [
      {
        instances.dns = baseInstances.instances.dns;
        instances.ingress.ingress-nginx = {
          package = ingressNginx;
          inherit config;
        };
      }
    ];

  namesOfKind = kind: cluster: map (m: m.metadata.name) (ofKind kind (manifests cluster));
  controllerEnv =
    cluster:
    (builtins.head (byName "ingress-nginx" (ofKind "Deployment" (manifests cluster))).spec.template.spec.containers).env;
in
{
  ingress-nginx-renders-cluster-rbac =
    let
      cluster = clusterWith { };
      roles = ofKind "Role" (manifests cluster);
      leaseRole = byName "ingress-nginx" roles;
    in
    lib.sort lib.lessThan (namesOfKind "ClusterRole" cluster) == [
      "ingress-ingress-nginx"
      "ingress-ingress-nginx-admission"
    ]
    &&
      lib.sort lib.lessThan (namesOfKind "ClusterRoleBinding" cluster) == [
        "ingress-ingress-nginx"
        "ingress-ingress-nginx-admission"
      ]
    && byName "ingress-nginx-admission" roles != null
    && lib.all (r: r.resources == [ "leases" ]) leaseRole.rules;

  ingress-nginx-snippets-need-critical-risk =
    evalFails (clusterWith { settings."allow-snippet-annotations" = "true"; })
    && !evalFails (
      clusterWith {
        settings = {
          "allow-snippet-annotations" = "true";
          "annotations-risk-level" = "Critical";
        };
      }
    );

  ingress-nginx-service-spec-selector-locked = evalFails (clusterWith {
    service.spec.selector.app = "other";
  });

  ingress-nginx-env-untracked-secret =
    let
      license = lib.findFirst (e: e.name == "MAXMIND_LICENSE_KEY") null (
        controllerEnv (clusterWith {
          env.MAXMIND_LICENSE_KEY.valueFrom.secretKeyRef = {
            name = kixlib.untrackedRef "maxmind";
            key = "license-key";
          };
        })
      );
    in
    license.valueFrom.secretKeyRef == {
      name = "maxmind";
      key = "license-key";
    };
}

# Namespace builder — Namespace resource + quota + network policies.

{ lib, k8s }:

let
  inherit (k8s) clusterScoped mkResource;
in

{
  # Namespace as a small inner fixpoint — Namespace resource + policies.
  mkNamespace =
    {
      name,
      labels ? { },
      annotations ? { },
      resourceQuota ? null,
      networkPolicies ? { },
    }:
    lib.fix (ns: {
      resource = mkResource {
        apiVersion = "v1";
        kind = "Namespace";
        inherit name;
        namespace = clusterScoped;
        labels = labels // {
          "kubernetes.io/metadata.name" = name;
          "app.kubernetes.io/managed-by" = "kix";
        };
        inherit annotations;
        requires = lib.optional (resourceQuota != null) ns.quota ++ builtins.attrValues ns.netpols;
      };

      quota =
        if resourceQuota != null then
          mkResource {
            apiVersion = "v1";
            kind = "ResourceQuota";
            name = "${name}-quota";
            namespace = name; # plain string — internal to namespace package
            spec.hard = resourceQuota;
          }
        else
          null;

      netpols = lib.mapAttrs (
        polName: pol:
        mkResource {
          apiVersion = "networking.k8s.io/v1";
          kind = "NetworkPolicy";
          name = "${name}-${polName}";
          namespace = name;
          spec = pol;
        }
      ) networkPolicies;

      root = ns.resource;
      inherit name;
      outPath = ns.resource.outPath;
    });
}

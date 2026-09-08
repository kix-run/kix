{ lib, k8s }:

let
  inherit (k8s) clusterScoped mkResource;
in

{
  mkNamespace =
    {
      name,
      labels ? { },
      annotations ? { },
      resourceQuota ? null,
      networkPolicies ? { },
    }:
    let
      # Bare k8s.mkResource stamps no labels; every other sealing path
      # marks its output as kix-managed, and the cross-resource checks
      # require it.
      managedBy = {
        "app.kubernetes.io/managed-by" = "kix";
      };
    in
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
            namespace = name;
            labels = managedBy;
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
          labels = managedBy;
          spec = pol;
        }
      ) networkPolicies;

      root = ns.resource;
      inherit name;
      outPath = ns.resource.outPath;
    });
}

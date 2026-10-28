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
      # Pod Security Standards level, or null for no label.
      podSecurity ? null,
    }:
    let
      # Bare k8s.mkResource stamps no labels. Cross-resource validation
      # requires every resource to carry the Kix managed-by label.
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
        labels =
          labels
          // {
            "kubernetes.io/metadata.name" = name;
            "app.kubernetes.io/managed-by" = "kix";
          }
          // lib.optionalAttrs (podSecurity != null) {
            "pod-security.kubernetes.io/enforce" = podSecurity;
          };
        inherit annotations;
      };

      quota =
        if resourceQuota != null then
          mkResource {
            apiVersion = "v1";
            kind = "ResourceQuota";
            name = "${name}-quota";
            namespace = ns.inside;
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
          namespace = ns.inside;
          labels = managedBy;
          spec = pol;
        }
      ) networkPolicies;

      # Pass the Namespace store path to the quota and policies so they are
      # applied after the Namespace.
      inside = {
        inherit name;
        inherit (ns.resource) outPath;
      };

      root = ns.resource;
      # Attach the quota and NetworkPolicy store paths to the namespace name
      # so resources in the namespace are applied after them.
      name = builtins.appendContext name (
        builtins.foldl' (acc: r: acc // builtins.getContext "${r}") { } (
          lib.optional (ns.quota != null) ns.quota ++ builtins.attrValues ns.netpols
        )
      );
      outPath = ns.resource.outPath;
    });
}

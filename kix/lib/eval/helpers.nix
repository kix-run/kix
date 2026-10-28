{ lib }:

rec {
  # The built-in kinds Kubernetes serves cluster-scoped. helm.nix renders
  # these without a namespace, and validate.nix resolves references to them
  # through the cluster-scoped bucket.
  builtInClusterScopedKinds = [
    "APIService"
    "CertificateSigningRequest"
    "ClusterRole"
    "ClusterRoleBinding"
    "CSIDriver"
    "CSINode"
    "CustomResourceDefinition"
    "IngressClass"
    "MutatingWebhookConfiguration"
    "Namespace"
    "Node"
    "PersistentVolume"
    "PriorityClass"
    "RuntimeClass"
    "StorageClass"
    "ValidatingAdmissionPolicy"
    "ValidatingAdmissionPolicyBinding"
    "ValidatingWebhookConfiguration"
    "VolumeAttachment"
  ];

  mergeCollide =
    context: a: b:
    let
      collisions = builtins.intersectAttrs a b;
    in
    if collisions == { } then
      a // b
    else
      throw "${context}: key collision on ${builtins.concatStringsSep ", " (builtins.attrNames collisions)}";

  collectTypedAttrs =
    {
      excludeKeys ? [ ],
      maxDepth ? 3,
    }:
    attrs:
    let
      go =
        depth: a:
        builtins.concatMap (
          n:
          let
            v = a.${n};
          in
          if v == null then
            [ ]
          else if !(builtins.isAttrs v) then
            [ ]
          else if v ? _type then
            [ v ]
          else if depth >= maxDepth then
            [ ]
          else
            go (depth + 1) v
        ) (builtins.attrNames (removeAttrs a excludeKeys));
    in
    go 0 attrs;

  # Return the resources rendered from an instance's parts, excluding its
  # PackageInstance and hook resources. Managed instances store their parts
  # under `raw` because top-level keys expose only the package's `out`
  # interface. Exclude `root` because it aliases a named part.
  instancePartResources =
    inst:
    let
      raw =
        inst.raw or (removeAttrs inst [
          "_type"
          "_meta"
          "_packageInstance"
          "_diagnostics"
          "_scorecardFindings"
          "_isImport"
          "root"
          "fqdn"
          "out"
          "overrideParts"
        ]);
    in
    builtins.filter (v: (v._type or "") == "k8s-resource") (
      collectTypedAttrs {
        excludeKeys = [
          "root"
          "meta"
        ];
      } raw
    );

  knownFolders = {
    secrets = {
      expectedTypes = [ "k8s-resource" ];
    };
    crds = {
      expectedTypes = [ "k8s-resource" ];
    };
  };
}

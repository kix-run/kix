# Declare that this cluster gives pods AWS roles through a self-hosted
# amazon-eks-pod-identity-webhook, for a cluster outside EKS that is
# federated to AWS (kubeadm, k3s, Talos, RKE2).
#
# Usage:
#   modules = [
#     kix.flavors.kubeadm
#     kix.modules.experimental.irsa-webhook
#     # Only when the webhook runs with another --annotation-prefix:
#     { irsaWebhook.annotationPrefix = "irsa.example.com"; }
#   ];
#
# A package then renders `kix.cloudIdentity.aws { roleArn = "..."; }` as the
# annotation `<annotationPrefix>/role-arn` on its ServiceAccount. Kix neither
# installs the webhook nor registers the cluster's OIDC issuer in IAM.

{
  config,
  lib,
  kix,
  ...
}:
let
  platformCloudIdentity = import ../../lib/flavors/cloud-identity.nix { inherit kix; };
  mechanisms = import ../../lib/vocab/cloud-identity-mechanisms.nix { inherit lib; };
in
{
  options.irsaWebhook.annotationPrefix = lib.mkOption {
    type = lib.types.str;
    default = "eks.amazonaws.com";
    description = ''
      Annotation domain matching the `--annotation-prefix` flag passed to
      `amazon-eks-pod-identity-webhook`. Kix writes IAM role ARNs to
      `<annotationPrefix>/role-arn` on ServiceAccounts and allows annotations
      under `<annotationPrefix>` in `architecture.annotationDomainOwnership`.
    '';
  };

  config.instances.kube-system.cloud-identity = platformCloudIdentity {
    mechanism = mechanisms.irsa { inherit (config.irsaWebhook) annotationPrefix; };
  };
}

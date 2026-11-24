# Declare that this cluster gives pods Azure identities through a
# self-hosted Azure Workload Identity webhook, for a cluster outside AKS
# that is federated to Microsoft Entra ID.
#
# Usage:
#   modules = [
#     kix.flavors.kubeadm
#     kix.modules.experimental.azure-workload-identity-webhook
#   ];
#
# A package then renders `kix.cloudIdentity.azure { clientId = "..."; }` as
# the `azure.workload.identity/client-id` annotation on its ServiceAccount
# and the `azure.workload.identity/use` label on its pods. Kix neither
# installs the webhook nor creates the federated credential.

{ lib, kix, ... }:
let
  platformCloudIdentity = import ../../lib/flavors/cloud-identity.nix { inherit kix; };
  mechanisms = import ../../lib/vocab/cloud-identity-mechanisms.nix { inherit lib; };
in
{
  instances.kube-system.cloud-identity = platformCloudIdentity {
    mechanism = mechanisms.azureWorkloadId { };
  };
}

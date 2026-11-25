# clusters/test-cloud-identity-aks.nix: workload cloud identity on the aks
# flavor, which gives pods Azure identities through Microsoft Entra Workload
# ID.
#
# `external-dns/azure-dns` acts as a user-assigned managed identity. Its
# ServiceAccount carries the client ID, and its pod template carries the
# `azure.workload.identity/use` label the webhook acts on. external-dns also
# reads its Azure settings from /etc/kubernetes/azure.json, which this
# package does not render. A real cluster mounts that file with
# `partsOverlays`.
#
# `cert-manager/cert-manager` acts as a managed identity too. Its controller
# ServiceAccount carries the client ID, and its controller pod carries the
# label and `checksum/cloud-identity`. The ClusterIssuer
# `cert-manager/letsencrypt` solves DNS-01 through Azure DNS with no client
# secret, so cert-manager calls Azure DNS with the controller's identity.
#
# Build:   kix check cloud-identity-aks
{ kix, packages }:

kix.buildCluster {
  name = "cloud-identity-aks";
  modules = [
    kix.flavors.aks

    {
      instances.external-dns.azure-dns = {
        package = packages.experimental.external-dns;
        deps.providerCredentials = kix.cloudIdentity.azure {
          clientId = "00000000-0000-0000-0000-000000000000";
        };
        config = {
          provider = "azure";
          policy = "upsert-only";
          txtOwnerId = "cloud-identity-aks/azure-dns";
          extraArgs = [ "--domain-filter=example.com" ];
        };
      };

      instances.cert-manager.cert-manager = {
        package = packages.experimental.cert-manager;
        deps.controllerIdentity = kix.cloudIdentity.azure {
          clientId = "11111111-1111-1111-1111-111111111111";
        };
      };

      instances.cert-manager.letsencrypt = {
        package = packages.experimental.cluster-issuer;
        config.spec.acme = {
          server = "https://acme-staging-v02.api.letsencrypt.org/directory";
          email = "platform@example.com";
          solvers = [
            {
              dns01.azureDNS = {
                subscriptionID = "22222222-2222-2222-2222-222222222222";
                resourceGroupName = "dns";
                hostedZoneName = "example.com";
              };
            }
          ];
        };
      };
    }
  ];
}

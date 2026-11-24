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
# Build:   kix check cloud-identity-aks
{ kix, packages }:

kix.buildCluster {
  name = "cloud-identity-aks";
  modules = [
    kix.flavors.aks

    {
      instances.external-dns.azure-dns = {
        package = packages.experimental.external-dns;
        cloudIdentity.azure.clientId = "00000000-0000-0000-0000-000000000000";
        config = {
          provider = "azure";
          policy = "upsert-only";
          txtOwnerId = "cloud-identity-aks/azure-dns";
          extraArgs = [ "--domain-filter=example.com" ];
        };
      };
    }
  ];
}

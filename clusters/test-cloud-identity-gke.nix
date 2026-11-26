# clusters/test-cloud-identity-gke.nix: workload cloud identity on the gke
# flavor, which gives pods Google Cloud identities through Workload Identity
# Federation for GKE.
#
# - `external-dns/clouddns` uses direct access: IAM roles are granted to the
#   Kubernetes ServiceAccount itself, so its ServiceAccount carries only
#   `kix.run/cloud-identity`.
# - `external-dns-linked/clouddns` acts as a Google service account, which
#   its ServiceAccount names in `iam.gke.io/gcp-service-account`.
#
# Build:   kix check cloud-identity-gke
{ kix, packages }:

let
  externalDns = txtOwnerId: {
    provider = "google";
    policy = "upsert-only";
    inherit txtOwnerId;
    extraArgs = [
      "--google-project=my-project"
      "--domain-filter=example.com"
    ];
  };
in
kix.buildCluster {
  name = "cloud-identity-gke";
  modules = [
    kix.flavors.gke

    {
      # region:gkeIdentityDirect
      instances.external-dns.clouddns = {
        package = packages.experimental.external-dns;
        deps.providerCredentials = kix.cloudIdentity.gcp { };
        config = externalDns "cloud-identity-gke/direct";
      };
      # endregion:gkeIdentityDirect

      # region:gkeIdentityLinked
      instances.external-dns-linked.clouddns = {
        package = packages.experimental.external-dns;
        deps.providerCredentials = kix.cloudIdentity.gcp {
          serviceAccount = "external-dns@my-project.iam.gserviceaccount.com";
        };
        config = externalDns "cloud-identity-gke/linked";
      };
      # endregion:gkeIdentityLinked
    }
  ];
}

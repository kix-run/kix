# clusters/test-cloud-identity-eks-pod-identity.nix: workload cloud identity
# on the eks flavor through EKS Pod Identity.
#
# - `external-dns/route53` declares an IAM role. In this mode Kix writes no
#   role annotation on its ServiceAccount. An EKS Pod Identity association
#   in AWS links the ServiceAccount to the role, and `kix deploy` checks that
#   new pods receive the Pod Identity variables.
#
# Build:   kix check cloud-identity-eks-pod-identity
{ kix, packages }:

kix.buildCluster {
  name = "cloud-identity-eks-pod-identity";
  modules = [
    kix.flavors.eks

    {
      # region:eksPodIdentity
      cluster.flavor.eks.cloudIdentity = "pod-identity";

      instances.external-dns.route53 = {
        package = packages.experimental.external-dns;
        deps.providerCredentials = kix.cloudIdentity.aws {
          roleArn = "arn:aws:iam::111122223333:role/external-dns";
        };
        config = {
          provider = "aws";
          policy = "upsert-only";
          txtOwnerId = "cloud-identity-eks-pod-identity/route53";
          extraArgs = [ "--domain-filter=example.com" ];
        };
      };
      # endregion:eksPodIdentity
    }
  ];
}

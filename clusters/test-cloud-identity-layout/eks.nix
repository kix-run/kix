# clusters/test-cloud-identity-layout/eks.nix: the shared external-dns
# instance on EKS, where it acts as an IAM role. With kind.nix, it shows a
# multi-cluster layout in which the workload definition names no
# credential.
#
# Build:   kix check cloud-identity-layout-eks
{ kix, packages }:

# region:eksCluster
kix.buildCluster {
  name = "cloud-identity-layout-eks";
  specialArgs = { inherit packages; };
  modules = [
    kix.flavors.eks
    ./external-dns.nix
    {
      instances.external-dns.route53.deps.providerCredentials = kix.cloudIdentity.aws {
        roleArn = "arn:aws:iam::111122223333:role/external-dns";
      };
    }
  ];
}
# endregion:eksCluster

# clusters/test-cloud-identity-self-managed.nix: workload cloud identity on
# a kubeadm cluster federated to AWS. The cluster owner runs
# amazon-eks-pod-identity-webhook with `--annotation-prefix=irsa.example.com`
# and registers the cluster's OIDC issuer in IAM. Kix does neither.
#
# The `cloud-identity` import tells Kix that this cluster delivers AWS
# identities through that webhook, so `external-dns/route53` gets the role
# ARN under the webhook's prefix.
#
# Build:   kix check cloud-identity-self-managed
{ kix, packages }:

kix.buildCluster {
  name = "cloud-identity-self-managed";
  modules = [
    kix.flavors.kubeadm

    {
      instances.kube-system.cloud-identity.package = kix.mkImport {
        roles = [ "cloudIdentity" ];
        annotationDomains = [ "irsa.example.com" ];
        out.cloudIdentity = kix.cloudIdentity.irsa { annotationPrefix = "irsa.example.com"; };
      };

      instances.external-dns.route53 = {
        package = packages.experimental.external-dns;
        deps.providerCredentials = kix.cloudIdentity.aws {
          roleArn = "arn:aws:iam::111122223333:role/external-dns";
        };
        config = {
          provider = "aws";
          policy = "upsert-only";
          txtOwnerId = "cloud-identity-self-managed/route53";
          extraArgs = [ "--domain-filter=example.com" ];
        };
      };
    }
  ];
}

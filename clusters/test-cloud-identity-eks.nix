# clusters/test-cloud-identity-eks.nix: workload cloud identity on the eks
# flavor, which gives pods AWS identities through IAM roles for service
# accounts (IRSA).
#
# - `external-dns/route53` acts as an IAM role. Its ServiceAccount carries
#   the role ARN and `kix.run/cloud-identity`, and its pod template carries
#   `checksum/cloud-identity`, so a changed role rolls the pod.
# - `external-dns-keys/route53` reads AWS access keys from a Secret created
#   outside Kix instead. The two differ only in `deps.providerCredentials`.
# - `tracing/tempo` writes trace blocks to an S3 bucket as an IAM role
#   through `deps.storageCredentials`. Its ServiceAccount carries the role
#   ARN, its pod template carries `checksum/cloud-identity`, and its
#   container has no AWS key variables. `tracing/gp3` imports the EBS
#   StorageClass that its claim uses.
# - `annotated/app` writes the IRSA annotation on its ServiceAccount itself.
#   The eks flavor declares the `eks.amazonaws.com` annotation domain, so
#   the scorecard accepts it.
# - `cert-manager/cert-manager` binds an IAM role to its controller
#   ServiceAccount, and the ClusterIssuer `cert-manager/letsencrypt` solves
#   DNS-01 through Route 53 with no key, so cert-manager calls Route 53 with
#   that role.
#
# Build:   kix check cloud-identity-eks
{ kix, packages }:

let
  annotatedServiceAccount =
    { scope, ... }:
    {
      meta = {
        version = "1.0.0";
        description = "ServiceAccount annotated for IRSA without scope.cloudIdentity";
      };
      build =
        { self, ... }:
        {
          serviceAccount = scope.mkResource {
            apiVersion = "v1";
            kind = "ServiceAccount";
            name = "app";
            annotations."eks.amazonaws.com/role-arn" = "arn:aws:iam::111122223333:role/app";
          };
          root = self.serviceAccount;
        };
    };
in
kix.buildCluster {
  name = "cloud-identity-eks";
  modules = [
    kix.flavors.eks

    (
      { ref, ... }:
      {
        # region:eksIrsaInstance
        instances.external-dns.route53 = {
          package = packages.experimental.external-dns;
          deps.providerCredentials = kix.cloudIdentity.aws {
            roleArn = "arn:aws:iam::111122223333:role/external-dns";
          };
          config = {
            provider = "aws";
            policy = "upsert-only";
            txtOwnerId = "cloud-identity-eks/route53";
            extraArgs = [ "--domain-filter=example.com" ];
          };
        };
        # endregion:eksIrsaInstance

        instances.external-dns-keys = {
          # A Secret created outside Kix with the keys AWS_ACCESS_KEY_ID and
          # AWS_SECRET_ACCESS_KEY.
          aws-keys = {
            package = packages.secret-ref;
            config.keys = [
              "AWS_ACCESS_KEY_ID"
              "AWS_SECRET_ACCESS_KEY"
            ];
          };

          route53 = {
            package = packages.experimental.external-dns;
            deps.providerCredentials = ref.external-dns-keys.aws-keys;
            config = {
              provider = "aws";
              policy = "upsert-only";
              txtOwnerId = "cloud-identity-eks/route53-keys";
              extraArgs = [ "--domain-filter=example.com" ];
            };
          };
        };

        instances.tracing = {
          gp3.package = kix.mkImport {
            kind = "StorageClass";
            apiVersion = "storage.k8s.io/v1";
            roles = [ "storageClasses" ];
            out = {
              name = "gp3";
              storageClassName = "gp3";
            };
          };
          storage = {
            package = packages.persistent-volume-claim;
            config.size = "10Gi";
          };
          # region:eksIrsaTempo
          tempo = {
            package = packages.experimental.tempo;
            deps.storageCredentials = kix.cloudIdentity.aws {
              roleArn = "arn:aws:iam::111122223333:role/tempo";
            };
            config = {
              objectStorage.bucket = "traces";
              settings.storage.trace.s3.endpoint = "s3.eu-west-1.amazonaws.com";
            };
          };
          # endregion:eksIrsaTempo
        };

        instances.annotated.app.package = annotatedServiceAccount;

        # region:eksCertManager
        instances.cert-manager.cert-manager = {
          package = packages.experimental.cert-manager;
          deps.controllerIdentity = kix.cloudIdentity.aws {
            roleArn = "arn:aws:iam::111122223333:role/cert-manager";
          };
        };

        instances.cert-manager.letsencrypt = {
          package = packages.experimental.cluster-issuer;
          config.spec.acme = {
            server = "https://acme-staging-v02.api.letsencrypt.org/directory";
            email = "platform@example.com";
            solvers = [ { dns01.route53.region = "eu-west-1"; } ];
          };
        };
        # endregion:eksCertManager
      }
    )
  ];
}

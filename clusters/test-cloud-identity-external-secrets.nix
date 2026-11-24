# clusters/test-cloud-identity-external-secrets.nix: External Secrets
# Operator on the eks flavor, with the controller acting as an IAM role
# through IAM roles for service accounts (IRSA).
#
# - `external-secrets/external-secrets` takes the role in
#   `deps.controllerCredentials`. Its controller ServiceAccount carries the
#   role ARN and `kix.run/cloud-identity`, and the controller's pod template
#   carries `checksum/cloud-identity`. The webhook and the cert-controller
#   call no cloud, so their ServiceAccounts and pods carry neither.
# - `app/secrets` builds an AWS Secrets Manager SecretStore that sets no
#   `auth`, so the controller calls AWS as that role, and an ExternalSecret
#   that reads one key through it.
#
# Build:   kix check cloud-identity-external-secrets
{ kix, packages }:

let
  appSecretsPackage = {
    meta = {
      description = "A SecretStore that uses the controller's cloud identity";
      owner = "app-team";
    };
    build =
      {
        self,
        scope,
        externalSecrets,
        ...
      }:
      {
        # No `auth`: the AWS SDK's default credential chain finds the role
        # that the IRSA webhook gives the controller pods.
        store = externalSecrets.out.mkSecretStore scope {
          name = "aws";
          spec.provider.aws = {
            service = "SecretsManager";
            region = "eu-central-1";
          };
        };

        sync = externalSecrets.out.mkExternalSecret scope {
          name = "billing";
          spec = {
            secretStoreRef = {
              name = self.store.out.name;
              kind = "SecretStore";
            };
            refreshInterval = "1h";
            data = [
              {
                secretKey = "API_KEY";
                remoteRef = {
                  key = "billing";
                  property = "api-key";
                };
              }
            ];
          };
        };

        credentials = self.sync.out.secretRef { keys = [ "API_KEY" ]; };
        root = self.credentials;
      };
  };
in
kix.buildCluster {
  name = "cloud-identity-external-secrets";
  modules = [
    kix.flavors.eks

    {
      instances.external-secrets.external-secrets = {
        package = packages.experimental.external-secrets;
        deps.controllerCredentials = kix.cloudIdentity.aws {
          roleArn = "arn:aws:iam::111122223333:role/external-secrets";
        };
      };

      instances.app.secrets.package = appSecretsPackage;
    }
  ];
}

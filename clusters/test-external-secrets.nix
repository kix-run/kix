# clusters/test-external-secrets.nix: External Secrets Operator on kind.
#
# The operator with metrics (prometheus-operator) and network policy (cilium)
# on, and a consumer namespace whose workload reads a Secret the operator
# writes. The SecretStore uses upstream's `fake` provider, which serves the
# values in its spec and needs no account. A Password generator feeds a
# second ExternalSecret through `dataFrom`. Every custom resource waits for
# the webhook check Job, so a deploy proves the cert-controller injected the
# webhook's CA before the first ExternalSecret was written.
#
# The builders' refusals and the secret-dependency path of mkSecretStore are
# covered by kix/lib/tests/units/external-secrets.nix.
#
# Build:  kix build external-secrets

{ kix, packages }:

let
  # Test values only: the fake provider serves them from the SecretStore
  # spec.
  fakeData = {
    username = "app";
    password = "fake-password";
    host = "db.example.test";
    port = "5432";
  };

  appSecretsPackage = {
    meta = {
      description = "ExternalSecrets for the secret-echo test workload";
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
        store = externalSecrets.out.mkSecretStore scope {
          name = "fake";
          spec.provider.fake.data = map (key: {
            inherit key;
            value = fakeData.${key};
          }) (builtins.attrNames fakeData);
        };

        sync = externalSecrets.out.mkExternalSecret scope {
          name = "app-credentials";
          spec = {
            secretStoreRef = {
              name = self.store.out.name;
              kind = "SecretStore";
            };
            refreshInterval = "1h";
            data = map (key: {
              secretKey = key;
              remoteRef.key = key;
            }) (builtins.attrNames fakeData);
          };
        };

        password = scope.mkCR externalSecrets.out.crds.Password {
          name = "session-key";
          spec = {
            length = 32;
            digits = 5;
            symbols = 0;
            noUpper = false;
            allowRepeat = true;
          };
        };

        generated = externalSecrets.out.mkExternalSecret scope {
          name = "session-key";
          spec = {
            # Generate once; a refresh would rotate the key.
            refreshInterval = "0";
            dataFrom = [
              {
                sourceRef.generatorRef = {
                  apiVersion = "generators.external-secrets.io/v1alpha1";
                  kind = "Password";
                  name = self.password.out.name;
                };
              }
            ];
          };
        };

        sessionKey = self.generated.out.secretRef { keys = [ "password" ]; };

        credentials = self.sync.out.secretRef { keys = builtins.attrNames fakeData; };

        root = {
          resource = self.credentials;
          requires = [ self.sessionKey ];
        };
      };
  };
in
kix.buildCluster {
  name = "test-external-secrets";
  specialArgs = { inherit packages kix; };
  modules = [
    kix.flavors.kind

    (
      { ref, ... }:
      {
        availablePackages = packages;
        networkPolicy.enable = true;
        # kind runs with the default CNI disabled, so the managed cilium
        # instance fills the cni role (test-harbor.nix does the same).
        cluster.roles.cni = {
          binding = "absent";
          provider = null;
        };
        instances.kube-system.cilium.package = packages.experimental.cilium;

        instances.monitoring.prometheus-operator.package = packages.experimental."prometheus-operator";

        instances.external-secrets.external-secrets.package = packages.experimental.external-secrets;

        instances.app = {
          app-secrets.package = appSecretsPackage;
          secret-echo = {
            package = import ./secret-echo.nix;
            deps.credentials = ref.app.app-secrets;
          };
        };
      }
    )
  ];
}

# clusters/test-external-secrets-monitoring.nix: External Secrets Operator
# with the monitoring module and Cilium network policy on kind.
#
# The same instances as test-external-secrets.nix, with a Prometheus server
# that scrapes the operator. The operator names its metrics Services after
# its Deployments, so the scrape join reads Service names that refer to
# other resources; the scrape policies must still build.
#
# Build:  kix check external-secrets-monitoring

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
  name = "test-external-secrets-monitoring";
  specialArgs = { inherit packages kix; };
  modules = [
    kix.flavors.kind
    kix.modules.experimental.monitoring

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

        monitoring.enabled = true;
        instances.monitoring-system.grafana-admin = {
          package = packages.secret;
          aliases = [ "grafanaAdmin" ];
          config.stringData = {
            admin-user = "admin";
            admin-password = "test-only";
          };
        };

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

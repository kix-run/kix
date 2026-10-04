# clusters/test-openbao.nix: OpenBao feeding External Secrets Operator on
# kind, under Cilium network policy.
#
# OpenBao runs with the static seal from a `secret` instance and declares a
# kv engine, a read policy, and a Kubernetes auth role bound to the
# ServiceAccount of the `app` namespace's store. The `app-secrets` package
# builds that ServiceAccount, a ClusterSecretStore from
# `openbao.out.externalSecretsProvider` limited to its namespace by
# `conditions`, an ExternalSecret, and a reference to the Secret it writes.
# The cluster's availability is `none`, so one OpenBao pod runs.
# `openbao-ha` in `secrets-ha` declares nothing and runs three pods at
# availability `pod`, so the alerts that need more than one replica render.
# That level needs `multiNode`, which the cluster declares, so create the
# kind cluster with a worker node.
#
# prometheus-operator gives both instances a metrics listener, a
# ServiceMonitor, and their PrometheusRules, which
# test-openbao.rules-test.yaml tests with promtool. No Prometheus server
# runs, so the scrape paths are not derived here.
#
# OpenBao starts empty: the ExternalSecret becomes ready only after a value
# is written to `secret/app/credentials` (key `password`). The test-only
# role `seed` lets the server's own ServiceAccount write it, so while the
# deploy waits on the ExternalSecret:
#
#   kubectl -n secrets exec openbao-0 -- sh -c 'export BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true;
#     BAO_TOKEN=$(bao write -field=token auth/kubernetes/login role=seed jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token) &&
#     export BAO_TOKEN && bao kv put -mount=secret app/credentials password=test-only'
#
# The refusals of the package and of `out.externalSecretsProvider` are
# covered by kix/lib/tests/units/openbao.nix.
#
# Build:  nix build .#cluster-openbao --extra-experimental-features pipe-operators
# Rules:  nix build ./clusters#checks.x86_64-linux.rules-cluster-openbao --extra-experimental-features pipe-operators

{ kix, packages }:

let
  appSecretsPackage = {
    meta = {
      description = "A ClusterSecretStore on OpenBao and an ExternalSecret";
      owner = "app-team";
    };
    build =
      {
        self,
        scope,
        externalSecrets,
        openbao,
        ...
      }:
      {
        storeServiceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          name = "openbao-store";
        };

        store = externalSecrets.out.mkClusterSecretStore scope {
          name = "openbao-app";
          spec = {
            provider = openbao.out.externalSecretsProvider scope {
              serviceAccount = self.storeServiceAccount;
              role = "app";
              mount = "secret";
            };
            conditions = [ { namespaces = [ scope.namespaceName ]; } ];
          };
        };

        sync = externalSecrets.out.mkExternalSecret scope {
          name = "app-credentials";
          spec = {
            secretStoreRef = {
              name = self.store.out.name;
              kind = "ClusterSecretStore";
            };
            refreshInterval = "1h";
            data = [
              {
                secretKey = "password";
                remoteRef = {
                  key = "app/credentials";
                  property = "password";
                };
              }
            ];
          };
        };

        credentials = self.sync.out.secretRef { keys = [ "password" ]; };

        root = self.credentials;
      };
  };
in
kix.buildCluster {
  name = "test-openbao";
  specialArgs = { inherit packages kix; };
  modules = [
    kix.flavors.kind

    (
      { ref, ... }:
      {
        availablePackages = packages;
        cluster.capabilities.multiNode = true;
        cluster.availability.default = "none";
        networkPolicy.enable = true;
        # kind runs with the default CNI disabled, so the managed cilium
        # instance fills the cni role.
        cluster.roles.cni = {
          binding = "absent";
          provider = null;
        };
        instances.kube-system.cilium.package = packages.cilium;

        instances.monitoring.prometheus-operator.package = packages.prometheus-operator;
        instances.cert-manager.cert-manager.package = packages.cert-manager;
        instances.external-secrets.external-secrets.package = packages.external-secrets;

        instances.secrets = {
          openbao = {
            package = packages.openbao;
            config = {
              secretsEngines.secret = {
                type = "kv";
                options.version = "2";
              };
              policies.app-read = ''
                path "secret/data/app/*" { capabilities = ["read"] }
              '';
              # Test only: lets the seeding command in the header write the
              # value the ExternalSecret reads.
              policies.seed-write = ''
                path "secret/data/app/*" { capabilities = ["create", "update"] }
              '';
              kubernetesAuth.roles.seed = {
                bound_service_account_names = [ "openbao" ];
                bound_service_account_namespaces = [ "secrets" ];
                token_policies = [ "seed-write" ];
                token_ttl = "5m";
              };
              kubernetesAuth.roles.app = {
                bound_service_account_names = [ "openbao-store" ];
                bound_service_account_namespaces = [ "app" ];
                token_policies = [ "app-read" ];
                token_ttl = "1h";
              };
            };
          };
          # Test value only.
          openbao-unseal = {
            package = packages.secret;
            aliases = [ "unsealKey" ];
            config.stringData.key = "6f70656e62616f2d746573742d6f6e6c792d6b65792d6e6f742d736563726574";
          };
        };

        instances.secrets-ha = {
          openbao-ha = {
            package = packages.openbao;
            availability = "pod";
          };
          # Test value only.
          openbao-ha-unseal = {
            package = packages.secret;
            aliases = [ "unsealKey" ];
            config.stringData.key = "6f70656e62616f2d68612d746573742d6f6e6c792d6b65792d6e6f7420736563";
          };
        };

        instances.app.app-secrets = {
          package = appSecretsPackage;
          deps.openbao = ref.secrets.openbao;
        };
      }
    )
  ];
}

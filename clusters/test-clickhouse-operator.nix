# clusters/test-clickhouse-operator.nix: the Altinity operator alone on kind
# (v2_discussions/148, phase 4).
#
# The operator, its four CRDs and the Secret it logs in to ClickHouse with,
# and no installation. What this proves on a live cluster is that the
# operator starts against exactly the CRDs the package ships and then stays
# up: a missing kind shows as a crashloop minutes in, not at startup.
#
# Build:   nix build .#cluster-clickhouse-operator --extra-experimental-features pipe-operators
# Deploy:  kix --flake ./clusters --context kind-kix-clickhouse deploy clickhouse-operator -y
#
{ kix, packages }:

kix.buildCluster {
  name = "test-clickhouse-operator";
  modules = [
    kix.flavors.kind

    {
      # Every rule set, so the package is held to all of them.
      scorecard = {
        enable = true;
        rules = kix.rules;
      };

      instances.clickhouse-system = {
        clickhouse-operator.package = packages.clickhouse-operator;

        # The user the operator creates in every installation and then logs
        # in as. The package has no default for it.
        clickhouse-operator-credentials = {
          package = packages.secret;
          aliases = [ "credentials" ];
          config.stringData = {
            username = "clickhouse_operator";
            password = "operator-dev-password";
          };
        };
      };
    }
  ];
}

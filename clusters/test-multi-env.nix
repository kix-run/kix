# clusters/test-multi-env.nix — one instance set, several environments,
# via `kix.mkEnv`.
#
# `mkEnv` had no build coverage anywhere in the tree, which is how it came
# to add `_envScope` to every generated instance while the instance
# submodule refused that field. Assigning a `mkEnv` result to `instances`
# therefore always failed:
#
#   error: The option `instances.development-app.web._envScope' does not exist.
#
# So this cluster exists mainly to keep `mkEnv` buildable.
#
# Note the sibling `example-multi-env/`, which does the same job the other
# way: one cluster definition per environment, sharing a base module. That
# pattern gives each environment its own activation and its own deploy;
# `mkEnv` puts every environment in one cluster, so they deploy together.
# Neither is the successor to the other.
#
# Build:  nix build .#cluster-multi-env --extra-experimental-features pipe-operators

{ kix, packages }:

let
  # One definition, evaluated once per environment. `env.name` is how a
  # definition varies without being written twice.
  application =
    { env, ... }:
    {
      web = {
        package = packages.echo-server;
        config.message = "hello from ${env.name}";
      };
    };
in
kix.buildCluster {
  name = "test-multi-env";
  modules = [
    {
      # The namespaces are `<env>-<set>`: development-app, production-app.
      # That prefix is the whole isolation mechanism. A plain dependency
      # auto-instantiated for `development-app` lands in `development-app`,
      # because `eval/auto.nix` resolves it into the requesting namespace.
      # Role-named deps are the deliberate exception: they are keyed by the
      # role, so both environments share one provider.
      instances =
        kix.mkEnv "development" { } { app = application; }
        // kix.mkEnv "production" {
          # Per-instance overrides merge into the generated config rather
          # than replacing the instance.
          overrides.app.web.config.replicaCount = 3;
        } { app = application; };
    }
  ];
}

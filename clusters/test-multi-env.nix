# clusters/test-multi-env.nix: One instance set across multiple environments
# via `kix.mkEnv`.
#
# Whereas `example-multi-env/` defines one cluster per environment sharing a
# base module (giving each environment its own activation and deploy), `mkEnv`
# places all environments in one cluster so they deploy together.
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
      # Role-named deps are the exception: they are keyed by the
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

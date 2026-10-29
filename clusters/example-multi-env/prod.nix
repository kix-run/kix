# clusters/example-multi-env/prod.nix: Production environment cluster.
#
# Imports the shared base and overrides for production:
# - Pinned image versions
# - Full resource limits and replicas
# - Scorecard enforcement (errors block the build)
# - Network policies enabled
#
# Build:  nix build .#cluster-prod
# Deploy: kix deploy prod

{ kix, packages }:

kix.buildCluster {
  name = "prod";
  specialArgs = { inherit packages kix; };
  modules = [
    kix.flavors.gke
    ./base.nix

    # Prod-specific overrides.
    (
      { lib, ... }:
      {
        cluster.domain = "example.com";

        # Deploy safety: only allow deploying to the prod context
        # cluster.deploy.allowedContexts = [ "gke_my-project_us-central1_prod" ];

        # Prod gets full resources
        instances.app.my-app.config = {
          image.tag = lib.mkDefault "v1.0.0"; # pinned version
          # replicas = lib.mkDefault 3;
        };

        instances.cache.valkey.config = {
          sentinel = {
            enabled = lib.mkDefault true;
            quorum = lib.mkDefault 2;
          };
        };
      }
    )
  ];
}

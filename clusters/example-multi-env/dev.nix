# clusters/example-multi-env/dev.nix: Dev environment cluster.
#
# Imports the shared base and overrides for development:
# - Smaller resource limits
# - Latest image tags
# - Relaxed security (scorecard warnings instead of errors)
#
# Build:  nix build .#cluster-dev
# Deploy: kix deploy dev

{ kix, packages }:

kix.buildCluster {
  name = "dev";
  specialArgs = { inherit packages kix; };
  modules = [
    kix.flavors.gke
    ./base.nix

    # Dev-specific overrides.
    (
      { lib, ... }:
      {
        cluster.domain = "dev.example.com";

        # Deploy safety: only allow deploying to the dev context
        # cluster.deploy.allowedContexts = [ "gke_my-project_us-central1_dev" ];

        # Dev gets relaxed resources via mkDefault (packages can still override)
        instances.app.my-app.config = {
          image.tag = lib.mkDefault "latest";
          # replicas = lib.mkDefault 1;
        };

        instances.cache.valkey.config = {
          # No HA needed in dev. Without Sentinel, Valkey runs one pod.
          sentinel.enabled = lib.mkDefault false;
        };
      }
    )
  ];
}

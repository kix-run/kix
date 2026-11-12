# The half of the swap fixture that must not notice the swap: File Browser,
# exposed through kix.expose on whatever answers `gateway`. Called with
# `packages` by envoy.nix and traefik.nix, which each add a gateway
# implementation.
{ packages }:
{
  cluster.domain = "swap.test";
  instances.files = {
    filebrowser.package = packages.experimental.filebrowser;
    filebrowser-data = {
      package = packages.persistent-volume-claim;
      aliases = [ "storage" ];
      config.size = "1Gi";
    };
  };
}

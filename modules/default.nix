# Base module for kixpkgs — provides the `manifests` option that all chart
# modules write into.
#
# Each chart module adds entries like:
#   config.manifests."coredns-deployment" = kixlib.mkManifest deployment;
#   config.manifests."coredns-service" = kixlib.mkManifest service;
#
# One entry per resource (not per module). This makes verify-parity.sh work
# because it can compare individual resources by kind against helm template output.

{
  lib,
  pkgs,
  config,
  ...
}:

let
  types = lib.types;

  options.manifests = lib.mkOption {
    type = types.attrsOf types.anything;
    default = { };
    description = "Collected Kubernetes manifests from all enabled modules. Each value is a store path to a JSON file.";
  };

in
{
  # Export the options for module system integration
  inherit options;

  # Export manifests only if the service is enabled
  config = { };
}

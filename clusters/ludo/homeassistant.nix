# HomeAssistant — home automation.
# Phase 2 service: deploy only after cluster proves stable.
#
# Reliability target: 99.9% (~1min downtime/day)
# May need hostNetwork for Zigbee/Z-Wave device access.
#
# DI resolves automatically:
#   clusterIssuer  → cert-manager.cluster-issuers
#   ingressNginx   → ingress-system.ingress-nginx
# Owned by: Luca (application)

# NOTE: HomeAssistant doesn't have a kix package yet.
# This file is a draft — package needs to be created first.

{ config, lib, packages, ... }:
{
  config.instances.homeassistant = {

    # homeassistant = {
    #   package = packages.homeassistant;
    #   config = {
    #     ingress = {
    #       enabled = true;
    #       host = "home.${config.cluster.domain}";
    #     };
    #     # Data on local SSD
    #     # TODO: storageClass = "local-ssd";
    #     storage.size = "5Gi";
    #   };
    # };
  };
}

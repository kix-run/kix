# Vaultwarden — password management.
# Phase 2 service: deploy only after cluster proves stable.
#
# Reliability target: 99.9% (~1min downtime/day)
#
# Uses SQLite (not Postgres) — simpler, fewer moving parts,
# fits the high reliability requirement.
#
# DI resolves automatically:
#   clusterIssuer  → cert-manager.cluster-issuers
#   ingressNginx   → ingress-system.ingress-nginx
# Owned by: Luca (application)

# NOTE: Vaultwarden doesn't have a kix package yet.
# This file is a draft — package needs to be created first.

{
  config,
  lib,
  packages,
  ...
}:
{
  config.instances.vaultwarden = {

    # vaultwarden = {
    #   package = packages.vaultwarden;
    #   config = {
    #     ingress = {
    #       enabled = true;
    #       host = "vault.${config.cluster.domain}";
    #     };
    #     # SQLite data on local SSD for performance
    #     # TODO: storageClass = "local-ssd";
    #     storage.size = "1Gi";
    #     env = {
    #       DOMAIN = "https://vault.${config.cluster.domain}";
    #       SIGNUPS_ALLOWED = "false";
    #       INVITATIONS_ALLOWED = "true";
    #     };
    #   };
    # };
  };
}

# NAS — file browsing & SMB sharing for the family.
# Phase 1 service: Filebrowser web UI + Samba for LAN access.
#
# Parents access SMB directly on the LAN (no VPN needed).
# Remote family members use Filebrowser via Tailscale.
#
# DI resolves automatically:
#   clusterIssuer  → cert-manager.cluster-issuers
#   ingressNginx   → ingress-system.ingress-nginx
# Owned by: Luca (application)

# NOTE: Filebrowser and Samba don't have kix packages yet.
# This file is a draft — packages need to be created first.
# Leaving the structure here so the cluster composition is complete.

{
  config,
  lib,
  packages,
  ...
}:
{
  config.instances.nas = {

    # PVC for NAS data — full ZFS pool mount
    # storage = {
    #   package = packages."persistent-volume-claim";
    #   config = {
    #     size = "10Ti";
    #     # storageClass = "zfs-bulk";
    #   };
    # };

    # Filebrowser — lightweight web file manager
    # filebrowser = {
    #   package = packages.filebrowser;
    #   config = {
    #     ingress = {
    #       enabled = true;
    #       host = "files.${config.cluster.domain}";
    #     };
    #   };
    # };

    # Samba — SMB shares for parents on LAN
    # Exposed via hostNetwork or NodePort (not ingress).
    # samba = {
    #   package = packages.samba;
    #   config = {
    #     shares = {
    #       nas = {
    #         path = "/data/nas";
    #         browseable = true;
    #         writable = true;
    #         validUsers = [ "luca" "helmut" ];
    #       };
    #       photos = {
    #         path = "/data/immich";
    #         browseable = true;
    #         writable = false; # read-only view of Immich library
    #       };
    #     };
    #   };
    # };
  };
}

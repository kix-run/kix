# Immich — photo backup & sharing for the family.
# Phase 1 service: exercises storage, ingress, DI, and backups.
#
# Reliability target: 99% (~15min downtime/day acceptable)
#
# DI resolves automatically:
#   postgres       → data.postgres (cluster-wide, via alias)
#   valkey         → data.valkey (cluster-wide, via alias)
#   clusterIssuer  → cert-manager.cluster-issuers
#   ingressNginx   → ingress-system.ingress-nginx
#   storage        → immich.storage (same namespace)
# Owned by: Luca (application)

{ config, lib, packages, ... }:
{
  config.instances.immich = {

    # PVC for the photo library — lives on ZFS bulk storage
    storage = {
      package = packages."persistent-volume-claim";
      config = {
        size = "2Ti";
        # TODO: storageClass = "zfs-bulk";
      };
    };

    # Postgres and Valkey resolve via DI from data namespace
    # (cluster-wide unique match on aliases "postgres" and "valkey")

    # Immich server
    immich = {
      package = packages.immich;
      config = {
        image.tag = "v2.0.0";
        replicaCount = 1;
        ingress = {
          enabled = true;
          host = "photos.${config.cluster.domain}";
        };
        metrics.enabled = true;
      };
    };

    # ML worker for smart search / facial recognition (CPU-only)
    machineLearning = {
      package = packages."immich-machine-learning";
      # CPU-only mode is the default; GPU node can be added later
    };
  };
}

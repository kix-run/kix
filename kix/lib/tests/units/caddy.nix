# Tests for kix/packages/stable/caddy: the default image is the official one, the
# deprecated `replicaCount` and `configSecretName` still work and warn, the
# Caddyfile comes from a `caddyfile` dependency, and a `storage` dependency
# backs /data. Caddy runs in namespace `edge`.

{
  lib,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  storageClassImport,
  ...
}:

let
  caddyPackage = import ../../../packages/stable/caddy;
  secretPackage = import ../../../packages/stable/secret;
  pvcPackage = import ../../../packages/stable/persistent-volume-claim;

  # `extra` adds instances to namespace `edge`.
  clusterWith =
    {
      config ? { },
      extra ? { },
    }:
    mkCluster [
      {
        # The cluster serves the HorizontalPodAutoscaler's metrics and the
        # LoadBalancer Service.
        cluster.roles = lib.genAttrs [ "metricsApi" "loadBalancer" ] (_: {
          binding = "exclusive";
          provider = "test";
        });
        instances.edge = {
          caddy = {
            package = caddyPackage;
            inherit config;
          };
        }
        // extra;
      }
    ];

  caddyfileSecret = {
    caddy-config = {
      package = secretPackage;
      aliases = [ "caddyfile" ];
      config.stringData.Caddyfile = ":8080 {\n  respond /healthz 200\n}\n";
    };
  };

  storage = {
    storage = {
      package = pvcPackage;
      config = {
        size = "1Gi";
        storageClassName = "standard";
      };
    };
    standard-class = storageClassImport "standard";
  };

  deploymentOf = cluster: byName "caddy" (ofKind "Deployment" (manifests cluster));
  podOf = cluster: (deploymentOf cluster).spec.template.spec;
  containerOf = cluster: builtins.head (podOf cluster).containers;
  volumeOf =
    cluster: name: builtins.head (builtins.filter (v: v.name == name) (podOf cluster).volumes);
  mountsOf = cluster: map (m: m.mountPath) (containerOf cluster).volumeMounts;
  warningsOf = cluster: cluster.instances.edge.caddy._diagnostics.warnings;
  warns = cluster: text: builtins.any (lib.hasInfix text) (warningsOf cluster);
in
{
  caddy-default-image =
    let
      image =
        (containerOf (clusterWith {
          extra = caddyfileSecret;
        })).image;
    in
    lib.hasPrefix "docker.io/library/caddy:2.10.0@sha256:" image || throw "caddy image: ${image}";

  # The old name sets the Deployment's replicas and warns with the new name.
  caddy-replica-count-deprecated =
    let
      old = clusterWith {
        config.replicaCount = 3;
        extra = caddyfileSecret;
      };
      new = clusterWith {
        config.replicas = 4;
        extra = caddyfileSecret;
      };
    in
    (
      (deploymentOf old).spec.replicas == 3
      && warns old "Set config.replicas instead"
      && (deploymentOf new).spec.replicas == 4
      && !(warns new "replicaCount")
      && evalFails (clusterWith {
        config.replicas = 0;
        extra = caddyfileSecret;
      })
    )
    || throw "caddy replicaCount: ${builtins.toJSON (warningsOf old)}";

  # The old route mounts both keys by subPath from the named Secret.
  caddy-config-secret-name-deprecated =
    let
      named = clusterWith { config.configSecretName = "my-caddy"; };
      unnamed = clusterWith { };
    in
    (
      (volumeOf named "caddy-config").secret.secretName == "my-caddy"
      && builtins.elem "/etc/caddy/crs-setup.conf" (mountsOf named)
      && warns named "configSecretName is deprecated"
      && (volumeOf unnamed "caddy-config").secret.secretName == "caddy-config"
      && warns unnamed "a default that 0.10 removes"
      && evalFails (clusterWith {
        config.configSecretName = "my-caddy";
        extra = caddyfileSecret;
      })
    )
    || throw "caddy configSecretName: ${builtins.toJSON (warningsOf named)}";

  # The dependency's Secret is mounted as /etc/caddy, a change rolls the
  # pods, and nothing warns.
  caddy-caddyfile-dependency =
    let
      cluster = clusterWith { extra = caddyfileSecret; };
      secretName = (volumeOf cluster "caddy-config").secret.secretName;
      noKey = clusterWith {
        extra.caddy-config = caddyfileSecret.caddy-config // {
          config.stringData.other = "x";
        };
      };
    in
    (
      builtins.elem "/etc/caddy" (mountsOf cluster)
      && !(builtins.elem "/etc/caddy/Caddyfile" (mountsOf cluster))
      && byName secretName (ofKind "Secret" (manifests cluster)) != null
      && (deploymentOf cluster).spec.template.metadata.annotations ? "checksum/caddyfile"
      && warningsOf cluster == [ ]
      && evalFails noKey
    )
    || throw "caddy caddyfile: ${
      builtins.toJSON {
        mounts = mountsOf cluster;
        warnings = warningsOf cluster;
      }
    }";

  # /data is an emptyDir by default and the claim with `storage`.
  caddy-storage-dependency =
    let
      withStorage = clusterWith { extra = caddyfileSecret // storage; };
      without = clusterWith { extra = caddyfileSecret; };
    in
    (
      (volumeOf withStorage "data").persistentVolumeClaim.claimName == "storage"
      && builtins.elem "/data" (mountsOf withStorage)
      && (volumeOf without "data") ? emptyDir
    )
    || throw "caddy storage: ${builtins.toJSON (volumeOf withStorage "data")}";
}

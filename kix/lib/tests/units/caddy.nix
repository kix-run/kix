# Tests for kix/packages/experimental/caddy: the default image is the
# official one, the removed `replicaCount` and `configSecretName` fail the
# build, the Caddyfile comes from the required `caddyfile` dependency, and a
# `storage` dependency backs /data. Caddy runs in namespace `edge`.

{
  lib,
  eval,
  kixlib,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  storageClassImport,
  ...
}:

let
  caddyPackage = import ../../../packages/experimental/caddy;
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
  warningsOf = cluster: map (w: w.message) cluster.instances.edge.caddy._diagnostics.warnings;

  # The package's failed assertion messages for `config`. A failed
  # assertion stops the cluster, and tryEval drops its message, so the
  # assertions are evaluated against the package directly.
  failedOf =
    config:
    let
      attrs = caddyPackage {
        scope = {
          instanceName = "caddy";
          namespaceName = "edge";
        };
        inherit lib;
        kix = kixlib;
        availability = "none";
      };
      evaluated = eval.evaluateInstanceConfig {
        packageOptions = attrs.options;
        instCfg.config.imports = [ config ];
        namespaceName = "edge";
        instanceName = "caddy";
      };
    in
    map (a: "[${a.id}] ${a.message} ${a.fix}") (
      builtins.filter (a: !a.assertion) (
        attrs.assertions {
          config = evaluated;
          deps = { };
        }
      )
    );
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

  # `replicas` sets the Deployment's replicas. The removed `replicaCount`
  # fails the build with a message that names `replicas`.
  caddy-replica-count-refused =
    let
      old = failedOf { replicaCount = 3; };
    in
    (
      (deploymentOf (clusterWith {
        config.replicas = 4;
        extra = caddyfileSecret;
      })).spec.replicas == 4
      && failedOf { replicas = 4; } == [ ]
      && old == [ "[K6965] replicaCount was removed. Set config.replicas instead." ]
      && evalFails (clusterWith {
        config.replicaCount = 3;
        extra = caddyfileSecret;
      })
      && evalFails (clusterWith {
        config.replicas = 0;
        extra = caddyfileSecret;
      })
    )
    || throw "caddy replicaCount: ${builtins.toJSON old}";

  # The removed `configSecretName` fails the build with a message that names
  # the `caddyfile` dependency, and a cluster without that dependency fails.
  caddy-config-secret-name-refused =
    let
      named = failedOf { configSecretName = "my-caddy"; };
    in
    (
      builtins.length named == 1
      && lib.hasPrefix "[K2263] " (builtins.head named)
      && lib.hasInfix "caddyfile dependency" (builtins.head named)
      && evalFails (clusterWith {
        config.configSecretName = "my-caddy";
        extra = caddyfileSecret;
      })
      && evalFails (clusterWith { })
    )
    || throw "caddy configSecretName: ${builtins.toJSON named}";

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

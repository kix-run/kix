# Tests for availability ceilings: the replica guard under a `none` ceiling
# (plugins/availability), ceiling validation (core/availability.nix
# checkCeiling, scope/builders.nix workloadCeilingOf) and the effective
# ceiling a sealed workload records.

{
  lib,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  containerBase,
  mkReplicatedPackage,
  singleNode,
  multiZone,
  ...
}:

let
  # A Deployment named `app` built from `spec`. `availability` is passed to
  # the builder only when set.
  appDeployment =
    scope:
    {
      replicas,
      availability ? null,
      kind ? "Deployment",
    }:
    let
      builder =
        {
          Deployment = scope.mkDeployment;
          StatefulSet = scope.mkStatefulSet;
          DaemonSet = scope.mkDaemonSet;
        }
        .${kind};
    in
    builder (
      {
        name = "app";
        spec = {
          selector.matchLabels = scope.selectorLabels;
          template = {
            metadata.labels = scope.selectorLabels;
            spec.containers = [
              (
                {
                  name = "app";
                  image = "example/app:1";
                }
                // containerBase
              )
            ];
          };
        }
        // lib.optionalAttrs (kind != "DaemonSet") { inherit replicas; };
      }
      // lib.optionalAttrs (availability != null) { inherit availability; }
    );

  # One workload, `self.app`, with an optional package ceiling.
  appPackage =
    {
      replicas ? 1,
      availability ? null,
      kind ? "Deployment",
      packageMax ? null,
    }:
    {
      meta = {
        version = "test";
      }
      // lib.optionalAttrs (packageMax != null) { availability.max = packageMax; };
      build =
        { self, scope, ... }:
        {
          root = self.app;
          app = appDeployment scope { inherit replicas availability kind; };
        };
    };

  clusterWith =
    mods: instance:
    mkCluster (
      mods
      ++ [
        { instances.appns.app = instance; }
      ]
    );

  builds = mods: instance: !(evalFails (clusterWith mods instance));

  replicasOf =
    mods: instance:
    (byName "app" (ofKind "Deployment" (manifests (clusterWith mods instance)))).spec.replicas;

  noneCeiling = {
    max = "none";
  };
in
{
  # A builder ceiling of `none` refuses two replicas whether or not it caps
  # the level; one replica, and a `pod` ceiling with two, still build.
  lib-availability-ceiling-builder-none-refuses-two =
    let
      twoUnderNone.package = appPackage {
        replicas = 2;
        availability = noneCeiling;
      };
    in
    (evalFails (clusterWith [ multiZone ] twoUnderNone))
    && (evalFails (clusterWith [ singleNode ] twoUnderNone))
    && builds [ multiZone ] {
      package = appPackage {
        replicas = 1;
        availability = noneCeiling;
      };
    }
    && builds [ multiZone ] {
      package = appPackage {
        replicas = 2;
        availability.max = "pod";
      };
    }
    || throw "a builder ceiling of none did not refuse two replicas, or refused a valid workload";

  # The package ceiling `none` refuses two replicas; one and zero build.
  lib-availability-ceiling-package-none-refuses-two =
    (evalFails (
      clusterWith [ multiZone ] {
        package = appPackage {
          replicas = 2;
          packageMax = "none";
        };
      }
    ))
    && builds [ multiZone ] {
      package = appPackage {
        replicas = 1;
        packageMax = "none";
      };
    }
    &&
      replicasOf [ multiZone ] {
        package = appPackage {
          replicas = 0;
          packageMax = "none";
        };
      } == 0
    || throw "the package ceiling none did not refuse two replicas, or refused one or zero";

  # A builder ceiling that does not cap the level (the instance runs at
  # `none`) is still recorded and still refuses two replicas.
  lib-availability-ceiling-builder-none-uncapped =
    let
      pkg = appPackage {
        replicas = 2;
        availability = noneCeiling;
      };
    in
    (evalFails (clusterWith [ singleNode ] { package = pkg; }))
    && (evalFails (
      clusterWith [ multiZone ] {
        package = pkg;
        availability = "none";
      }
    ))
    || throw "a builder ceiling of none that does not cap was not enforced";

  # An unknown level fails at the package or the builder, as do an unknown
  # key and `availability` on a DaemonSet, which runs one pod per node.
  lib-availability-ceiling-invalid-ceilings =
    (evalFails (clusterWith [ multiZone ] { package = appPackage { packageMax = "nod"; }; }))
    && (evalFails (clusterWith [ multiZone ] { package = appPackage { availability.max = "nod"; }; }))
    && (evalFails (
      clusterWith [ multiZone ] { package = appPackage { availability.maximum = "pod"; }; }
    ))
    && (evalFails (
      clusterWith [ multiZone ] {
        package = appPackage {
          kind = "DaemonSet";
          availability.max = "pod";
        };
      }
    ))
    && builds [ multiZone ] { package = appPackage { kind = "DaemonSet"; }; }
    || throw "an invalid ceiling or availability on a DaemonSet was accepted";

  # A chart workload carries the package ceiling, so chart values above
  # one replica under `none` fail.
  lib-availability-ceiling-chart-under-package-none =
    (evalFails (mkCluster [
      multiZone
      {
        instances.appns.web.package = mkReplicatedPackage {
          helm = true;
          replicas = 2;
          metaExtra.availability.max = "none";
        };
      }
    ]))
    && !(evalFails (mkCluster [
      multiZone
      {
        instances.appns.web.package = mkReplicatedPackage {
          helm = true;
          replicas = 1;
          metaExtra.availability.max = "none";
        };
      }
    ]))
    || throw "a chart workload above one replica under the package ceiling none was accepted";

  # A partsOverlays entry that keeps the builder ceiling and raises the
  # replicas fails. One that rebuilds the workload without availability.max
  # drops the builder ceiling and builds.
  lib-availability-ceiling-overlay-raises-replicas =
    let
      pkg = appPackage {
        replicas = 1;
        availability = noneCeiling;
      };
      withOverlay = availability: {
        package = pkg;
        partsOverlays = [
          (scope: _self: _base: {
            app = appDeployment scope {
              replicas = 3;
              inherit availability;
            };
          })
        ];
      };
    in
    (evalFails (clusterWith [ multiZone ] (withOverlay noneCeiling)))
    && replicasOf [ multiZone ] (withOverlay null) == 3
    || throw "an overlay that kept the none ceiling raised the replicas, or the escape did not build";

  # A ceiling computed from config on the builder call, in the shape of a
  # workload that cannot share a local cache. Off, the replicas follow
  # `pick` (3 at zone); on, the workload runs one pod and records the
  # builder ceiling. A builder ceiling that does not cap is recorded too.
  lib-availability-ceiling-ceiling-from-config =
    let
      pkg =
        { kix, availability, ... }:
        {
          meta.version = "test";
          options.localCache = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
          build =
            {
              self,
              scope,
              config,
              ...
            }:
            {
              root = self.app;
              app = appDeployment scope (
                if config.localCache then
                  {
                    replicas = 1;
                    availability = noneCeiling;
                  }
                else
                  {
                    replicas = kix.availability.pick availability {
                      none = 1;
                      pod = 2;
                      node = 2;
                      zone = 3;
                    };
                  }
              );
            };
        };
      sealed = mods: instance: (clusterWith mods instance).instances.appns.app.raw.app._availability;
      on = sealed [ multiZone ] {
        package = pkg;
        config.localCache = true;
      };
      uncapped = sealed [ singleNode ] {
        package = appPackage {
          replicas = 1;
          availability.max = "pod";
        };
      };
    in
    (
      replicasOf [ multiZone ] { package = pkg; } == 3
      &&
        replicasOf [ multiZone ] {
          package = pkg;
          config.localCache = true;
        } == 1
      && on.level == "none"
      && on.ceiling == "none"
      && on.ceilingFrom == "builder"
      && uncapped.level == "none"
      && uncapped.ceiling == "pod"
      && uncapped.ceilingFrom == "builder"
    )
    || throw "ceiling from config: ${
      builtins.toJSON {
        on = removeAttrs on [ "warnings" ];
        uncapped = removeAttrs uncapped [ "warnings" ];
      }
    }";
}

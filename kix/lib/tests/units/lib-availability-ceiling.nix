# Tests for availability ceilings: the replica guard under a `none` ceiling
# (plugins/availability), ceiling validation (core/availability.nix
# checkCeiling and ceilingOfMeta, scope/builders.nix workloadCeilingOf), the
# effective ceiling a sealed workload records, and the dead-mapping guard on
# `kix.availability.pick` and `atLeast` under a package ceiling
# (core/availability.nix underCeiling).

{
  lib,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  containerBase,
  mkReplicatedPackage,
  mkLevelPackage,
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

  availabilityLib = import ../../core/availability.nix { inherit lib; };

  fails = v: !(builtins.tryEval (builtins.deepSeq v true)).success;

  levelPackageAt =
    mods: args:
    mkCluster (
      mods
      ++ [
        { instances.appns.web.package = mkLevelPackage args; }
      ]
    );

  constantTable = {
    none = 1;
    pod = 1;
    node = 1;
    zone = 1;
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

  # Under meta.availability.max = "none" the package only sees "none", so a
  # `pick` table that differs above it fails, at every level. A constant
  # table builds. A package without a package ceiling may keep the table
  # beside a workload with a builder ceiling of `none`. An incomplete table,
  # or a value that is not an attrset, fails with the completeness `throw`.
  # An entry above the ceiling that throws is not compared.
  lib-availability-ceiling-package-none-dead-pick =
    let
      twoWorkloads =
        { kix, availability, ... }:
        {
          meta.version = "test";
          build =
            { self, scope, ... }:
            {
              root = self.app;
              app = appDeployment scope {
                replicas = kix.availability.pick availability {
                  none = 1;
                  pod = 2;
                  node = 2;
                  zone = 3;
                };
              };
              single = scope.mkDeployment {
                name = "single";
                availability = noneCeiling;
                spec = {
                  replicas = 1;
                  selector.matchLabels = scope.selectorLabels // {
                    part = "single";
                  };
                  template = {
                    metadata.labels = scope.selectorLabels // {
                      part = "single";
                    };
                    spec.containers = [
                      (
                        {
                          name = "single";
                          image = "example/single:1";
                        }
                        // containerBase
                      )
                    ];
                  };
                };
              };
            };
        };
      underNone = availabilityLib.underCeiling {
        ceiling = "none";
        where = "appns/web";
      };
      unbounded = availabilityLib.underCeiling {
        ceiling = null;
        where = "appns/web";
      };
      table = {
        none = 1;
        pod = 2;
        node = 2;
        zone = 3;
      };
    in
    (evalFails (levelPackageAt [ multiZone ] { metaExtra.availability.max = "none"; }))
    && (evalFails (levelPackageAt [ singleNode ] { metaExtra.availability.max = "none"; }))
    && !(evalFails (
      levelPackageAt [ multiZone ] {
        metaExtra.availability.max = "none";
        table = constantTable;
      }
    ))
    && replicasOf [ multiZone ] { package = twoWorkloads; } == 3
    && fails (underNone.pick "none" table)
    && underNone.pick "none" constantTable == 1
    && fails (
      underNone.pick "none" {
        none = 1;
        pod = 2;
      }
    )
    && fails (
      underNone.pick "none" {
        pod = 1;
        node = 1;
        zone = 1;
      }
    )
    && fails (underNone.pick "none" 3)
    && underNone.pick "none" (constantTable // { pod = throw "unused"; }) == 1
    # A function value is not compared, so a table of builders passes.
    && (underNone.pick "none" (lib.genAttrs availabilityLib.levels (l: _: l))) null == "none"
    && unbounded.pick "zone" table == 3
    || throw "a dead pick table under the package ceiling none was accepted, or a valid table was refused";

  # Under meta.availability.max = "pod", `atLeast "node"` is always false
  # and fails; `atLeast "pod"` still answers. The build function takes
  # `kix` as an argument, which is the path the dead-pick test does not
  # cover.
  lib-availability-ceiling-atleast-above-ceiling =
    let
      pkg = min: {
        meta = {
          version = "test";
          availability.max = "pod";
        };
        build =
          {
            self,
            scope,
            kix,
            availability,
            ...
          }:
          {
            root = self.app;
            app = appDeployment scope { replicas = 2; };
            seen = scope.mkResource {
              apiVersion = "v1";
              kind = "ConfigMap";
              name = "at-least";
              data.result = lib.boolToString (kix.availability.atLeast min availability);
            };
          };
      };
      resultAt =
        min:
        (byName "at-least" (
          ofKind "ConfigMap" (manifests (clusterWith [ multiZone ] { package = pkg min; }))
        )).data.result;
    in
    (evalFails (clusterWith [ multiZone ] { package = pkg "node"; })) && resultAt "pod" == "true"
    || throw "atLeast above the package ceiling was accepted, or atLeast at the ceiling failed";

  # meta.availability takes only `max`; anything else fails rather than
  # being ignored.
  lib-availability-ceiling-meta-availability-unknown-key =
    (evalFails (
      clusterWith [ multiZone ] {
        package = appPackage { } // {
          meta = {
            version = "test";
            availability.maximum = "none";
          };
        };
      }
    ))
    && (evalFails (
      clusterWith [ multiZone ] {
        package = appPackage { } // {
          meta = {
            version = "test";
            availability = "none";
          };
        };
      }
    ))
    && builds [ multiZone ] { package = appPackage { packageMax = "pod"; }; }
    || throw "an unknown meta.availability key was accepted";
}

# Tests for the volsync package: the VolumeSnapshot API it needs, one
# instance per cluster, the image's release check, the refusals of
# out.mkReplicationSource, and the network policy its movers get to an
# in-cluster store and to one outside the cluster.

{
  lib,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  netpolOn,
  containerBase,
  storageClassImport,
  ...
}:

let
  volsyncPackage = import ../../../packages/volsync;
  snapshotControllerPackage = import ../../../packages/snapshot-controller;
  secretPackage = import ../../../packages/secret;
  pvcPackage = import ../../../packages/persistent-volume-claim;

  resticKeys = {
    RESTIC_REPOSITORY = "s3:https://s3.example.com/backups/app";
    RESTIC_PASSWORD = "password";
    AWS_ACCESS_KEY_ID = "key";
    AWS_SECRET_ACCESS_KEY = "secret";
  };

  # A Deployment and its Service standing in for an in-cluster S3 store.
  storePackage =
    { scope, kix, ... }:
    {
      meta.description = "S3 store stand-in";
      build =
        { self, ... }:
        {
          deployment = scope.mkDeployment {
            name = "s3";
            spec = {
              replicas = 1;
              selector.matchLabels = scope.selectorLabels;
              template.spec.containers = [
                (
                  containerBase
                  // {
                    name = "s3";
                    image = "registry.example/s3:1.0@sha256:0000000000000000000000000000000000000000000000000000000000000000";
                    ports = [ (kix.port "s3" 7070) ];
                  }
                )
              ];
            };
          };
          service = self.deployment |> kix.service.fromWorkload { name = "s3"; } |> scope.mkResource;
          root = self.service;
        };
    };

  # A package that backs up its claim, with `source` merged over the
  # builder's arguments and `restic` over their restic attrset.
  consumerPackage =
    { source, restic }:
    { scope, ... }:
    {
      meta.description = "VolSync consumer";
      build =
        {
          self,
          volsync,
          storage,
          resticRepository,
          endpointService ? null,
          ...
        }:
        {
          backup = volsync.out.mkReplicationSource scope (
            {
              name = "data";
              claim = storage;
              schedule = "0 3 * * *";
              copyMethod = "Snapshot";
              restic = {
                repository = resticRepository;
                inherit endpointService;
              }
              // restic;
            }
            // source
          );
          root = self.backup.replicationSource;
        };
    };

  cluster =
    {
      source ? { },
      restic ? { },
      store ? true,
      repositoryKeys ? resticKeys,
      volsyncConfig ? { },
      snapshots ? true,
      extraInstances ? { },
      module ? { },
    }:
    mkCluster [
      module
      (
        { ref, ... }:
        {
          instances = {
            classes.standard = storageClassImport "standard";
            volsync.volsync = {
              package = volsyncPackage;
              config = volsyncConfig;
            };
            app = {
              storage = {
                package = pvcPackage;
                config = {
                  size = "1Gi";
                  storageClassName = "standard";
                };
              };
              restic-repository = {
                package = secretPackage;
                aliases = [ "resticRepository" ];
                config.stringData = repositoryKeys;
              };
              consumer = {
                package = consumerPackage { inherit source restic; };
              }
              // lib.optionalAttrs store { deps.endpointService = ref.s3.s3; };
            };
          }
          // lib.optionalAttrs store { s3.s3.package = storePackage; }
          // lib.optionalAttrs snapshots {
            storage.snapshot-controller.package = snapshotControllerPackage;
          }
          // extraInstances;
        }
      )
    ];

  builds = c: !(evalFails c);

  check =
    label: cases:
    let
      wrong = lib.attrNames (lib.filterAttrs (_: c: builds c.cluster != c.builds) cases);
    in
    wrong == [ ] || throw "${label}: these cases did not behave: ${toString wrong}";
in
{
  # The operator does not start without the VolumeSnapshot CRD, so the
  # package needs the snapshotController role.
  volsync-needs-snapshot-api = check "volsync without a snapshot controller" {
    without-controller = {
      cluster = cluster { snapshots = false; };
      builds = false;
    };
    with-controller = {
      cluster = cluster { };
      builds = true;
    };
  };

  volsync-second-instance = check "two volsync instances" {
    one = {
      cluster = cluster { };
      builds = true;
    };
    two = {
      cluster = cluster { extraInstances.other.volsync.package = volsyncPackage; };
      builds = false;
    };
  };

  # The vendored CRDs and ClusterRole follow the release.
  volsync-image-minor = check "volsync image.tag" {
    other-minor = {
      cluster = cluster { volsyncConfig.image.tag = "0.15.0"; };
      builds = false;
    };
    same-minor = {
      cluster = cluster {
        volsyncConfig.image = {
          tag = "0.16.1";
          digest = null;
        };
      };
      builds = true;
    };
  };

  # Each refusal of mkReplicationSource beside the valid arguments.
  volsync-replication-source-refusals = check "mkReplicationSource" {
    valid = {
      cluster = cluster { };
      builds = true;
    };
    descriptor = {
      cluster = cluster { source.schedule = "@daily"; };
      builds = true;
    };
    six-field-schedule = {
      cluster = cluster { source.schedule = "0 0 3 * * *"; };
      builds = false;
    };
    copy-method = {
      cluster = cluster { source.copyMethod = "None"; };
      builds = false;
    };
    long-name = {
      cluster = cluster { source.name = lib.concatStrings (lib.replicate 52 "a"); };
      builds = false;
    };
    missing-key = {
      cluster = cluster { repositoryKeys = removeAttrs resticKeys [ "RESTIC_PASSWORD" ]; };
      builds = false;
    };
    store-and-port = {
      cluster = cluster { restic.storePort = 443; };
      builds = false;
    };
    unknown-restic-key = {
      cluster = cluster { restic.cacheCapacity = "1Gi"; };
      builds = false;
    };
    other-mover = {
      cluster = cluster { source.extraSpec.rclone.rcloneConfig = "rclone"; };
      builds = false;
    };
    locked-path = {
      cluster = cluster { source.extraSpec.sourcePVC = "other"; };
      builds = false;
    };
    restic-extra = {
      cluster = cluster { source.extraSpec.restic.pruneIntervalDays = 14; };
      builds = true;
    };
  };

  # A store outside the cluster takes a port number.
  volsync-store-port = check "mkReplicationSource storePort" {
    port = {
      cluster = cluster {
        store = false;
        restic.storePort = 9000;
      };
      builds = true;
    };
    not-a-port = {
      cluster = cluster {
        store = false;
        restic.storePort = 70000;
      };
      builds = false;
    };
  };

  # An in-cluster store: the movers get egress to it and it gets ingress
  # from them, derived from the resource. A store outside the cluster: the
  # builder adds a policy for the movers, with DNS. The test enforcer
  # translates intents to no rules, so the world rule's port is not
  # checked here.
  volsync-mover-policies =
    let
      inCluster = manifests (cluster {
        module = netpolOn;
      });
      outside = manifests (cluster {
        module = netpolOn;
        store = false;
        restic.storePort = 9000;
      });
      policies = ms: ofKind "CiliumNetworkPolicy" ms;
      moverSelector = {
        "app.kubernetes.io/created-by" = "volsync";
        "batch.kubernetes.io/job-name" = "volsync-src-data";
      };
      selects = p: (p.spec.endpointSelector.matchLabels or { }) == moverSelector;
      storeIngress = builtins.filter (
        p:
        p.metadata.namespace == "s3"
        && builtins.any (r: (r.callerSelector or null) == moverSelector && r.callerNamespace == "app") (
          p.spec.ingress or [ ]
        )
      ) (policies inCluster);
      worldEgress = byName "data-restic-egress" (policies outside);
    in
    (
      builtins.any selects (policies inCluster)
      || throw "no policy selects the mover pods for an in-cluster store"
    )
    && (storeIngress != [ ] || throw "the store has no ingress from the mover pods")
    && (
      worldEgress != null
      && selects worldEgress
      && builtins.elem "dns-egress" (map (r: r.stubRule or null) worldEgress.spec.egress)
      || throw "the mover pods have no egress policy to a store outside the cluster: ${builtins.toJSON worldEgress}"
    );
}

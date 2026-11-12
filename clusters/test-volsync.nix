# clusters/test-volsync.nix: VolSync backs up a workload's claim to an
# in-cluster S3 store with restic, on kind under Cilium default-deny.
#
# The store (./s3-test-store.nix) runs in its own namespace. The smoke
# workload writes a file to its claim and builds a ReplicationSource with
# `volsync.out.mkReplicationSource`, naming the store as its
# endpointService, so the mover pods' egress and the store's ingress come
# from the graph. VolSync runs the first backup when the resource is
# created, and the deploy waits until it reports Successful. kind's
# local-path class cannot clone or snapshot, so the mover reads the claim
# directly (copyMethod Direct). A snapshot-controller instance provides the
# VolumeSnapshot API the operator needs to start.
#
# Build:  nix build .#cluster-volsync --extra-experimental-features pipe-operators

{ kix, packages }:

let
  # Test values only. The store reads the root user's keys; the restic
  # mover reads the same keys from the repository Secret.
  accessKeyId = "volsync-test";
  secretAccessKey = "volsync-test-secret";

  smokePackage =
    { scope, kix, ... }:
    {
      meta = {
        description = "Workload whose claim the volsync test cluster backs up";
        owner = "platform";
      };
      build =
        {
          self,
          volsync,
          storage,
          resticRepository,
          endpointService,
          ...
        }:
        {
          deployment =
            {
              name = "smoke";
              availability.max = "none";
              spec = {
                replicas = 1;
                selector.matchLabels = scope.selectorLabels;
                # The claim is ReadWriteOnce.
                strategy.type = "Recreate";
                template.spec = {
                  securityContext = {
                    runAsNonRoot = true;
                    runAsUser = 1000;
                    fsGroup = 1000;
                  };
                  # Kubernetes' default; sleep holds no state.
                  terminationGracePeriodSeconds = 30;
                  containers = [
                    {
                      name = "smoke";
                      image = "docker.io/library/busybox:1.37.0@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e";
                      command = [
                        "sh"
                        "-c"
                        "test -f /data/file || head -c 65536 /dev/urandom > /data/file; exec sleep 2147483647"
                      ];
                      resources = {
                        requests = {
                          cpu = "10m";
                          memory = "16Mi";
                        };
                        limits = {
                          cpu = "100m";
                          memory = "32Mi";
                        };
                      };
                      securityContext = {
                        allowPrivilegeEscalation = false;
                        readOnlyRootFilesystem = true;
                        capabilities.drop = [ "ALL" ];
                      };
                      livenessProbe.exec.command = [
                        "test"
                        "-f"
                        "/data/file"
                      ];
                      readinessProbe.exec.command = [
                        "test"
                        "-f"
                        "/data/file"
                      ];
                    }
                  ];
                };
              };
            }
            |> kix.withMounts [ (kix.mount.pvc storage { mountPath = "/data"; }) ]
            |> scope.mkDeployment;
          backup = volsync.out.mkReplicationSource scope {
            name = "smoke";
            claim = storage;
            schedule = "0 3 * * *";
            copyMethod = "Direct";
            restic = {
              repository = resticRepository;
              inherit endpointService;
            };
            extraSpec.restic.retain.daily = 7;
            # Back up once the file exists.
            requires = [ self.deployment ];
          };
          root = {
            resource = self.deployment;
            requires = [ self.backup.replicationSource ];
          };
        };
    };
in
kix.buildCluster {
  name = "volsync";
  modules = [
    kix.flavors.kind
    (
      { ref, config, ... }:
      {
        # kind runs with the default CNI disabled; the managed cilium
        # instance fills the vacant role.
        cluster.roles.cni = {
          binding = "absent";
          provider = null;
        };
        networkPolicy.enable = true;

        namespaces = {
          volsync = { };
          storage = { };
          s3 = { };
          volsync-smoke = { };
          monitoring = { };
        };

        instances = {
          kube-system.cilium = {
            package = packages.experimental.cilium;
            config.values = {
              kubeProxyReplacement = false;
              prometheus.enabled = false;
              ipam.operator.clusterPoolIPv4PodCIDRList = [ "10.244.0.0/16" ];
            };
          };

          monitoring.prometheus-operator.package = packages.experimental.prometheus-operator;

          storage.snapshot-controller.package = packages.experimental.snapshot-controller;

          volsync.volsync = {
            package = packages.experimental.volsync;
            config.metrics.enabled = true;
          };

          s3 = {
            s3-root-credentials = {
              package = packages.secret;
              aliases = [ "s3RootCredentials" ];
              config.stringData = { inherit accessKeyId secretAccessKey; };
            };
            s3.package = import ./s3-test-store.nix {
              buckets = [ "volsync" ];
              description = "S3 test store for the VolSync backups";
            };
          };

          volsync-smoke = {
            storage = {
              package = packages.persistent-volume-claim;
              config.size = "64Mi";
            };
            restic-repository = {
              package = packages.secret;
              aliases = [ "resticRepository" ];
              config.stringData = {
                RESTIC_REPOSITORY = "s3:http://s3.s3.svc.${config.clusterDomain}:7070/volsync/smoke";
                RESTIC_PASSWORD = "volsync-test-repository-key";
                AWS_ACCESS_KEY_ID = accessKeyId;
                AWS_SECRET_ACCESS_KEY = secretAccessKey;
              };
            };
            smoke = {
              package = smokePackage;
              deps.endpointService = ref.s3.s3;
            };
          };
        };
      }
    )
  ];
}

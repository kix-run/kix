# clusters/test-velero.nix: Velero end to end on kind, under Cilium
# default-deny.
#
# An in-cluster S3 store (versitygw on emptyDirs) is the `objectStorage`
# dependency, so the backup location's `s3Url` and its network policy come
# from the graph. A smoke workload in its own namespace builds a Backup and
# a Schedule through `velero.out.mkBackup` and `velero.out.mkSchedule`; a
# volume policy sends its emptyDir to file-system backup, so the backup
# runs in the pods node-agent launches and the repository maintenance Job
# the server launches, which the `velero-data-path` policy lets out.
#
# Build:  nix build .#cluster-velero --extra-experimental-features pipe-operators
# Deploy: scripts/kind-velero.sh

{ kix, packages }:

let
  # Test keys for the in-cluster store. The store and Velero read the same
  # Secret: the store as its root user, Velero through the `cloud` file.
  accessKeyId = "velero-test";
  secretAccessKey = "velero-test-secret";

  # versitygw, an S3 gateway over a directory. Each directory under /data
  # is a bucket; --sidecar keeps object metadata in files under /meta
  # instead of extended attributes, which some kind hosts refuse.
  s3Package =
    { scope, kix, ... }:
    {
      meta = {
        version = "v1.8.0";
        description = "S3 test store for the velero kind run";
        owner = "platform";
        defaultAliases = [ "objectStorage" ];
      };
      build =
        { self, s3RootCredentials, ... }:
        let
          image = "docker.io/versity/versitygw:v1.8.0@sha256:30292fc2eeacc67a36993b01f7a7a5e3361a19cced0e80c1d71cfa2a4b0a2499";
          resources = {
            requests = {
              cpu = "50m";
              memory = "64Mi";
            };
            limits = {
              cpu = "500m";
              memory = "256Mi";
            };
          };
          mounts = [
            {
              name = "data";
              mountPath = "/data";
            }
            {
              name = "meta";
              mountPath = "/meta";
            }
          ];
        in
        {
          deployment = scope.mkDeployment {
            name = "s3";
            availability.max = "none";
            spec = {
              replicas = 1;
              selector.matchLabels = scope.selectorLabels;
              template.spec = {
                securityContext = {
                  runAsNonRoot = true;
                  runAsUser = 1000;
                };
                initContainers = [
                  {
                    name = "bucket";
                    inherit image resources;
                    command = [
                      "mkdir"
                      "-p"
                      "/data/velero"
                    ];
                    securityContext.readOnlyRootFilesystem = true;
                    volumeMounts = mounts;
                  }
                ];
                containers = [
                  {
                    name = "versitygw";
                    inherit image resources;
                    args = [
                      "--port"
                      ":7070"
                      "posix"
                      "--sidecar"
                      "/meta"
                      "/data"
                    ];
                    env = kix.mkEnvVars {
                      ROOT_ACCESS_KEY_ID = s3RootCredentials.out.keyRef "accessKeyId";
                      ROOT_SECRET_ACCESS_KEY = s3RootCredentials.out.keyRef "secretAccessKey";
                    };
                    ports = [ (kix.port "s3" 7070) ];
                    readinessProbe.tcpSocket.port = "s3";
                    livenessProbe.tcpSocket.port = "s3";
                    securityContext.readOnlyRootFilesystem = true;
                    volumeMounts = mounts;
                  }
                ];
                volumes =
                  map
                    (n: {
                      name = n;
                      emptyDir = { };
                    })
                    [
                      "data"
                      "meta"
                    ];
              };
            };
          };
          service = self.deployment |> kix.service.fromWorkload { name = "s3"; } |> scope.mkResource;
          root = self.service;
        };
    };

  # A ConfigMap and a pod whose emptyDir holds a file written at its first
  # start. The run deletes the namespace and restores it from `smoke`.
  smokePackage =
    { scope, ... }:
    {
      meta = {
        description = "Workload the velero kind run backs up and restores";
        owner = "platform";
      };
      build =
        { self, velero, ... }:
        {
          configMap = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "smoke";
            data.greeting = "restored by velero";
          };
          deployment = scope.mkDeployment {
            name = "smoke";
            availability.max = "none";
            spec = {
              replicas = 1;
              selector.matchLabels = scope.selectorLabels;
              template.spec = {
                securityContext = {
                  runAsNonRoot = true;
                  runAsUser = 1000;
                };
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
                    securityContext.readOnlyRootFilesystem = true;
                    volumeMounts = [
                      {
                        name = "data";
                        mountPath = "/data";
                      }
                    ];
                  }
                ];
                volumes = [
                  {
                    name = "data";
                    emptyDir = { };
                  }
                ];
              };
            };
          };
          backup = velero.out.mkBackup scope {
            name = "smoke";
            spec.includedNamespaces = [ scope.namespaceName ];
            requires = [
              self.configMap
              self.deployment
            ];
          };
          schedule = velero.out.mkSchedule scope {
            name = "smoke-daily";
            spec = {
              schedule = "@every 24h";
              skipImmediately = true;
              template.includedNamespaces = [ scope.namespaceName ];
            };
          };
          root = {
            resource = self.deployment;
            requires = [ self.configMap ];
          };
        };
    };
in
kix.buildCluster {
  name = "velero";
  modules = [
    kix.flavors.kind

    {
      # kind runs with the default CNI disabled (scripts/kind-velero.sh);
      # the managed cilium instance fills the vacant role.
      cluster.roles.cni = {
        binding = "absent";
        provider = null;
      };
      networkPolicy.enable = true;

      namespaces = {
        velero = { };
        velero-smoke = { };
      };

      instances = {
        kube-system.cilium = {
          package = packages.cilium;
          config.values = {
            kubeProxyReplacement = false;
            prometheus.enabled = false;
            ipam.operator.clusterPoolIPv4PodCIDRList = [ "10.244.0.0/16" ];
          };
        };

        velero = {
          s3-credentials = {
            package = packages.secret;
            aliases = [
              "cloudCredentials"
              "s3RootCredentials"
            ];
            config.stringData = {
              inherit accessKeyId secretAccessKey;
              cloud = "[default]\naws_access_key_id = ${accessKeyId}\naws_secret_access_key = ${secretAccessKey}\n";
            };
          };
          velero-repo-credentials = {
            package = packages.secret;
            aliases = [ "repositoryPassword" ];
            config.stringData.repository-password = "velero-test-repository-key";
          };
          s3.package = s3Package;
          velero = {
            package = packages.velero;
            config = {
              backupStorageLocation = {
                objectStorage.bucket = "velero";
                # The store ignores the region, and the AWS plugin needs one.
                config.region = "us-east-1";
              };
              schedules.daily = {
                schedule = "@every 24h";
                skipImmediately = true;
                template.includedNamespaces = [ "velero-smoke" ];
              };
              volumePolicies = [
                {
                  conditions.volumeTypes = [ "emptyDir" ];
                  action.type = "fs-backup";
                }
              ];
            };
          };
        };

        velero-smoke.smoke.package = smokePackage;
      };
    }
  ];
}

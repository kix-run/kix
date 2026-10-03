# clusters/s3-test-store.nix: an in-cluster S3 store for test clusters,
# versitygw on emptyDirs, used by test-velero.nix and test-cnpg.nix.
#
# Each directory under /data is a bucket; an init container creates one
# per entry of `buckets`. --sidecar keeps object metadata in files under
# /meta instead of extended attributes, which some kind hosts refuse. The
# root user comes from an `s3RootCredentials` dependency with keys
# `accessKeyId` and `secretAccessKey`. The instance's root is its S3
# Service, so a consumer reads `out.url`.
#
#   s3.package = import ./s3-test-store.nix {
#     buckets = [ "velero" ];
#     description = "S3 test store for the velero kind run";
#   };

{ buckets, description }:

{ scope, kix, ... }:
{
  meta = {
    version = "v1.8.0";
    inherit description;
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
                ]
                ++ map (b: "/data/${b}") buckets;
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
}

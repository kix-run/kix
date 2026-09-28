# Filebrowser — web-based file manager.
#
# Single-container app. Mounts a storage PVC at /srv.
#
# Dependencies:
#   storage        — required, persistent volume for files
#   ingressNginx   — optional, auto-creates ingress when present (+ host is set)
#   clusterIssuer  — optional, auto-enables TLS when present
#
# root = Service (port 80).

{
  scope,
  lib,
  kix,
}:

let
  name = scope.instanceName;
in
{
  meta = {
    version = "v2.63.18";
    description = "Filebrowser: web-based file manager";
    owner = "app-team";
  };

  options = {
    image = kix.options.image {
      repository = "filebrowser/filebrowser";
      tag = "v2.63.18";
      pullPolicy = null;
    };
    # Upstream publishes no chart or resource guidance. An idle instance
    # holds about 15 MiB; the limits leave room for archive downloads.
    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
        requests = {
          cpu = "10m";
          memory = "64Mi";
        };
        limits = {
          cpu = "500m";
          memory = "256Mi";
        };
      };
    };
    ingress = kix.options.ingress;
  };

  build = [
    (
      {
        self,
        config,
        clusterConfig,
        storage,
        scope,
        kix,
        ...
      }:
      {
        deployment =
          {
            name = name;
            spec = {
              replicas = 1;
              selector.matchLabels = scope.selectorLabels;
              # Kubernetes default: filebrowser documents no shutdown drain.
              template.spec.terminationGracePeriodSeconds = 30;
              template.spec.containers = [
                (
                  {
                    name = "filebrowser";
                    image = kix.image.ref config.image;
                    # The image's own user is uid 1000; stated so the kubelet
                    # can verify it rather than trust the image.
                    securityContext = {
                      runAsNonRoot = true;
                      runAsUser = 1000;
                      runAsGroup = 1000;
                      readOnlyRootFilesystem = true;
                    };
                    resources = config.resources;
                    ports = [
                      {
                        name = "http";
                        containerPort = 80;
                        protocol = "TCP";
                      }
                    ];
                    livenessProbe = {
                      httpGet = {
                        path = "/health";
                        port = "http";
                      };
                      periodSeconds = 30;
                    };
                    readinessProbe = {
                      httpGet = {
                        path = "/health";
                        port = "http";
                      };
                    };
                  }
                  // lib.optionalAttrs (config.image.pullPolicy != null) {
                    imagePullPolicy = config.image.pullPolicy;
                  }
                )
              ];
            };
          }
          |> kix.withMounts [
            (kix.mount.pvc storage { mountPath = "/srv"; })
            # The image's /init.sh copies settings.json into /config on
            # start, and those settings put the database in /database.
            (kix.mount.emptyDir {
              name = "config";
              mountPath = "/config";
            })
            (kix.mount.emptyDir {
              name = "database";
              mountPath = "/database";
            })
            (kix.mount.emptyDir {
              name = "tmp";
              mountPath = "/tmp";
            })
          ]
          |> scope.mkDeployment;

        service = self.deployment |> kix.service.fromWorkload { inherit name; } |> scope.mkResource;

        root = self.service;
      }
    )
    (kix.expose { service = "service"; })
  ];
}

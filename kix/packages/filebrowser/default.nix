# filebrowser: the File Browser web file manager, serving the files on one
# volume.
#
# Installs a Deployment and a Service on port 80, and a route through
# `kix.expose` when the cluster has an ingress controller or a gateway.
#
# Dependencies:
#   storage (required)   a claim, mounted at /srv, whose files it serves
#   an ingress controller or gateway, a cluster issuer (optional): read by
#                        `kix.expose` for the route and its TLS
#
# Minimal instance:
#
#   instances.files = {
#     storage = {
#       package = packages.persistent-volume-claim;
#       config.size = "10Gi";
#     };
#     filebrowser.package = packages.filebrowser;   # takes deps.storage
#   };
#
# `out`: the Service's `name`, `fqdn`, and `port` (80).
#
# Escape hatches: `ingress` for the route's host and annotations, and the
# instance's `partsOverlays`.
#
# Limits: File Browser keeps its user database in an emptyDir, so users
# and settings reset when the pod restarts. One replica, because the
# database is a single file.

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
    resources = kix.options.resources {
      requests = {
        cpu = "10m";
        memory = "64Mi";
      };
      limits = {
        cpu = "500m";
        memory = "256Mi";
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

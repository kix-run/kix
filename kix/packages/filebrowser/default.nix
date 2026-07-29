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
    description = "Filebrowser — web-based file manager";
  };

  options = {
    image = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "filebrowser/filebrowser";
        tag = "v2.63.18";
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
              template.spec.containers = [
                {
                  name = "filebrowser";
                  image = "${config.image.repository}:${config.image.tag}";
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
              ];
            };
          }
          |> kix.withMounts [
            (kix.mount.pvc storage { mountPath = "/srv"; })
          ]
          |> scope.mkDeployment;

        service = self.deployment |> kix.service.fromWorkload { inherit name; } |> scope.mkResource;

        root = self.service;
      }
    )
    (kix.expose { service = "service"; })
  ];
}

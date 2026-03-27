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
    version = "v2.32.0";
    description = "Filebrowser — web-based file manager";
  };

  options = {
    image = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "filebrowser/filebrowser";
        tag = "v2.32.0";
      };
    };
    ingress = lib.mkOption {
      type = lib.types.anything;
      default = {
        host = null;
        annotations = { };
      };
    };
  };

  build =
    {
      self,
      config,
      clusterConfig,
      storage,
      ingressNginx ? null,
      clusterIssuer ? null,
    }:
    let
      clusterDomain = clusterConfig.cluster.domain or null;
      ingressHost =
        if config.ingress.host != null then
          config.ingress.host
        else if clusterDomain != null then
          "${name}.${clusterDomain}"
        else
          null;
      hasIngress = ingressNginx != null && ingressHost != null;
      hasTls = hasIngress && clusterIssuer != null;
    in
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

      ingress =
        if hasIngress then
          self.service
          |> kix.ingress.fromService {
            inherit name;
            host = ingressHost;
            className = ingressNginx.out.ingressClassName;
            tls = lib.optional hasTls {
              hosts = [ ingressHost ];
              secretName = "${name}-tls";
            };
            annotations = config.ingress.annotations;
          }
          |> (if hasTls then clusterIssuer.out.withCert else lib.id)
          |> scope.mkResource
        else
          null;

      root = self.service;
    };
}

# Echo server package — simple nginx returning a test page.
#
# Useful for validating cluster connectivity in local environments (kind).
# Resources: ConfigMap, Deployment, Service.

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
    version = "1.27";
    description = "Nginx echo server for connectivity testing";
  };

  options = {
    image = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        repository = "nginx";
        tag = "1.27-alpine";
        pullPolicy = "IfNotPresent";
      };
      description = ''
        Container image used by the echo-server `Deployment`. Attrset with
        `repository`, `tag`, and `pullPolicy` keys, applied directly to the
        pod's container spec.
      '';
    };
    replicaCount = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = "Number of `Deployment` replicas for the echo-server pods.";
    };
    service = lib.mkOption {
      type = lib.types.anything;
      default = {
        type = "ClusterIP";
        port = 80;
      };
      description = ''
        `Service` exposure for the echo-server. Attrset with `type` (e.g.
        `ClusterIP`, `NodePort`) and `port` keys.
      '';
    };
    message = lib.mkOption {
      type = lib.types.str;
      default = "kix echo server is running";
      description = ''
        Plain-text response body returned by the echo-server at `/`. Useful
        for distinguishing instances during connectivity checks.
      '';
    };
  };

  build =
    {
      self,
      config,
      clusterConfig,
    }:
    {
      # --- ConfigMap (nginx config + response page) ---
      configmap = scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        inherit name;
        data = {
          "default.conf" = ''
            server {
                listen 80;
                location / {
                    default_type text/plain;
                    return 200 '${config.message}\n';
                }
                location /healthz {
                    default_type text/plain;
                    return 200 'ok\n';
                }
            }
          '';
        };
      };

      # --- Deployment ---
      deployment =
        {
          inherit name;
          spec = {
            replicas = config.replicaCount;
            selector.matchLabels = scope.selectorLabels;
            template.spec = {
              containers = [
                {
                  name = "nginx";
                  image = "${config.image.repository}:${config.image.tag}";
                  imagePullPolicy = config.image.pullPolicy;
                  ports = [
                    (kix.port "http" 80)
                  ];
                  livenessProbe = {
                    httpGet = {
                      path = "/healthz";
                      port = 80;
                    };
                    periodSeconds = 10;
                    failureThreshold = 3;
                  };
                  readinessProbe = {
                    httpGet = {
                      path = "/healthz";
                      port = 80;
                    };
                    periodSeconds = 5;
                    failureThreshold = 1;
                  };
                  volumeMounts = [
                    {
                      name = "config";
                      mountPath = "/etc/nginx/conf.d";
                      readOnly = true;
                    }
                  ];
                  resources = {
                    requests = {
                      cpu = "50m";
                      memory = "32Mi";
                    };
                    limits = {
                      cpu = "100m";
                      memory = "64Mi";
                    };
                  };
                }
              ];
              volumes = [
                {
                  name = "config";
                  configMap.name = self.configmap.out.name;
                }
              ];
            };
          };
        }
        |> scope.mkDeployment;

      # --- Service ---
      service =
        self.deployment
        |> kix.service.fromWorkload {
          inherit name;
          type = config.service.type;
          ports = [
            {
              name = "http";
              port = config.service.port;
              targetPort = "http";
              protocol = "TCP";
            }
          ];
        }
        |> scope.mkResource;

      # --- Entry point ---
      root = self.service;
    };
}

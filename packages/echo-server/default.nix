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
    };
    replicaCount = lib.mkOption {
      type = lib.types.int;
      default = 1;
    };
    service = lib.mkOption {
      type = lib.types.anything;
      default = {
        type = "ClusterIP";
        port = 80;
      };
    };
    message = lib.mkOption {
      type = lib.types.str;
      default = "kix echo server is running";
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

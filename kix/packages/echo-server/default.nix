# Echo server package — simple nginx returning a test page.
#
# Useful for validating cluster connectivity in local environments (kind).
# Resources: ConfigMap, Deployment, Service.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  name = scope.instanceName;
in
{
  meta = {
    version = "1.27";
    description = "Nginx echo server for connectivity testing";
    owner = "app-team";
  };

  options = {
    image = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        repository = "nginxinc/nginx-unprivileged";
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
      # Stateless and serving: two replicas as soon as a pod restart must
      # not be downtime, three once a whole zone may go.
      default = kix.availability.pick availability {
        none = 1;
        pod = 2;
        node = 2;
        zone = 3;
      };
      description = ''
        Number of `Deployment` replicas for the echo-server pods. Defaults
        from the cluster's availability level (v2_discussions/145).
      '';
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
                listen 8080;
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
                  # nginx-unprivileged runs as uid 101 and listens on 8080.
                  securityContext.runAsNonRoot = true;
                  ports = [
                    (kix.port "http" 8080)
                  ];
                  livenessProbe = {
                    httpGet = {
                      path = "/healthz";
                      port = 8080;
                    };
                    periodSeconds = 10;
                    failureThreshold = 3;
                  };
                  readinessProbe = {
                    httpGet = {
                      path = "/healthz";
                      port = 8080;
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
              targetPort = 8080;
              protocol = "TCP";
            }
          ];
        }
        |> scope.mkResource;

      # --- Entry point ---
      root = self.service;
    };
}

# Echo server package: simple nginx returning a test page.
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
    image = kix.options.image {
      repository = "nginxinc/nginx-unprivileged";
      tag = "1.27-alpine";
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
    service = {
      type = lib.mkOption {
        type = lib.types.enum [
          "ClusterIP"
          "NodePort"
          "LoadBalancer"
        ];
        default = "ClusterIP";
        description = "Type of the echo-server's Service.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 80;
        description = "Port the Service listens on. It forwards to the container's port 8080.";
      };
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
              # nginx drains open connections on the image's SIGQUIT stop
              # signal; the Kubernetes default bounds that wait.
              terminationGracePeriodSeconds = 30;
              containers = [
                {
                  name = "nginx";
                  image = kix.image.ref config.image;
                  imagePullPolicy = config.image.pullPolicy;
                  # nginx-unprivileged runs as uid 101 and listens on 8080.
                  securityContext = {
                    runAsNonRoot = true;
                    readOnlyRootFilesystem = true;
                  };
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
                    # nginx-unprivileged keeps its pid file and temp paths
                    # under /tmp.
                    {
                      name = "tmp";
                      mountPath = "/tmp";
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
                {
                  name = "tmp";
                  emptyDir = { };
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

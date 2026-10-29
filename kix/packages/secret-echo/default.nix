# Secret echo server: test package for SOPS secret integration.
#
# Runs a simple pod that reads secret credentials from env vars and
# serves them via an HTTP endpoint. Used by integration tests to verify
# that SOPS-encrypted secrets are correctly decrypted and injected.
#
# Expects a `credentials` dep (a secret with keys: username, password, host, port).

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
    version = "1.0.0";
    description = "Echo server that reads secrets from env vars (test only)";
    owner = "platform";
  };

  options = {
    image = kix.options.image {
      repository = "nginxinc/nginx-unprivileged";
      tag = "1.27-alpine";
    };
  };

  build =
    {
      self,
      config,
      credentials,
      ...
    }:
    {
      configmap = scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        inherit name;
        data = {
          # Entrypoint script: writes env vars to a static file, then starts nginx
          "entrypoint.sh" = ''
            #!/bin/sh
            mkdir -p /usr/share/nginx/html
            echo "DB_USERNAME=$DB_USERNAME" > /usr/share/nginx/html/index.html
            echo "DB_PASSWORD=$DB_PASSWORD" >> /usr/share/nginx/html/index.html
            echo "DB_HOST=$DB_HOST" >> /usr/share/nginx/html/index.html
            echo "DB_PORT=$DB_PORT" >> /usr/share/nginx/html/index.html
            exec nginx -g 'daemon off;'
          '';
          "default.conf" = ''
            server {
                listen 8080;
                location / {
                    root /usr/share/nginx/html;
                    default_type text/plain;
                }
                location /healthz {
                    default_type text/plain;
                    return 200 'ok\n';
                }
            }
          '';
        };
      };

      deployment =
        {
          inherit name;
          spec = {
            replicas = 1;
            selector.matchLabels = scope.selectorLabels;
            template.spec = {
              # nginx drains open connections on the image's SIGQUIT stop
              # signal; the Kubernetes default bounds that wait.
              terminationGracePeriodSeconds = 30;
              containers = [
                {
                  name = "echo";
                  image = kix.image.ref config.image;
                  imagePullPolicy = config.image.pullPolicy;
                  command = [
                    "/bin/sh"
                    "/etc/config/entrypoint.sh"
                  ];
                  # nginx-unprivileged runs as uid 101 and listens on 8080.
                  securityContext = {
                    runAsNonRoot = true;
                    readOnlyRootFilesystem = true;
                  };
                  ports = [
                    (kix.port "http" 8080)
                  ];
                  env = credentials.out.mkEnv {
                    DB_USERNAME = "username";
                    DB_PASSWORD = "password";
                    DB_HOST = "host";
                    DB_PORT = "port";
                  };
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
                      mountPath = "/etc/config";
                      readOnly = true;
                    }
                    {
                      name = "nginx-conf";
                      mountPath = "/etc/nginx/conf.d";
                      readOnly = true;
                    }
                    # The entrypoint writes the page here, and
                    # nginx-unprivileged keeps its pid file and temp paths
                    # under /tmp.
                    {
                      name = "html";
                      mountPath = "/usr/share/nginx/html";
                    }
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
                  configMap = {
                    name = self.configmap.out.name;
                    defaultMode = 493; # 0755 (executable entrypoint)
                    items = [
                      {
                        key = "entrypoint.sh";
                        path = "entrypoint.sh";
                      }
                    ];
                  };
                }
                {
                  name = "nginx-conf";
                  configMap = {
                    name = self.configmap.out.name;
                    items = [
                      {
                        key = "default.conf";
                        path = "default.conf";
                      }
                    ];
                  };
                }
                {
                  name = "html";
                  emptyDir = { };
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

      service =
        self.deployment
        |> kix.service.fromWorkload {
          inherit name;
          ports = [
            {
              name = "http";
              port = 80;
              targetPort = 8080;
              protocol = "TCP";
            }
          ];
        }
        |> scope.mkResource;

      root = self.service;
    };
}

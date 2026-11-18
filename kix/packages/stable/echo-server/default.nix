# echo-server: an nginx server that answers every request with a fixed
# text message.
#
# Installs a ConfigMap holding the nginx config, a Deployment, and a Service
# in front of it. It needs no dependencies and no config, so it is the
# smallest package to deploy when checking that a cluster works.
#
# Minimal instance:
#
#   instances.demo.hello = {
#     package = packages.echo-server;
#     config.message = "hello from demo";   # optional; tells instances apart
#   };
#
# `out`: the Service's `name`, `fqdn`, and `port` (`config.service.port`,
# 80 by default), and `version`, the nginx version `image.tag` names.
# `/healthz` answers "ok"; every other path returns `config.message`.
# nginx serves the message from a file, so it can hold any text.
#
# Escape hatches: none of its own. Use the instance's `partsOverlays` for
# anything the options do not cover (placement, extra labels).
#
# Limits: the message is served as plain text, and the server serves
# nothing else.
#
# Upgrades: nginx 1.30.6 reads the same config as 1.30.5 and keeps no data,
# so a plain deploy upgrades an existing install. Going back to 1.30.5 also
# works with a plain deploy of the older version. No operator step is needed
# in either direction.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  name = scope.instanceName;
  release = "1.30.6";
in
{
  meta = {
    version = release;
    description = "Nginx echo server for connectivity testing";
    owner = "app-team";
  };

  assertions =
    { config, ... }:
    [
      {
        assertion = config.replicaCount == null;
        message = "replicaCount was renamed to replicas. Set config.replicas instead.";
      }
    ];

  options = {
    image = kix.options.image {
      repository = "docker.io/nginxinc/nginx-unprivileged";
      tag = "${release}-alpine";
      digest = "sha256:f5116ed4606f3eb015dd4a8e28cb9b351476dc0ad4bc6e9f93b19cec130cdf03";
    };
    # Declared only so that setting the removed name fails with the new one.
    replicaCount = lib.mkOption {
      type = lib.types.unspecified;
      default = null;
      visible = false;
      description = "Removed. Use `replicas`.";
    };
    replicas = lib.mkOption {
      type = lib.types.ints.positive;
      # Stateless and serving: two replicas as soon as a pod restart must
      # not be downtime, spread so either survives a lost node or zone.
      default = kix.availability.pick availability {
        none = 1;
        pod = 2;
        node = 2;
        zone = 2;
      };
      description = ''
        Number of `Deployment` replicas for the echo-server pods. Defaults
        from the cluster's availability level.
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
        Plain-text response body returned for every path except `/healthz`.
        The server returns quotes and `$` characters as written. Set this to
        tell instances apart during connectivity checks.
      '';
    };
  };

  build =
    { self, config, ... }:
    {
      configmap = scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        inherit name;
        data = {
          # nginx includes only the *.conf files of this directory.
          "message.txt" = "${config.message}\n";
          "default.conf" = ''
            server {
                listen 8080;
                location / {
                    root /etc/nginx/conf.d;
                    default_type text/plain;
                    try_files /message.txt =404;
                    # nginx refuses a POST for a static file with 405. The
                    # redirect turns the request into a GET, so every
                    # method gets the message.
                    error_page 405 =200 /message.txt;
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
            replicas = config.replicas;
            selector.matchLabels = scope.selectorLabels;
            # nginx reads its config only at start, so a changed ConfigMap
            # must roll the pods.
            template.metadata.annotations."checksum/config" = self.configmap.out.contentHash;
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
                    allowPrivilegeEscalation = false;
                    capabilities.drop = [ "ALL" ];
                    seccompProfile.type = "RuntimeDefault";
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

      root = {
        resource = self.service;
        out.version = kix.image.version config.image;
      };
    };
}

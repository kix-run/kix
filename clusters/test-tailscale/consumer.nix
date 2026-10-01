# An nginx echo backend put on the tailnet both ways the tailscale package
# offers: an Ingress from `out.mkIngress`, and a LoadBalancer Service with
# `out.loadBalancerClass` opened to the proxies by `out.mkBackendPolicy`.
# Under default deny each path works only through its `*-from-tailscale`
# policy.

{ scope, kix, ... }:

let
  name = scope.instanceName;
  port = 8080;
in
{
  meta = {
    version = "1.30.5";
    description = "Echo backend reached over the tailnet";
    owner = "platform";
  };

  build =
    { self, tailscale, ... }:
    {
      deployment = scope.mkDeployment {
        inherit name;
        spec = {
          replicas = 1;
          selector.matchLabels = scope.selectorLabels;
          template.spec = {
            securityContext = {
              runAsNonRoot = true;
              seccompProfile.type = "RuntimeDefault";
            };
            containers = [
              {
                name = "nginx";
                # echo-server's image; nginx serves its default page on 8080.
                image = "docker.io/nginxinc/nginx-unprivileged:1.30.5-alpine@sha256:ed04ec1ff34502c339ee5c3ae3f855442398edc1d05591e2b98981dcbbd20b1e";
                ports = [ (kix.port "http" port) ];
                readinessProbe.httpGet = {
                  path = "/";
                  port = "http";
                };
                livenessProbe.httpGet = {
                  path = "/";
                  port = "http";
                };
                resources = {
                  requests = {
                    cpu = "10m";
                    memory = "16Mi";
                  };
                  limits = {
                    cpu = "100m";
                    memory = "64Mi";
                  };
                };
                securityContext = {
                  allowPrivilegeEscalation = false;
                  capabilities.drop = [ "ALL" ];
                  readOnlyRootFilesystem = true;
                };
                volumeMounts = [
                  {
                    name = "tmp";
                    mountPath = "/tmp";
                  }
                ];
              }
            ];
            volumes = [
              {
                name = "tmp";
                emptyDir = { };
              }
            ];
          };
        };
      };

      service =
        self.deployment
        |> kix.service.fromWorkload {
          inherit name;
          labels."app.kubernetes.io/component" = "ingress-backend";
          ports = [
            {
              name = "http";
              port = 80;
              targetPort = port;
            }
          ];
        }
        |> scope.mkResource;

      # http://<name>.<tailnet>.ts.net through an ingress proxy.
      tailnet = tailscale.out.mkIngress scope {
        inherit name;
        service = self.service;
      };

      lbService =
        self.deployment
        |> kix.service.fromWorkload {
          name = "${name}-lb";
          labels."app.kubernetes.io/component" = "load-balancer";
          type = "LoadBalancer";
          spec.loadBalancerClass = tailscale.out.loadBalancerClass;
          ports = [
            {
              name = "http";
              port = 80;
              targetPort = port;
            }
          ];
        }
        |> scope.mkResource;

      lbPolicy = tailscale.out.mkBackendPolicy scope { service = self.lbService; };

      root = {
        resource = self.deployment;
        requires = [
          self.service
          self.tailnet.ingress
          self.lbService
        ];
      };
    };
}

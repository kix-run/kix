# DNS Exporter package — tykling/dns_exporter.
#
# Prometheus exporter for DNS queries. Exposes metrics on port 15353.
#
# Resources: Deployment, Service.

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
  };

  options = {
    image = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        repository = "tykling/dns_exporter";
        tag = "latest";
      };
    };
    replicaCount = lib.mkOption {
      type = lib.types.int;
      default = 2;
    };
    resources = lib.mkOption {
      type = lib.types.anything;
      default = { };
    };
  };

  build =
    {
      self,
      config,
      clusterConfig,
    }:
    {
      deployment =
        {
          name = name;
          spec = {
            replicas = config.replicaCount;
            selector.matchLabels = scope.selectorLabels;
            template.spec.containers = [
              {
                name = "dns-exporter";
                image = "${config.image.repository}:${config.image.tag}";
                ports = [
                  (kix.port "metrics" 15353)
                ];
              }
            ];
          };
        }
        |> scope.mkDeployment;

      service =
        self.deployment
        |> kix.service.fromWorkload {
          inherit name;
          ports = [
            {
              name = "metrics";
              port = 15353;
              targetPort = 15353;
              protocol = "TCP";
            }
          ];
        }
        |> scope.mkResource;

      main = self.service;
    };
}

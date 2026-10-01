# DNS Exporter package: tykling/dns_exporter.
#
# Prometheus exporter for DNS queries. Exposes metrics on port 15353.
#
# Resources: Deployment, Service.

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
    version = "1.0.0";
    description = "dns_exporter, a Prometheus exporter that runs DNS queries and reports the results as metrics";
    owner = "platform";
  };

  options = {
    image = kix.options.image {
      repository = "tykling/dns_exporter";
      tag = "v1.2.3";
    };
    replicaCount = lib.mkOption {
      type = lib.types.int;
      # Probe-style exporter behind a Service: each scrape lands on one
      # pod, so a second replica is redundancy and not duplicate series.
      default = kix.availability.pick availability {
        none = 1;
        pod = 2;
        node = 2;
        zone = 2;
      };
      description = ''
        Number of dns-exporter `Deployment` replicas. Defaults from the
        cluster's availability level (v2_discussions/145).
      '';
    };
    # Upstream publishes no chart or resource guidance. An idle exporter
    # holds about 45 MiB.
    resources = kix.options.resources {
      requests = {
        cpu = "10m";
        memory = "64Mi";
      };
      limits = {
        cpu = "200m";
        memory = "128Mi";
      };
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
            # Kubernetes default: a scrape in flight is the only work lost.
            template.spec.terminationGracePeriodSeconds = 30;
            template.spec.containers = [
              {
                name = "dns-exporter";
                image = kix.image.ref config.image;
                imagePullPolicy = config.image.pullPolicy;
                # The image's `nonroot` user is uid 65532; stated so the
                # kubelet can verify it rather than trust the image.
                securityContext = {
                  runAsNonRoot = true;
                  runAsUser = 65532;
                  runAsGroup = 65532;
                  readOnlyRootFilesystem = true;
                  allowPrivilegeEscalation = false;
                };
                ports = [
                  (kix.port "metrics" 15353)
                ];
                resources = config.resources;
                # `/` is the exporter's static index page; `/query` would
                # run a DNS lookup on every probe.
                livenessProbe = {
                  httpGet = {
                    path = "/";
                    port = "metrics";
                  };
                  periodSeconds = 10;
                  failureThreshold = 3;
                };
                readinessProbe = {
                  httpGet = {
                    path = "/";
                    port = "metrics";
                  };
                  periodSeconds = 10;
                };
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

      root = self.service;
    };
}

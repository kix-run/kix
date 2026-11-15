# dns-exporter: tykling/dns_exporter, a Prometheus exporter that runs DNS
# queries on request and reports the results as metrics.
#
# Installs a Deployment and a Service on port 15353. It needs no
# dependencies and no config. Prometheus asks it for a query through the
# `/query` path with `server` and `query_name` parameters, usually from a
# ScrapeConfig or a Probe the cluster author writes.
#
# Minimal instance:
#
#   instances.monitoring.dns-exporter.package = packages.experimental.dns-exporter;
#
# `out`: the Service's `name`, `fqdn`, and `port` (15353), and `version`, the
# dns_exporter version `image.tag` names.
#
# Escape hatches: the instance's `partsOverlays`, for example to mount a
# dns_exporter config file.
#
# Limits: the package renders no scrape target of its own, so nothing is
# probed until a cluster adds one. It runs with the exporter's built-in
# defaults and has no config-file option.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  release = "v1.2.3";
  name = scope.instanceName;
in
{
  meta = {
    version = lib.removePrefix "v" release;
    description = "dns_exporter, a Prometheus exporter that runs DNS queries and reports the results as metrics";
    owner = "platform";
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
      repository = "docker.io/tykling/dns_exporter";
      tag = release;
      digest = "sha256:cd6d650c01c159cf34675615b553316f648dce8e76deabd3eeccab1e8cdd9b42";
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
        cluster's availability level.
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
    { self, config, ... }:
    {
      deployment =
        {
          name = name;
          spec = {
            replicas = config.replicas;
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

      root = {
        resource = self.service;
        out.version = kix.image.version config.image;
      };
    };
}

# caddy: the Caddy web server and reverse proxy, from the official image.
#
# Installs a ServiceAccount, a Deployment, a Service on ports 80 and 443
# (LoadBalancer by default), a HorizontalPodAutoscaler on CPU, and, when
# `customDomainsService.enabled`, a second LoadBalancer Service named
# `<instance>-custom-domains`.
#
# Dependencies:
#   caddyfile             a secret with the key `Caddyfile`. A
#                         `packages.secret` instance or a `packages.secret-ref`
#                         instance. Every key is a file in /etc/caddy, so
#                         snippets the Caddyfile imports can sit beside it.
#   storage (optional)    a claim for /data, where Caddy keeps certificates,
#                         OCSP staples, and ACME account keys. Defaults to an
#                         emptyDir.
#
# Minimal instance:
#
#   instances.edge = {
#     caddy.package = packages.experimental.caddy;
#     caddy-config = {
#       package = packages.secret;
#       aliases = [ "caddyfile" ];
#       config.keys = [ "Caddyfile" ];
#       config.source = ./secrets/caddyfile.sops.yaml;
#     };
#   };
#
# The Caddyfile must answer `/healthz` on port 8080, which both probes call.
# Port 2019 serves metrics when the Caddyfile moves the admin endpoint off
# localhost (`admin :2019`).
#
# A Kix-built `caddyfile` secret restarts the pods when it changes. A
# `secret-ref` secret has no content hash, so Caddy reads a changed
# Caddyfile on the next restart.
#
# Network: egress to anywhere, for the upstreams a Caddyfile can name and
# for ACME.
#
# `out`: the main Service's `name`, `fqdn`, and `port`.
#
# Escape hatches: `image` for a build with plugins, and the instance's
# `partsOverlays`.
#
# Limits: without `storage`, each pod keeps its own certificates on an
# emptyDir, so a new pod requests them again and can reach the ACME
# issuer's rate limits. With `storage` and more than one replica, the claim
# must be ReadWriteMany, which Kix does not check.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  name = scope.instanceName;
  who = "caddy ${scope.namespaceName}/${name}";
  release = "2.10.0";

  # Stateless and serving user traffic: two replicas once a pod restart
  # must not be downtime, spread so either survives a lost node or zone.
  replicasForLevel = kix.availability.pick availability {
    none = 1;
    pod = 2;
    node = 2;
    zone = 2;
  };

  # The official image defines no user. uid 65532 is the conventional
  # unprivileged `nonroot` id.
  uid = 65532;
in
{
  meta = {
    version = release;
    description = "Caddy web server and reverse proxy";
    owner = "app-team";
    network = {
      # Entities for auto-derived external ingress (LoadBalancer Service).
      externalIngressEntities = [ "all" ];
      intents = {
        external = {
          egress = [
            {
              to = "world";
              entities = [ "all" ];
            }
          ];
        };
      };
    };
  };

  assertions =
    { config, ... }:
    [
      {
        assertion = config.replicaCount == null;
        message = "[K6965] caddy: replicaCount was removed. Set config.replicas instead.";
      }
      {
        assertion = config.configSecretName == null;
        message = "[K2263] caddy: configSecretName was removed. Give the Caddyfile through the caddyfile dependency, a secret with the key Caddyfile, such as a packages.secret instance with aliases = [ \"caddyfile\" ].";
      }
    ];

  options = {
    image = kix.options.image {
      repository = "docker.io/library/caddy";
      tag = release;
      digest = "sha256:133b5eb7ef9d42e34756ba206b06d84f4e3eb308044e268e182c2747083f09de";
    };
    replicas = lib.mkOption {
      type = lib.types.ints.positive;
      default = replicasForLevel;
      description = ''
        Number of Caddy `Deployment` replicas. Defaults from the cluster's
        availability level.
      '';
    };
    replicaCount = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      visible = false;
      description = "Removed. Setting it fails the build with a message that names `replicas`.";
    };
    resources = kix.options.resources {
      requests = {
        cpu = "200m";
        memory = "256Mi";
      };
      limits = {
        cpu = "500m";
        memory = "512Mi";
      };
    };

    service = lib.mkOption {
      type = lib.types.submodule {
        options = {
          type = lib.mkOption {
            type = lib.types.str;
            default = "LoadBalancer";
            description = "Service `spec.type` of the main Service.";
          };
          annotations = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = "Annotations on the main Service.";
          };
        };
      };
      default = { };
      description = "The Service that serves ports 80 and 443.";
    };

    customDomainsService = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enabled = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Emit a second LoadBalancer Service, `<instance>-custom-domains`, on ports 80 and 443.";
          };
          annotations = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = "Annotations on the custom-domains Service.";
          };
        };
      };
      default = { };
      description = "An optional second LoadBalancer Service for custom domains.";
    };

    hpa = lib.mkOption {
      type = lib.types.submodule {
        options = {
          minReplicas = lib.mkOption {
            type = lib.types.int;
            # The floor follows the replicas default, so the autoscaler
            # never undoes the availability level.
            default = replicasForLevel;
            description = "HorizontalPodAutoscaler `spec.minReplicas`. Defaults from the cluster's availability level.";
          };
          maxReplicas = lib.mkOption {
            type = lib.types.int;
            default = 10;
            description = "HorizontalPodAutoscaler `spec.maxReplicas`.";
          };
          targetCPUUtilization = lib.mkOption {
            type = lib.types.int;
            default = 60;
            description = "Average CPU utilization, as a percentage of the CPU request, that the autoscaler targets.";
          };
        };
      };
      default = { };
      description = "The HorizontalPodAutoscaler on the Deployment.";
    };

    configSecretName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      visible = false;
      description = "Removed. Setting it fails the build with a message that names the `caddyfile` dependency.";
    };
  };

  build =
    {
      self,
      config,
      clusterConfig,
      caddyfile,
      storage ? null,
    }:
    let
      caddyfileSecret = kix.contracts.secret.helpers.use {
        inherit who;
        arg = "caddyfile";
        dep = caddyfile;
        keys = [ "Caddyfile" ];
      };

      # A Kix-built Secret has an identity hash. A changed Caddyfile then
      # rolls the pods, since Caddy reads it only at start.
      configAnnotations = lib.optionalAttrs (caddyfileSecret.out ? identityHash) {
        "checksum/caddyfile" = caddyfileSecret.out.identityHash;
      };

      dataVolume =
        if storage != null then
          { name = "data"; } // (kix.mount.pvc storage { mountPath = "/data"; }).source
        else
          {
            name = "data";
            emptyDir = { };
          };
    in
    {
      serviceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = name;
      };

      deployment =
        {
          inherit name;
          spec = {
            replicas = config.replicas;
            revisionHistoryLimit = 10;
            selector.matchLabels = scope.selectorLabels;
            strategy = {
              type = "RollingUpdate";
              rollingUpdate = {
                maxSurge = 1;
                maxUnavailable = 0;
              };
            };
            template.metadata.annotations = configAnnotations;
            template.spec = {
              serviceAccountName = self.serviceAccount.out.name;
              # Caddy's `grace_period` is unbounded by default, so the
              # Kubernetes default of 30s is what ends a drain.
              terminationGracePeriodSeconds = 30;
              securityContext = {
                # Caddy listens on 80 and 443 as a non-root user. The
                # official image sets the cap_net_bind_service file
                # capability on /usr/bin/caddy, but the kernel ignores file
                # capabilities when allowPrivilegeEscalation is false. The
                # pod lowers the privileged-port floor instead (a safe
                # sysctl since Kubernetes 1.22).
                sysctls = [
                  {
                    name = "net.ipv4.ip_unprivileged_port_start";
                    value = "0";
                  }
                ];
                # Makes a `storage` claim writable by the Caddy user.
                fsGroup = uid;
                fsGroupChangePolicy = "OnRootMismatch";
              };
              containers = [
                {
                  name = "caddy";
                  image = kix.image.ref config.image;
                  imagePullPolicy = config.image.pullPolicy;
                  args = [
                    "caddy"
                    "run"
                    "--config"
                    "/etc/caddy/Caddyfile"
                  ];
                  ports = [
                    (kix.port "health" 8080)
                    (kix.port "http" 80)
                    (kix.port "https" 443)
                    (kix.port "metrics" 2019)
                  ];
                  livenessProbe = {
                    httpGet = {
                      path = "/healthz";
                      port = 8080;
                    };
                    periodSeconds = 10;
                    failureThreshold = 3;
                    successThreshold = 1;
                    timeoutSeconds = 1;
                  };
                  readinessProbe = {
                    httpGet = {
                      path = "/healthz";
                      port = 8080;
                    };
                    periodSeconds = 10;
                    failureThreshold = 3;
                    successThreshold = 1;
                    timeoutSeconds = 1;
                  };
                  resources = config.resources;
                  securityContext = {
                    runAsNonRoot = true;
                    runAsUser = uid;
                    runAsGroup = uid;
                    allowPrivilegeEscalation = false;
                    privileged = false;
                    readOnlyRootFilesystem = true;
                  };
                  volumeMounts = [
                    {
                      name = "caddy-config";
                      mountPath = "/etc/caddy";
                      readOnly = true;
                    }
                    # The official image sets XDG_DATA_HOME=/data (certificates,
                    # OCSP staples, locks) and XDG_CONFIG_HOME=/config (autosaved
                    # config).
                    {
                      name = "data";
                      mountPath = "/data";
                    }
                    {
                      name = "config";
                      mountPath = "/config";
                    }
                    # The root filesystem is read-only. Caddy and its plugins
                    # write temporary files, such as large request bodies, to
                    # os.TempDir(), which is /tmp.
                    {
                      name = "tmp";
                      mountPath = "/tmp";
                    }
                  ];
                }
              ];
              volumes = [
                {
                  name = "caddy-config";
                  secret = {
                    secretName = caddyfileSecret.out.name;
                    defaultMode = 420;
                  };
                }
                dataVolume
                {
                  name = "config";
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
          type = config.service.type;
          annotations = config.service.annotations;
          ports = [
            {
              name = "http";
              port = 80;
              targetPort = 80;
              protocol = "TCP";
            }
            {
              name = "https";
              port = 443;
              targetPort = 443;
              protocol = "TCP";
            }
          ];
        }
        |> scope.mkResource;

      customDomainsService =
        if config.customDomainsService.enabled then
          self.deployment
          |> kix.service.fromWorkload {
            name = "${name}-custom-domains";
            type = "LoadBalancer";
            annotations = config.customDomainsService.annotations;
            ports = [
              {
                name = "http";
                port = 80;
                targetPort = 80;
                protocol = "TCP";
              }
              {
                name = "https";
                port = 443;
                targetPort = 443;
                protocol = "TCP";
              }
            ];
          }
          |> scope.mkResource
        else
          null;

      hpa = scope.mkResource {
        apiVersion = "autoscaling/v2";
        kind = "HorizontalPodAutoscaler";
        inherit name;
        spec = {
          scaleTargetRef = {
            apiVersion = "apps/v1";
            kind = "Deployment";
            name = self.deployment.out.name;
          };
          minReplicas = config.hpa.minReplicas;
          maxReplicas = config.hpa.maxReplicas;
          metrics = [
            {
              type = "Resource";
              resource = {
                name = "cpu";
                target = {
                  type = "Utilization";
                  averageUtilization = config.hpa.targetCPUUtilization;
                };
              };
            }
          ];
        };
      };

      # No PodDisruptionBudget here: the availability plugin derives one for
      # every workload above a single replica, and an explicit
      # minAvailable = 1 blocked eviction outright on a single-replica
      # cluster.
      root = self.service;
    };
}

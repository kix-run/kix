# Caddy reverse proxy package.
#
# Runs Caddy as a LoadBalancer-fronted deployment with HPA, PDB,
# and ServiceAccount.  Config is mounted from an external Secret.
#
# Resources: ServiceAccount, Deployment, Service, HPA, PDB,
#            optional custom-domains Service.

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
    version = "2.10.0-cf";
    description = "Caddy reverse proxy";
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

  options = {
    image = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        repository = "ghcr.io/northwind/shopfront/caddy";
        tag = "2.10.0-cf";
        pullPolicy = "IfNotPresent";
      };
    };
    replicaCount = lib.mkOption {
      type = lib.types.int;
      # Stateless and serving user traffic: two replicas once a pod restart
      # must not be downtime, three once a whole zone may go.
      default = kix.availability.pick availability {
        none = 1;
        pod = 2;
        node = 2;
        zone = 3;
      };
      description = ''
        Number of Caddy `Deployment` replicas. Defaults from the cluster's
        availability level (v2_discussions/145).
      '';
    };
    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
        requests = {
          cpu = "200m";
          memory = "256Mi";
        };
        limits = {
          cpu = "500m";
          memory = "512Mi";
        };
      };
    };

    # --- Service ---
    service = lib.mkOption {
      type = lib.types.anything;
      default = {
        type = "LoadBalancer";
        annotations = { };
      };
    };

    # --- Custom domains service (optional, prod-only) ---
    customDomainsService = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = false;
        annotations = { };
      };
    };

    # --- HPA ---
    hpa = lib.mkOption {
      type = lib.types.anything;
      default = {
        # The floor follows replicaCount's mapping of the availability
        # level (v2_discussions/145), so the autoscaler never undoes it.
        minReplicas = kix.availability.pick availability {
          none = 1;
          pod = 2;
          node = 2;
          zone = 3;
        };
        maxReplicas = 10;
        targetCPUUtilization = 60;
      };
    };

    # --- Config secret name ---
    configSecretName = lib.mkOption {
      type = lib.types.str;
      default = "${name}-config";
    };
  };

  build =
    {
      self,
      config,
      clusterConfig,
    }:
    {
      # --- ServiceAccount ---
      serviceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = name;
      };

      # --- Config secret reference ---
      # User-provided external Secret — wrapped in a SecretRef so volume
      # mounts carry DI context and the deploy engine gates on its existence.
      configSecret = scope.mkSecretRef {
        name = config.configSecretName;
        keys = [ ];
      };

      # --- Deployment ---
      deployment =
        {
          inherit name;
          spec = {
            replicas = config.replicaCount;
            revisionHistoryLimit = 10;
            selector.matchLabels = scope.selectorLabels;
            strategy = {
              type = "RollingUpdate";
              rollingUpdate = {
                maxSurge = 1;
                maxUnavailable = 0;
              };
            };
            template.spec = {
              serviceAccountName = self.serviceAccount.out.name;
              # Caddy's `grace_period` is unbounded by default, so the
              # Kubernetes default of 30s is what ends a drain.
              terminationGracePeriodSeconds = 30;
              # Caddy listens on 80 and 443 as a non-root user. A custom
              # build such as the default image may lack the
              # cap_net_bind_service file capability the official image sets
              # on /usr/bin/caddy, so the pod lowers the privileged-port
              # floor (a safe sysctl since Kubernetes 1.22).
              securityContext.sysctls = [
                {
                  name = "net.ipv4.ip_unprivileged_port_start";
                  value = "0";
                }
              ];
              containers = [
                {
                  name = "caddy";
                  image = "${config.image.repository}:${config.image.tag}";
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
                  # The official Caddy image defines no user; uid 65532 is
                  # the conventional unprivileged `nonroot` id.
                  securityContext = {
                    runAsNonRoot = true;
                    runAsUser = 65532;
                    runAsGroup = 65532;
                    allowPrivilegeEscalation = false;
                    privileged = false;
                    readOnlyRootFilesystem = true;
                  };
                  volumeMounts = [
                    {
                      name = "caddy-config";
                      mountPath = "/etc/caddy/Caddyfile";
                      readOnly = true;
                      subPath = "Caddyfile";
                    }
                    {
                      name = "caddy-config";
                      mountPath = "/etc/caddy/crs-setup.conf";
                      readOnly = true;
                      subPath = "crs-setup.conf";
                    }
                    # The official image sets XDG_DATA_HOME=/data (certificates,
                    # OCSP staples, locks) and XDG_CONFIG_HOME=/config (autosaved
                    # config). Both last as long as the pod.
                    {
                      name = "data";
                      mountPath = "/data";
                    }
                    {
                      name = "config";
                      mountPath = "/config";
                    }
                    # The Coraza WAF configured by crs-setup.conf writes request
                    # bodies over 128 KiB to os.TempDir(), which is /tmp.
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
                    secretName = self.configSecret.out.name;
                    defaultMode = 420;
                  };
                }
                {
                  name = "data";
                  emptyDir = { };
                }
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

      # --- Service ---
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

      # --- Custom Domains Service (optional) ---
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

      # --- HorizontalPodAutoscaler ---
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

      # --- Entry point ---
      # No PodDisruptionBudget here: the availability plugin derives one for
      # every workload above a single replica, and an explicit
      # minAvailable = 1 blocked eviction outright on a single-replica
      # cluster.
      root = self.service;
    };
}

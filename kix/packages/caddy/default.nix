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
}:

let
  name = scope.instanceName;
in
{
  meta = {
    version = "2.10.0-cf";
    description = "Caddy reverse proxy";
    network = {
      externalIngressEntities = [ "all" ];
      allowExternalEgress = true;
      externalEgressEntities = [ "all" ];
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
      default = 3;
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
        minReplicas = 3;
        maxReplicas = 10;
        targetCPUUtilization = 60;
      };
    };

    # --- PDB ---
    pdb = lib.mkOption {
      type = lib.types.anything;
      default = {
        minAvailable = 1;
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
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    privileged = false;
                    readOnlyRootFilesystem = false;
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
                  ];
                }
              ];
              topologySpreadConstraints = [
                {
                  labelSelector.matchLabels = scope.selectorLabels;
                  maxSkew = 1;
                  topologyKey = "kubernetes.io/hostname";
                  whenUnsatisfiable = "ScheduleAnyway";
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
              targetPort = "http";
              protocol = "TCP";
            }
            {
              name = "https";
              port = 443;
              targetPort = "https";
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
                targetPort = "http";
                protocol = "TCP";
              }
              {
                name = "https";
                port = 443;
                targetPort = "https";
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

      # --- PodDisruptionBudget ---
      pdb = scope.mkResource {
        apiVersion = "policy/v1";
        kind = "PodDisruptionBudget";
        inherit name;
        requires = [ self.deployment ];
        spec = {
          minAvailable = config.pdb.minAvailable;
          selector.matchLabels = scope.selectorLabels;
        };
      };

      # --- Entry point ---
      root = {
        resource = self.service;
        requires = [
          self.pdb
        ];
      };
    };
}

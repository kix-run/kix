# caddy.nix — build part: caddy Deployment, Service, HPA.
{
  self,
  config,
  clusterConfig,
  scope,
  lib,
  kix,
  postgres ? null,
  valkey ? null,
}:

let
  name = scope.instanceName;
  h = import ./helpers.nix {
    inherit
      name
      config
      lib
      kix
      scope
      postgres
      valkey
      ;
  };
  inherit (h) componentLabels selectorLabels mkPodSpec;
in
{
  # ── Caddy Deployment ────────────────────────────────────────────
  caddyDeployment =
    if config.caddy.enabled then
      {
        name = "${name}-caddy";
        labels = componentLabels "caddy";
        spec = {
          replicas = config.caddy.replicaCount;
          strategy.rollingUpdate.maxSurge = "100%";
          selector.matchLabels = selectorLabels "caddy";
          template = {
            metadata.labels = selectorLabels "caddy";
            spec = mkPodSpec self {
              containers = [
                {
                  name = "caddy";
                  image = "${config.caddy.image.repository}:${config.caddy.image.tag}";
                  imagePullPolicy = config.caddy.image.pullPolicy;
                  ports = [
                    (kix.port "http" config.caddy.port)
                  ];
                  env = kix.mkEnvVars {
                    BACKEND_HOST = self.backendService.out.name;
                    BACKEND_PORT = toString config.backend.port;
                    FRONTEND_HOST = if config.frontend.enabled then self.frontendService.out.name else null;
                    FRONTEND_PORT = if config.frontend.enabled then toString config.frontend.port else null;
                  };
                  resources = config.caddy.resources;
                }
              ];
              volumes = [ ];
            };
          };
        };
      }
      |> scope.mkDeployment
    else
      null;

  # ── Caddy Service ───────────────────────────────────────────────
  caddyService =
    if config.caddy.enabled then
      scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${name}-caddy";
        labels = componentLabels "caddy";
        spec = {
          type = "ClusterIP";
          selector = selectorLabels "caddy";
          ports = [
            {
              name = "http";
              port = config.caddy.port;
              targetPort = "http";
              protocol = "TCP";
            }
          ];
        };
        outputs = {
          port = toString config.caddy.port;
        };
        requires = [ self.caddyDeployment ];
      }
    else
      null;

  # ── Caddy HPA ──────────────────────────────────────────────────
  caddyHpa =
    if config.caddy.enabled && config.caddy.hpa.enabled then
      scope.mkResource {
        apiVersion = "autoscaling/v2";
        kind = "HorizontalPodAutoscaler";
        name = "${name}-caddy";
        labels = componentLabels "caddy";
        spec = {
          scaleTargetRef = {
            apiVersion = "apps/v1";
            kind = "Deployment";
            name = self.caddyDeployment.out.name;
          };
          minReplicas = config.caddy.hpa.minReplicas;
          maxReplicas = config.caddy.hpa.maxReplicas;
          metrics = [
            {
              type = "Resource";
              resource = {
                name = "cpu";
                target = {
                  type = "Utilization";
                  averageUtilization = config.caddy.hpa.targetCPU;
                };
              };
            }
          ];
        };
      }
    else
      null;
}

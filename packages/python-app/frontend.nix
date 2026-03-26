# frontend.nix — build part: frontend Deployment, Service (conditional).
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
  inherit (h)
    componentLabels
    selectorLabels
    mkPodSpec
    mkFrontendContainer
    ;
in
{
  # ── Frontend Deployment ─────────────────────────────────────────
  frontendDeployment =
    if config.frontend.enabled then
      {
        name = "${name}-frontend";
        labels = componentLabels "frontend";
        spec = {
          replicas = config.frontend.replicaCount;
          strategy = {
            rollingUpdate = {
              maxSurge =
                if config.frontend.strategy.maxSurge != null then
                  config.frontend.strategy.maxSurge
                else
                  config.maxSurge;
            }
            // lib.optionalAttrs (config.frontend.strategy.maxUnavailable != null) {
              maxUnavailable = config.frontend.strategy.maxUnavailable;
            };
            type = "RollingUpdate";
          };
          selector.matchLabels = selectorLabels "frontend";
          template = {
            metadata = {
              labels = selectorLabels "frontend";
            }
            // lib.optionalAttrs config.frontend.useConfigMap {
              annotations = {
                "checksum/config" = self.frontendConfigmap.out.identityHash;
              };
            };
            spec = mkPodSpec self {
              containers = [ (mkFrontendContainer self) ];
              volumes = [ ];
            };
          };
        };
      }
      |> scope.mkDeployment
    else
      null;

  # ── Frontend Service ────────────────────────────────────────────
  frontendService =
    if config.frontend.enabled then
      scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${name}-frontend-internal";
        labels = componentLabels "frontend";
        spec = {
          type = "ClusterIP";
          selector = selectorLabels "frontend";
          ports = [
            {
              name = "http";
              port =
                if config.frontend.servicePort or null != null then
                  config.frontend.servicePort
                else
                  config.frontend.port;
              targetPort = config.frontend.port;
              protocol = "TCP";
            }
          ];
        };
        outputs = {
          port = toString (
            if config.frontend.servicePort or null != null then
              config.frontend.servicePort
            else
              config.frontend.port
          );
        };
        requires = [ self.frontendDeployment ];
      }
    else
      null;
}

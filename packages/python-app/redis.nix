# redis.nix — build part: redis Deployment, Service.
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
  inherit (h) componentLabels selectorLabels;
in
{
  # ── Redis Deployment ────────────────────────────────────────────
  redisDeployment =
    if config.redis.enabled then
      {
        name = "${name}-redis";
        labels = componentLabels "redis";
        spec = {
          replicas = 1;
          strategy.type = "Recreate";
          selector.matchLabels = selectorLabels "redis";
          template = {
            metadata.labels = selectorLabels "redis";
            spec = {
              containers = [
                {
                  name = "redis";
                  image = "${config.redis.image.repository}:${config.redis.image.tag}";
                  ports = [
                    (kix.port "redis" 6379)
                  ];
                  resources = config.redis.resources;
                  volumeMounts = [
                    {
                      name = "data";
                      mountPath = "/data";
                    }
                  ];
                }
              ];
              volumes = [
                {
                  name = "data";
                  emptyDir = { };
                }
              ];
            };
          };
        };
      }
      |> scope.mkDeployment
    else
      null;

  # ── Redis Service ───────────────────────────────────────────────
  redisService =
    if config.redis.enabled then
      scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${name}-redis";
        labels = componentLabels "redis";
        spec = {
          type = "ClusterIP";
          selector = selectorLabels "redis";
          ports = [
            {
              name = "redis";
              port = 6379;
              targetPort = "redis";
              protocol = "TCP";
            }
          ];
        };
        outputs = {
          port = "6379";
        };
        requires = [ self.redisDeployment ];
      }
    else
      null;
}

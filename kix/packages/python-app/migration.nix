# migration.nix — build part: migration Job (pre-deploy hook).
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
    mkEnvFrom
    secretVolumeMounts
    secretVolumes
    ;
in
{
  # ── Migration Hook (Job) ────────────────────────────────────────
  migrateJob =
    if config.hooks.migrate.enabled then
      scope.mkResource {
        apiVersion = "batch/v1";
        kind = "Job";
        name = "${name}-migrate";
        labels = componentLabels "migrate";
        annotations = {
          ${kix.keys.hook} = "pre-deploy";
          ${kix.keys.hookDeletePolicy} = "before-hook-creation,hook-succeeded";
        };
        spec = {
          activeDeadlineSeconds = 3600;
          backoffLimit = 0;
          ttlSecondsAfterFinished = 28800;
          template = {
            metadata.labels = selectorLabels "migrate";
            spec = {
              restartPolicy = "Never";
              containers = [
                {
                  name = "migrate";
                  image = "${config.backend.image.repository}:${config.backend.image.tag}";
                  imagePullPolicy = config.backend.image.pullPolicy;
                  command = config.hooks.migrate.command;
                  envFrom = mkEnvFrom self self.configmap config.backend.secrets;
                  volumeMounts = secretVolumeMounts;
                }
              ];
              volumes = secretVolumes;
            };
          };
        };
      }
    else
      null;
}

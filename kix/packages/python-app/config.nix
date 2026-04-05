# config.nix — build part: ConfigMaps, Secrets, ServiceAccount.
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
  inherit (h) rName componentLabels depEnv;
in
{
  # ── ConfigMap (backend environment) ─────────────────────────────
  configmap =
    if config.useConfigMap then
      scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "${name}-environment";
        labels = componentLabels "config";
        data = {
          ENVIRONMENT = config.environment;
        }
        // depEnv
        // config.env;
      }
    else
      null;

  # ── ConfigMap (frontend environment) ────────────────────────────
  frontendConfigmap =
    if config.frontend.enabled && config.frontend.useConfigMap then
      scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "${name}-environment-frontend";
        labels = componentLabels "config-frontend";
        data = config.frontendEnv;
      }
    else
      null;

  # ── Secret (env vars) ──────────────────────────────────────────
  secret =
    if config.secretEnv != { } then
      scope.mkSecret {
        name = "${name}-secrets";
        labels = componentLabels "secrets";
        stringData = config.secretEnv;
      }
    else
      null;

  # ── Secret (file mounts) ───────────────────────────────────────
  secretFilesResource =
    if config.secretFiles != { } then
      scope.mkSecret {
        name = "${name}-secret-files";
        labels = componentLabels "secret-files";
        stringData = config.secretFiles;
      }
    else
      null;

  # ── ServiceAccount ───────────────────────────────────────────────
  serviceAccount =
    if config.serviceAccount.enabled then
      scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = if config.serviceAccount.name != null then config.serviceAccount.name else rName;
        labels = componentLabels "serviceaccount";
      }
    else
      null;
}

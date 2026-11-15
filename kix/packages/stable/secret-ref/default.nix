# Reference to an externally-managed secret (Vault, ESO, cert-manager, bootstrap).
#
# No manifest produced. Creates a store path for dependency tracking
# and exposes the same out API as packages/secret (keyRef, mkEnv,
# envFrom, volume) with build-time key validation.
#
# root = secret-ref (no deployable manifest).

{
  scope,
  lib,
}:

{
  meta = {
    description = "Reference to an externally-managed secret";
    owner = "platform";
    scope = "namespace";
    defaultAliases = [ "secret" ];
  };

  options = {
    keys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Declared secret keys (for build-time validation and access matrix).";
    };
    type = lib.mkOption {
      type = lib.types.str;
      default = "Opaque";
      description = "K8s secret type.";
    };
  };

  build =
    {
      self,
      config,
      ...
    }:
    let
      ref = scope.mkSecretRef {
        name = scope.instanceName;
        inherit (config) keys type;
      };
    in
    {
      inherit ref;
      root = self.ref;
    };
}

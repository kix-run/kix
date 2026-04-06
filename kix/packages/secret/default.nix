# Standalone secret instance — kix-managed (SOPS or inline).
#
# Creates a K8s Secret with the enriched out API (keyRef, mkEnv,
# envFrom, volume). Use as a first-class instance in the cluster
# definition for secrets that no package produces internally.
#
# root = Secret.

{
  scope,
  lib,
}:

{
  meta = {
    version = "1.0.0";
    description = "Standalone secret instance (kix-managed)";
    lifecycle = "stateful";
    scope = "namespace";
    provides = [ "secret" ];
    defaultAliases = [ "secret" ];
  };

  options = {
    keys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Declared secret keys. Derived from stringData if omitted.";
    };
    stringData = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Inline secret data (plaintext key-value pairs).";
    };
    source = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to SOPS-encrypted file. kix-deploy hydrates from this at apply time.";
    };
    hash = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Content hash of decrypted values (like fetchurl's sha256).";
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
      secret = scope.mkSecret {
        name = scope.instanceName;
        keys = if config.keys != [ ] then config.keys else null;
        inherit (config)
          stringData
          source
          hash
          type
          ;
      };
    in
    {
      root = secret;
    };
}

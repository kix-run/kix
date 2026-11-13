# Standalone secret instance: Kix-managed (SOPS or inline).
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
    owner = "platform";
    lifecycle = "stateful";
    scope = "namespace";
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
    # Refused, so a definition that still sets it gets an error that says
    # what to do instead of an unknown-option error.
    hash = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      visible = false;
      description = "Removed. Kix computes a digest of the SOPS file itself.";
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
      secret =
        if config.hash != null then
          scope.fail {
            id = "K4732";
            package = "secret";
            option = "config.hash";
            message = "`hash` was removed. Kix now computes a digest of the SOPS file itself.";
            fix = "Delete the `hash` line from the instance's config.";
          }
        else
          scope.mkSecret {
            name = scope.instanceName;
            keys = if config.keys != [ ] then config.keys else null;
            inherit (config)
              stringData
              source
              type
              ;
          };
    in
    {
      root = secret;
      # Also expose under a sibling key so cluster.nix's collectResources
      # (which drops the `root` key) sees the Secret. Without this, a
      # secret-as-root package emits only the PackageInstance marker, not
      # the Secret itself. Same store-path → dedup'd in the manifest writer.
      inherit secret;
    };
}

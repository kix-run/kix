# Standalone SGObjectStorage — S3-compatible backup destination for
# StackGres clusters.
#
# The `stackgres-cluster` package emits an SGObjectStorage when its
# `backup.enabled` is set. This package is for the *standalone* case:
# SGObjectStorages declared in `stackgres-system` (or another shared
# ns) and consumed by SGClusters in unrelated namespaces. Useful for
# multi-tenant clusters where the platform owns the S3 endpoint /
# region / credentials and tenants only need to reference the storage
# location by name on their SGClusters.
#
# Defaults target OVH eu-central (GRA). Override `region` / `endpoint`
# for AWS, Hetzner, etc. Credentials are read from an existing
# in-namespace Secret with two keys: `accesskey` and `secretkey`.

{
  scope,
  lib,
}:

{
  meta = {
    version = "1.0.0";
    description = "Standalone SGObjectStorage for cross-namespace backup targets";
  };

  options = {
    bucket = lib.mkOption {
      type = lib.types.str;
      description = "S3 bucket name; defaults to scope.instanceName.";
    };
    region = lib.mkOption {
      type = lib.types.str;
      default = "gra";
    };
    endpoint = lib.mkOption {
      type = lib.types.str;
      default = "https://s3.gra.io.cloud.ovh.net/";
    };
    enablePathStyleAddressing = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    credentialsSecretName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of an existing Secret in this namespace holding two keys:
        `accesskey` and `secretkey`.  Sourced from Infisical (or
        equivalent) via a separate InfisicalSecret instance.
      '';
    };
  };

  build =
    { self, config, ... }:
    let
      name = scope.instanceName;
    in
    {
      objectStorage = scope.mkResource {
        apiVersion = "stackgres.io/v1beta1";
        kind = "SGObjectStorage";
        inherit name;
        extra.spec = {
          type = "s3Compatible";
          s3Compatible = {
            bucket = config.bucket;
            inherit (config) region enablePathStyleAddressing endpoint;
            awsCredentials.secretKeySelectors = {
              accessKeyId = {
                key = "accesskey";
                name = config.credentialsSecretName;
              };
              secretAccessKey = {
                key = "secretkey";
                name = config.credentialsSecretName;
              };
            };
          };
        };
      };

      root = self.objectStorage // {
        out = (self.objectStorage.out or { }) // {
          inherit name;
        };
      };
    };
}

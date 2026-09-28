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
    owner = "platform";
  };

  options = {
    bucket = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of an existing S3 bucket that you own. Required: bucket names
        are global across all accounts of a provider, so no default can be
        assumed to be yours.
      '';
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
      bucket = config.bucket;
      # S3 bucket naming rules:
      # https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucketnamingrules.html
      bucketProblems =
        lib.optional (
          builtins.stringLength bucket < 3 || builtins.stringLength bucket > 63
        ) "is not 3 to 63 characters long"
        ++
          lib.optional (builtins.match "[a-z0-9][a-z0-9.-]*[a-z0-9]" bucket == null)
            "must use only lowercase letters, digits, dots and hyphens, and start and end with a letter or digit"
        ++ lib.optional (lib.hasInfix ".." bucket) "contains two adjacent dots"
        ++ lib.optional (
          builtins.match "[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+" bucket != null
        ) "is formatted as an IP address"
        ++ lib.optional (
          lib.hasPrefix "xn--" bucket || lib.hasPrefix "sthree-" bucket
        ) "starts with a reserved prefix (`xn--` or `sthree-`)"
        ++ lib.optional (lib.hasSuffix "-s3alias" bucket) "ends with the reserved suffix `-s3alias`";
    in
    assert
      bucketProblems == [ ]
      || throw "stackgres-object-storage '${name}': `bucket` \"${bucket}\" is not a valid S3 bucket name: it ${lib.concatStringsSep "; it " bucketProblems}. See https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucketnamingrules.html";
    {
      objectStorage = scope.mkResource {
        apiVersion = "stackgres.io/v1beta1";
        kind = "SGObjectStorage";
        inherit name;
        extra.spec = {
          type = "s3Compatible";
          s3Compatible = {
            inherit bucket;
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

      root = self.objectStorage;
    };
}

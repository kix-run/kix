# stackgres-object-storage: backup storage for StackGres clusters, as one
# SGObjectStorage.
#
# A stackgres-cluster in the same namespace with `backups` set takes this
# instance as its `sgObjectStorage` dependency. StackGres resolves an
# SGCluster's SGObjectStorage in the cluster's own namespace, so the
# package is namespace-scoped: an instance in another namespace does not
# resolve.
#
# Minimal instance, beside a Secret holding the credentials:
#
#   backup-credentials = {
#     package = packages.secret-ref;
#     aliases = [ "storageCredentials" ];
#     config.keys = [ "accessKeyId" "secretAccessKey" ];
#   };
#   backups = {
#     package = packages.stackgres-object-storage;
#     config = {
#       type = "s3Compatible";
#       bucket = "pg-backups";
#       extraSpec.s3Compatible = {
#         endpoint = "https://s3.example.com";
#         region = "example-1";
#         enablePathStyleAddressing = true;
#       };
#     };
#   };
#
# Dependencies:
#   stackgresOperator (required)   the operator whose SGObjectStorage kind
#                                  this instance uses.
#   storageCredentials (required)  the Secret the selectors name. The keys
#                                  it must declare depend on `type`; see
#                                  `credentialKeys`.
#   endpointService (optional)     an S3 store in the cluster, as an
#                                  instance whose root is its S3 Service.
#                                  `s3Compatible` only. The package sets the
#                                  endpoint to that Service's URL and turns
#                                  on path-style addressing, and the
#                                  clusters that back up here get network
#                                  policy to the store. No package has the
#                                  alias, so wire it with
#                                  deps.endpointService = ref.<ns>.<instance>.
#
# Credentials from a cloud metadata service or workload identity
# (`useIAMRole`, `fetchCredentialsFromMetadataService`) are not modelled:
# set them through `extraSpec`, and the package still writes the selectors.
#
# Escape hatch: `extraSpec`, merged over the SGObjectStorage spec. It reaches
# the endpoint, region, path-style addressing, storage class, and
# `encryption`. The type, the bucket, the credential selectors, and, with
# `endpointService`, the endpoint are locked. An endpoint written here is
# treated as outside the cluster.
#
# `out`:
#   out.name             the SGObjectStorage's name.
#   out.worldEgressPort  the TCP port backups reach outside the cluster: the
#                        endpoint's port, else 80 or 443 from its scheme,
#                        else 443. null with `endpointService`, whose
#                        address opens the in-cluster path.
#
# root = the SGObjectStorage.

{
  scope,
  lib,
  kix,
}:

let
  name = scope.instanceName;
  who = "stackgres-object-storage ${scope.namespaceName}/${name}";

  # The credentials block of each type and the selectors it takes
  # (crds/SGObjectStorage.yaml).
  types = {
    s3 = {
      block = "awsCredentials";
      selectors = [
        "accessKeyId"
        "secretAccessKey"
      ];
    };
    s3Compatible = {
      block = "awsCredentials";
      selectors = [
        "accessKeyId"
        "secretAccessKey"
      ];
    };
    gcs = {
      block = "gcpCredentials";
      selectors = [ "serviceAccountJSON" ];
    };
    azureBlob = {
      block = "azureCredentials";
      selectors = [
        "storageAccount"
        "accessKey"
      ];
    };
  };
  allSelectors = lib.unique (lib.concatMap (t: t.selectors) (builtins.attrValues types)) ++ [
    "caCertificate"
  ];

  # The selector -> Secret key map for this instance's type.
  selectorKeys =
    config:
    lib.genAttrs types.${config.type}.selectors (
      s: if config.credentialKeys.${s} != null then config.credentialKeys.${s} else s
    )
    // lib.optionalAttrs (config.credentialKeys.caCertificate != null) {
      caCertificate = config.credentialKeys.caCertificate;
    };

  # https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucketnamingrules.html
  bucketProblems =
    bucket:
    lib.optional (
      builtins.stringLength bucket < 3 || builtins.stringLength bucket > 63
    ) "is not 3 to 63 characters long"
    ++
      lib.optional (builtins.match "[a-z0-9][a-z0-9.-]*[a-z0-9]" bucket == null)
        "must use only lowercase letters, digits, dots, and hyphens, and start and end with a letter or digit"
    ++ lib.optional (lib.hasInfix ".." bucket) "contains two adjacent dots"
    ++ lib.optional (
      builtins.match "[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+" bucket != null
    ) "is formatted as an IP address"
    ++ lib.optional (
      lib.hasPrefix "xn--" bucket || lib.hasPrefix "sthree-" bucket
    ) "starts with a reserved prefix (`xn--` or `sthree-`)"
    ++ lib.optional (lib.hasSuffix "-s3alias" bucket) "ends with the reserved suffix `-s3alias`";
in
{
  meta = {
    description = "Backup storage for StackGres clusters (SGObjectStorage)";
    owner = "platform";
    # Not `objectStorage`: velero reads that alias with another contract.
    defaultAliases = [ "sgObjectStorage" ];
    scope = "namespace";
  };

  assertions =
    { config, ... }:
    let
      problems = bucketProblems config.bucket;
      foreign = builtins.filter (
        s:
        config.credentialKeys.${s} != null
        && !(builtins.elem s types.${config.type}.selectors)
        && !(s == "caCertificate" && config.type == "s3Compatible")
      ) allSelectors;
    in
    [
      {
        assertion = !(lib.hasPrefix "s3" config.type) || problems == [ ];
        message = "bucket \"${config.bucket}\" is not a valid S3 bucket name: it ${lib.concatStringsSep "; it " problems}. See https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucketnamingrules.html";
      }
      {
        assertion = foreign == [ ];
        message = "credentialKeys sets ${lib.concatStringsSep ", " foreign}, which type \"${config.type}\" does not read. Remove ${
          if builtins.length foreign == 1 then "it" else "them"
        }.";
      }
    ];

  # An imported operator carries no release to check.
  deps.stackgresOperator.assertions = dep: [
    {
      assertion = !(dep.out ? release) || lib.versions.majorMinor dep.out.release == "1.19";
      message = "this package writes the SGObjectStorage fields of StackGres 1.19, and the stackgresOperator dependency runs ${dep.out.release}. Update kix/packages/stable/stackgres-object-storage for that release.";
    }
  ];

  options = {
    type = lib.mkOption {
      type = lib.types.enum (builtins.attrNames types);
      description = "Storage service: `s3` (AWS S3), `s3Compatible` (any S3 API, with an endpoint in `extraSpec.s3Compatible.endpoint`), `gcs`, or `azureBlob`.";
    };
    bucket = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = ''
        An existing bucket (for `azureBlob`, a container) that you own. A
        prefix within it goes in the cluster's `backups[].path`.
      '';
    };
    credentialKeys = lib.mkOption {
      default = { };
      description = ''
        The key of the `storageCredentials` Secret behind each selector of
        `type`. A selector left null reads the key with its own name:
        `s3` and `s3Compatible` read `accessKeyId` and `secretAccessKey`,
        `gcs` reads `serviceAccountJSON`, and `azureBlob` reads
        `storageAccount` and `accessKey`. A key set for a selector the type
        does not read is refused.
      '';
      type = lib.types.submodule {
        options =
          lib.genAttrs allSelectors (
            s:
            lib.mkOption {
              type = lib.types.nullOr lib.types.nonEmptyStr;
              default = null;
              description = "Secret key for the `${s}` selector; null reads the key `${s}`.";
            }
          )
          // {
            caCertificate = lib.mkOption {
              type = lib.types.nullOr lib.types.nonEmptyStr;
              default = null;
              description = "`s3Compatible` only: the Secret key holding the CA certificate of an endpoint whose certificate a public CA did not issue. Null sets no CA.";
            };
          };
      };
    };
    extraSpec = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        s3Compatible = {
          endpoint = "https://s3.example.com";
          region = "example-1";
          enablePathStyleAddressing = true;
        };
      };
      description = "Merged over the SGObjectStorage spec. `type`, `<type>.bucket`, and the credential selectors the package writes are refused.";
    };
  };

  build =
    {
      self,
      config,
      stackgresOperator,
      storageCredentials,
      endpointService ? null,
      ...
    }:
    let
      t = types.${config.type};
      inCluster = endpointService != null;
      _inClusterType =
        if inCluster && config.type != "s3Compatible" then
          throw "${who}: deps.endpointService is wired, and type is \"${config.type}\". Only s3Compatible takes an endpoint; set type = \"s3Compatible\", or remove the dependency."
        else
          null;
      keys = selectorKeys config;
      creds = kix.checkSecretKeys {
        inherit who;
        arg = "storageCredentials";
        dep = storageCredentials;
        keys = builtins.attrValues keys;
      };

      base = {
        inherit (config) type;
        ${config.type} = {
          inherit (config) bucket;
          ${t.block}.secretKeySelectors = lib.mapAttrs (_: key: {
            name = creds.out.name;
            inherit key;
          }) keys;
        }
        // lib.optionalAttrs inCluster {
          endpoint =
            (endpointService.out.url
              or (throw "${who}: deps.endpointService has no out.url. Wire an instance whose root is its S3 Service.")
            )
              { };
          enablePathStyleAddressing = true;
        };
      };

      spec = kix.mergeGuarded {
        inherit who;
        locked = [
          [ "type" ]
          [
            config.type
            "bucket"
          ]
        ]
        ++ map (s: [
          config.type
          t.block
          "secretKeySelectors"
          s
        ]) (builtins.attrNames keys)
        ++ lib.optional inCluster [
          config.type
          "endpoint"
        ];
      } base config.extraSpec;

      endpoint = spec.${config.type}.endpoint or null;
      endpointParts = builtins.match "([a-zA-Z]+)://[^/:]+(:([0-9]+))?.*" endpoint;
      worldEgressPort =
        if inCluster then
          null
        else if endpoint == null then
          443
        else if endpointParts == null then
          throw "${who}: extraSpec.${config.type}.endpoint \"${endpoint}\" is not a URL such as https://s3.example.com."
        else if builtins.elemAt endpointParts 2 != null then
          lib.toInt (builtins.elemAt endpointParts 2)
        else if lib.toLower (builtins.head endpointParts) == "http" then
          80
        else
          443;
    in
    builtins.seq _inClusterType {
      objectStorage =
        scope.mkCR
          (stackgresOperator.out.crds.SGObjectStorage
            or (throw "${who}: the stackgresOperator dependency has no out.crds.SGObjectStorage. Wire a stackgres-operator instance, or an import that declares the SGObjectStorage CRD in its crds.")
          )
          {
            inherit name spec;
          };

      root = {
        resource = self.objectStorage;
        out = { inherit worldEgressPort; };
      };
    };
}

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
#     package = packages.experimental.stackgres-object-storage;
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
#   storageCredentials             the Secret the selectors name. The keys
#                                  it must declare depend on `type`; see
#                                  `credentialKeys`. Required unless the
#                                  pods use their own cloud credentials
#                                  (below), and refused when they do.
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
# Pod credentials: for `s3`, `extraSpec.s3.awsCredentials.useIAMRole =
# true`, and for `gcs`,
# `extraSpec.gcs.gcpCredentials.fetchCredentialsFromMetadataService = true`,
# make wal-g in each database pod use that pod's own cloud credentials.
# These are StackGres's own fields. The package then writes no selectors,
# takes no `storageCredentials`, and publishes the cloud in
# `out.ambientCloud`. StackGres has no such field for `s3Compatible` or
# `azureBlob`, so the package refuses one there. The pods run as the
# `<cluster>-patroni` ServiceAccount that the operator creates for each
# SGCluster, so the cloud identity goes on each stackgres-cluster instance
# (`deps.backupIdentity`), never on this one. Without an identity there,
# the pods use the node's credentials.
#
#   backups = {
#     package = packages.experimental.stackgres-object-storage;
#     config = {
#       type = "s3";
#       bucket = "pg-backups";
#       extraSpec.s3 = {
#         region = "eu-west-1";
#         awsCredentials.useIAMRole = true;
#       };
#     };
#   };
#
# Escape hatch: `extraSpec`, merged over the SGObjectStorage spec. It reaches
# the endpoint, region, path-style addressing, storage class, and
# `encryption`. The type, the bucket, the credential selectors, and, with
# `endpointService`, the endpoint are locked. An endpoint written here is
# treated as outside the cluster.
#
# `out`:
#   out.name             the SGObjectStorage's name.
#   out.ambientCloud     "aws" or "gcp" when the pods use their own cloud
#                        credentials, null when they read the Secret.
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

  # The credentials block of each type and the selectors it takes, and,
  # for a type that has one, the field of that block that makes wal-g use
  # the pod's own credentials and the cloud they come from
  # (crds/SGObjectStorage.yaml).
  types = {
    s3 = {
      block = "awsCredentials";
      selectors = [
        "accessKeyId"
        "secretAccessKey"
      ];
      ambient = {
        field = "useIAMRole";
        cloud = "aws";
      };
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
      ambient = {
        field = "fetchCredentialsFromMetadataService";
        cloud = "gcp";
      };
    };
    azureBlob = {
      block = "azureCredentials";
      selectors = [
        "storageAccount"
        "accessKey"
      ];
    };
  };
  ambientFields = map (t: t.ambient.field) (
    builtins.filter (t: t ? ambient) (builtins.attrValues types)
  );

  # The ambient-credential fields that `extraSpec` sets to true in the
  # credentials block of `config.type`.
  ambientSet =
    config:
    let
      block = config.extraSpec.${config.type}.${types.${config.type}.block} or { };
    in
    builtins.filter (f: (block.${f} or false) == true) ambientFields;

  # The cloud whose credentials the pods use, or null when they read the
  # Secret.
  ambientCloudOf =
    config:
    let
      t = types.${config.type};
    in
    if t ? ambient && builtins.elem t.ambient.field (ambientSet config) then t.ambient.cloud else null;

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
    { config, deps, ... }:
    let
      problems = bucketProblems config.bucket;
      t = types.${config.type};
      block = "extraSpec.${config.type}.${t.block}";
      ambient = ambientCloudOf config != null;
      credentialsGiven = (deps.storageCredentials or null) != null;
      unsupported = builtins.filter (f: !(t ? ambient) || f != t.ambient.field) (ambientSet config);
      keysSet = builtins.filter (s: config.credentialKeys.${s} != null) allSelectors;
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
      {
        assertion = unsupported == [ ];
        id = "K5962";
        option = "extraSpec";
        message = "`${block}` sets ${
          lib.concatMapStringsSep " and " (f: "`${f} = true`") unsupported
        }, which StackGres does not support here. StackGres supports pod credentials only on `s3` (`useIAMRole`) and `gcs` (`fetchCredentialsFromMetadataService`), so Kix rejected this instance.";
        fix =
          if t ? ambient then
            "Replace that setting with `${block}.${t.ambient.field} = true` to use pod credentials for `type = \"${config.type}\"`, or remove it and pass a Secret in `deps.storageCredentials`."
          else
            "Remove that setting from `extraSpec` and pass a Secret in `deps.storageCredentials`, or change `type` to `\"s3\"` (`useIAMRole = true`) or `\"gcs\"` (`fetchCredentialsFromMetadataService = true`).";
      }
      {
        assertion = !(ambient && credentialsGiven);
        id = "K5962";
        dependency = "storageCredentials";
        message = "`${block}.${t.ambient.field or ""}` is `true`, which tells the database pods to use their own cloud credentials, while `storageCredentials` is also bound. StackGres uses only one credential source, so Kix rejected this instance.";
        fix = "To use pod credentials, remove `deps.storageCredentials` (or remove the `storageCredentials` alias from the Secret instance in this namespace), and set `deps.backupIdentity` on each `stackgres-cluster` instance unless the pods use node credentials. To use the Secret instead, remove `${t.ambient.field or ""}` from `extraSpec`.";
      }
      {
        assertion = ambient || credentialsGiven;
        dependency = "storageCredentials";
        message = "No storage credentials are configured: `deps.storageCredentials` is unset${
          lib.optionalString (t ? ambient) ", and `${block}.${t.ambient.field}` is not `true`"
        }, so Kix rejected this instance.";
        fix =
          "Pass a Secret instance in `deps.storageCredentials`"
          +
            lib.optionalString (t ? ambient)
              ", or set `${block}.${t.ambient.field} = true` to use the database pods' cloud credentials (with `deps.backupIdentity` on each `stackgres-cluster` instance, or node credentials)"
          + ".";
      }
      {
        assertion = !ambient || keysSet == [ ];
        option = "credentialKeys";
        message = "`credentialKeys` sets ${
          lib.concatMapStringsSep ", " (k: "`${k}`") keysSet
        }, which maps keys in a `storageCredentials` Secret, but `${block}.${t.ambient.field or ""}` is `true` so this instance uses pod credentials instead of a Secret. Kix rejected this instance.";
        fix = "Remove `credentialKeys` to use pod credentials, or remove `${t.ambient.field or ""}` from `extraSpec` and pass a Secret in `deps.storageCredentials`.";
      }
    ];

  # An imported operator carries no release to check.
  deps.stackgresOperator.assertions = dep: [
    {
      assertion = !(dep.out ? release) || lib.versions.majorMinor dep.out.release == "1.19";
      message = "this package writes the SGObjectStorage fields of StackGres 1.19, and the stackgresOperator dependency runs ${dep.out.release}. Update kix/packages/experimental/stackgres-object-storage for that release.";
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
      storageCredentials ? null,
      endpointService ? null,
      ...
    }:
    let
      t = types.${config.type};
      ambientCloud = ambientCloudOf config;
      ambient = ambientCloud != null;
      inCluster = endpointService != null;
      _inClusterType =
        if inCluster && config.type != "s3Compatible" then
          scope.fail {
            dependency = "endpointService";
            message = "deps.endpointService is wired, and type is \"${config.type}\". Only s3Compatible takes an endpoint.";
            fix = "Set type = \"s3Compatible\", or remove the dependency.";
          }
        else
          null;
      keys = selectorKeys config;
      # A cloud identity belongs on the instances whose pods make the call.
      storage = kix.cloudIdentity.use {
        inherit scope;
        dep = storageCredentials;
        cloud = null;
        identityGoesTo = "`deps.backupIdentity` on each `stackgres-cluster` instance that backs up here, and set `${
          t.ambient.field or "useIAMRole"
        } = true` in `extraSpec.${config.type}.${t.block}`";
      };
      creds = kix.contracts.secret.helpers.use {
        inherit scope;
        arg = "storageCredentials";
        dep = storage.secret;
        keys = builtins.attrValues keys;
      };

      base = {
        inherit (config) type;
        ${config.type} = {
          inherit (config) bucket;
        }
        # Without a Secret or the ambient field, an assertion refuses the
        # instance.
        // lib.optionalAttrs (!ambient && storage.secret != null) {
          ${t.block}.secretKeySelectors = lib.mapAttrs (_: key: {
            name = creds.out.name;
            inherit key;
          }) keys;
        }
        // lib.optionalAttrs inCluster {
          endpoint =
            (endpointService.out.url or (scope.fail {
              dependency = "endpointService";
              message = "deps.endpointService has no out.url.";
              fix = "Wire an instance whose root is its S3 Service.";
            })
            )
              { };
          enablePathStyleAddressing = true;
        };
      };

      spec = kix.mergeGuarded {
        inherit scope;
        locked = [
          [ "type" ]
          [
            config.type
            "bucket"
          ]
        ]
        # With the ambient field, StackGres requires gcs to omit the
        # selectors and ignores them for s3.
        ++ (
          if ambient then
            [
              [
                config.type
                t.block
                "secretKeySelectors"
              ]
            ]
          else
            map (s: [
              config.type
              t.block
              "secretKeySelectors"
              s
            ]) (builtins.attrNames keys)
        )
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
          scope.fail {
            option = "extraSpec.${config.type}.endpoint";
            message = "extraSpec.${config.type}.endpoint \"${endpoint}\" is not a URL such as https://s3.example.com.";
          }
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
          (stackgresOperator.out.crds.SGObjectStorage or (scope.fail {
            message = "the stackgresOperator dependency has no out.crds.SGObjectStorage.";
            fix = "Wire a stackgres-operator instance, or an import that declares the SGObjectStorage CRD in its crds.";
          })
          )
          {
            inherit name spec;
          };

      root = {
        resource = self.objectStorage;
        out = { inherit worldEgressPort ambientCloud; };
      };
    };
}

# external-secret: one ExternalSecret for the External Secrets Operator,
# and the Secret it writes as a secret dependency.
#
# The package renders an ExternalSecret named after the instance, through
# the operator's `out.mkExternalSecret`. The controller reads each declared
# key from one SecretStore or ClusterSecretStore and writes them into a
# Secret of the same name in the instance's namespace. A package that takes
# a secret dependency (grafana's `grafanaAdmin`, a database's credentials)
# can take an instance of this package in place of `secret` or
# `secret-ref`.
#
# Dependencies:
#   externalSecrets (required)  the external-secrets operator instance. It
#                               builds the ExternalSecret and gates it on
#                               the operator's webhook.
#
# Minimal instance, in a namespace whose `vault` SecretStore reads
# HashiCorp Vault:
#
#   instances.app.grafana-admin = {
#     package = packages.experimental.external-secret;
#     aliases = [ "grafanaAdmin" ];
#     config = {
#       store.name = "vault";
#       keys = {
#         admin-user = { key = "grafana"; property = "user"; };
#         admin-password = { key = "grafana"; property = "password"; };
#       };
#     };
#   };
#
# `keys` maps each key of the Secret to where the store holds it. A string
# is the remote key. An attrset gives `key`, and optionally `property` (a
# field inside the remote secret) and `version`. The names of `keys` are the
# Secret's declared keys, so a consumer's `keyRef` of any other key fails
# the build.
#
# The ExternalSecret uses creationPolicy Owner: the controller sets an
# owner reference on the Secret, so deleting the ExternalSecret deletes the
# Secret. The data stays in the store.
#
# `out`, on the root:
#   out.name, out.keys, out.type, out.keyRef, out.mkEnv, out.envFrom,
#   out.volume
#       The same Secret reference as `secret-ref`, for the Secret the
#       ExternalSecret writes. Every resource that reads it requires the
#       ExternalSecret, and the deploy waits for its Ready condition, so the
#       first sync has written the Secret before a consumer starts.
#
# root = the Secret reference.
#
# Limits:
#   - One store per instance. Keys from two stores need two instances.
#   - No `dataFrom` (find by name or tag, extract a whole remote secret, or
#     generators) and no template data, so every Secret key maps to one
#     remote value as stored. Other ExternalSecret fields, such as
#     `spec.target.deletionPolicy` and a remote reference's
#     `conversionStrategy`, `decodingStrategy`, and `metadataPolicy`, keep
#     the controller's defaults. Build such an ExternalSecret in a package
#     with `externalSecrets.out.mkExternalSecret`.
#   - The store is named by a string. Kix does not order the ExternalSecret
#     after the store or check that the store exists. A missing store leaves
#     the ExternalSecret not Ready, and the deploy waits for it until it
#     times out.
#   - A value that changes in the store reaches the Secret at the next
#     refresh. Pods that read it through environment variables keep the old
#     value until they restart.

{
  scope,
  lib,
}:

let
  inherit (lib) types mkOption;

  remoteRef = types.submodule {
    options = {
      key = mkOption {
        type = types.nonEmptyStr;
        description = "Key of the secret in the external store.";
      };
      property = mkOption {
        type = types.nullOr types.nonEmptyStr;
        default = null;
        description = "Field inside the remote secret, for stores that keep several values under one key. Null reads the whole value.";
      };
      version = mkOption {
        type = types.nullOr types.nonEmptyStr;
        default = null;
        description = "Version of the remote secret. Null reads the current version.";
      };
    };
  };

  # The ExternalSecret's `remoteRef` for one entry of `keys`.
  remoteRefOf =
    ref: if builtins.isString ref then { key = ref; } else lib.filterAttrs (_: v: v != null) ref;

  # Secret data keys, as the API server validates them.
  validKey = k: builtins.match "[-._a-zA-Z0-9]+" k != null;
in
{
  meta = {
    description = "One External Secrets Operator ExternalSecret, consumed as a secret dependency";
    owner = "platform";
    # Consumers read the Secret through secretKeyRef, which cannot cross
    # namespaces.
    scope = "namespace";
    defaultAliases = [ "secret" ];
  };

  assertions =
    { config, ... }:
    let
      invalid = builtins.filter (k: !(validKey k)) (builtins.attrNames config.keys);
    in
    [
      {
        assertion = config.keys != { };
        message = "keys is empty, so the ExternalSecret would write a Secret with no keys. Map at least one Secret key to a remote key, such as keys.password = \"app/db-password\".";
      }
      {
        assertion = invalid == [ ];
        message = "keys names ${
          lib.concatMapStringsSep ", " (k: "\"${k}\"") invalid
        }, which the API server refuses as a Secret key. Use only letters, digits, \"-\", \"_\", and \".\".";
      }
    ];

  options = {
    store = {
      name = mkOption {
        type = types.nonEmptyStr;
        example = "vault";
        description = "Name of the SecretStore or ClusterSecretStore the ExternalSecret reads from. A SecretStore must be in the instance's namespace.";
      };
      kind = mkOption {
        type = types.enum [
          "SecretStore"
          "ClusterSecretStore"
        ];
        default = "SecretStore";
        description = "Kind of the store.";
      };
    };
    refreshInterval = mkOption {
      # Go's time.ParseDuration, which the CRD's metav1.Duration uses.
      type = types.strMatching "([0-9]+(\\.[0-9]+)?(ns|us|µs|ms|s|m|h))+|0";
      default = "1h";
      example = "15m";
      description = "How often the controller reads the store again and updates the Secret. \"0\" reads it once.";
    };
    type = mkOption {
      type = types.nonEmptyStr;
      default = "Opaque";
      example = "kubernetes.io/basic-auth";
      description = "Type of the Secret the ExternalSecret writes.";
    };
    keys = mkOption {
      type = types.attrsOf (types.either types.nonEmptyStr remoteRef);
      example = lib.literalExpression ''
        {
          username = "app/db-user";
          password = { key = "app/db"; property = "password"; };
        }
      '';
      description = "Secret keys, each mapped to its place in the store: a string is the remote key, an attrset gives key, property, and version. The names are the Secret's declared keys.";
    };
  };

  build =
    {
      self,
      config,
      externalSecrets,
      ...
    }:
    let
      operatorOut = externalSecrets.out or { };
    in
    {
      externalSecret =
        if !(operatorOut ? mkExternalSecret) then
          scope.fail {
            package = "external-secret";
            message = "the externalSecrets dependency has no out.mkExternalSecret, so it is not an external-secrets instance.";
            fix = "Wire packages.experimental.external-secrets as externalSecrets.";
          }
        else
          operatorOut.mkExternalSecret scope {
            name = scope.instanceName;
            spec = {
              secretStoreRef = {
                inherit (config.store) name kind;
              };
              inherit (config) refreshInterval;
              target.template.type = config.type;
              data = lib.mapAttrsToList (secretKey: ref: {
                inherit secretKey;
                remoteRef = remoteRefOf ref;
              }) config.keys;
            };
          };
      secretRef = self.externalSecret.out.secretRef { keys = builtins.attrNames config.keys; };
      root = self.secretRef;
    };
}

# Tests for kix/packages/experimental/external-secret: the rendered
# ExternalSecret, a consumer reading it as a secret dependency, and the
# refusals. The operator runs in namespace `external-secrets`, the
# instances and the consumer in `app`.

{
  lib,
  k8s,
  eval,
  kixKeys,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  containerBase,
  ...
}:

let
  operatorPackage = import ../../../packages/experimental/external-secrets;
  externalSecretPackage = import ../../../packages/experimental/external-secret;

  # A Deployment that reads `key` of its `apiCredentials` dependency into
  # an environment variable.
  mkConsumer = key: {
    meta = {
      version = "test";
      description = "Secret dependency consumer";
      owner = "test";
    };
    build =
      {
        self,
        scope,
        apiCredentials,
        ...
      }:
      {
        deployment = scope.mkDeployment {
          name = "web";
          spec = {
            replicas = 1;
            selector.matchLabels = scope.selectorLabels;
            template = {
              metadata.labels = scope.selectorLabels;
              spec.containers = [
                (
                  {
                    name = "web";
                    image = "web:1";
                    env = [
                      {
                        name = "API_KEY";
                        valueFrom = (apiCredentials.out.keyRef key).valueFrom;
                      }
                    ];
                  }
                  // containerBase
                )
              ];
            };
          };
        };
        root = self.deployment;
      };
  };

  apiConfig = {
    store.name = "vault";
    keys = {
      API_KEY = "billing/api-key";
      DB_PASSWORD = {
        key = "billing/db";
        property = "password";
        version = "3";
      };
    };
  };

  clusterWith =
    {
      api ? apiConfig,
      consumerKey ? "API_KEY",
      operator ? {
        package = operatorPackage;
      },
    }:
    mkCluster [
      {
        instances.external-secrets.external-secrets = operator;
        instances.app = {
          api = {
            package = externalSecretPackage;
            aliases = [ "apiCredentials" ];
            config = api;
          };
          login = {
            package = externalSecretPackage;
            config = {
              store = {
                name = "shared";
                kind = "ClusterSecretStore";
              };
              refreshInterval = "0";
              type = "kubernetes.io/basic-auth";
              keys = {
                username = "login/user";
                password = "login/password";
              };
            };
          };
        }
        // lib.optionalAttrs (consumerKey != null) {
          consumer.package = mkConsumer consumerKey;
        };
      }
    ];

  cluster = clusterWith { };
  ms = manifests cluster;
  find = kind: name: byName name (ofKind kind ms);
  hashOf =
    nsName: inst: part:
    builtins.unsafeDiscardStringContext
      cluster.instances.${nsName}.${inst}.raw.${part}.out.identityHash;
  dependsOn = m: lib.splitString "," ((m.metadata.annotations or { }).${kixKeys.dependsOn} or "");

  # The package's assertions read only `config` and `lib`.
  failedAssertions =
    config:
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (
        (externalSecretPackage {
          inherit lib;
          scope = { };
        }).assertions
          { inherit config; }
      )
    );
in
{
  # A string is the remote key; an attrset keeps property and version. The
  # type lands in the template, beside the metadata the operator pins.
  external-secret-spec =
    let
      spec = (find "ExternalSecret" "api").spec;
      expected = {
        secretStoreRef = {
          name = "vault";
          kind = "SecretStore";
        };
        refreshInterval = "1h";
        target.template = {
          metadata = { };
          type = "Opaque";
        };
        data = [
          {
            secretKey = "API_KEY";
            remoteRef.key = "billing/api-key";
          }
          {
            secretKey = "DB_PASSWORD";
            remoteRef = {
              key = "billing/db";
              property = "password";
              version = "3";
            };
          }
        ];
      };
    in
    spec == expected || throw "external-secret spec: ${builtins.toJSON spec}";

  # The store kind, refresh interval, and Secret type options.
  external-secret-store-and-type =
    let
      spec = (find "ExternalSecret" "login").spec;
    in
    (
      spec.secretStoreRef == {
        name = "shared";
        kind = "ClusterSecretStore";
      }
      && spec.refreshInterval == "0"
      && spec.target.template.type == "kubernetes.io/basic-auth"
      &&
        map (d: d.secretKey) spec.data == [
          "password"
          "username"
        ]
    )
    || throw "external-secret store and type: ${builtins.toJSON spec}";

  # The consumer's keyRef names the Secret the ExternalSecret writes, and
  # the consumer waits for the Secret reference, which requires the
  # ExternalSecret.
  external-secret-consumer-keyref =
    let
      deployment = find "Deployment" "web";
      env = builtins.head (builtins.head deployment.spec.template.spec.containers).env;
      marker = find "PackageInstance" "secret-ref-api-api";
      markerHash = k8s.extractStoreHash cluster.instances.app.api.raw.secretRef.outPath;
    in
    (
      env.valueFrom.secretKeyRef == {
        name = "api";
        key = "API_KEY";
      }
      && marker != null
      && builtins.elem "requires:${hashOf "app" "api" "externalSecret"}" (dependsOn marker)
      && builtins.elem markerHash (dependsOn deployment)
    )
    || throw "external-secret consumer: env ${builtins.toJSON env}, marker ${
      builtins.toJSON (marker.metadata or null)
    }, deployment ${builtins.toJSON deployment.metadata}";

  # The assertion messages, read from the package's assertions function.
  external-secret-assertion-text =
    let
      empty = failedAssertions { keys = { }; };
      badKey = failedAssertions { keys."a/b" = "x"; };
    in
    (
      builtins.length empty == 1
      && lib.hasPrefix "keys is empty" (builtins.head empty)
      && builtins.length badKey == 1
      && lib.hasInfix "\"a/b\"" (builtins.head badKey)
      && failedAssertions { inherit (apiConfig) keys; } == [ ]
    )
    || throw "external-secret assertions: ${builtins.toJSON { inherit empty badKey; }}";

  # Each refusal fails the build, and its positive control builds.
  external-secret-refusals =
    let
      cases = {
        # Without the consumer, whose keyRef would fail on its own.
        emptyKeys = {
          bad = clusterWith {
            api = apiConfig // {
              keys = { };
            };
            consumerKey = null;
          };
          good = clusterWith { consumerKey = null; };
        };
        invalidKeyName = {
          bad = clusterWith {
            api = apiConfig // {
              keys = apiConfig.keys // {
                "api/key" = "billing/api-key";
              };
            };
          };
          good = clusterWith {
            api = apiConfig // {
              keys = apiConfig.keys // {
                "api.key_1-x" = "billing/api-key";
              };
            };
          };
        };
        undeclaredKey = {
          bad = clusterWith { consumerKey = "OTHER"; };
          good = clusterWith { consumerKey = "DB_PASSWORD"; };
        };
        # An import has no out.mkExternalSecret.
        importedOperator = {
          bad = clusterWith {
            operator = {
              package = eval.mkImport { };
              aliases = [ "externalSecrets" ];
            };
          };
          good = cluster;
        };
        refreshInterval = {
          bad = clusterWith {
            api = apiConfig // {
              refreshInterval = "1 hour";
            };
          };
          good = clusterWith {
            api = apiConfig // {
              refreshInterval = "1h30m";
            };
          };
        };
      };
      wrong = builtins.attrNames (lib.filterAttrs (_: c: !(evalFails c.bad) || evalFails c.good) cases);
    in
    wrong == [ ]
    || throw "external-secret refusals: bad case built or good case failed: ${builtins.toJSON wrong}";
}

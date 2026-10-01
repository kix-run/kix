# Tests for kix/packages/infisical-operator: the custom resource builders,
# readiness, ordering, metrics gating, address handling and refusals. The
# operator and a consumer both run in namespace `infisical`.

{
  lib,
  kixKeys,
  mkCluster,
  netpolOn,
  manifests,
  ofKind,
  byName,
  evalFails,
  ...
}:

let
  operatorPackage = import ../../../packages/infisical-operator;

  # The package header's consumer pattern, plus an InfisicalSecret and an
  # InfisicalPushSecret built from out.crds. `extraParts` adds parts for
  # the refusal cases.
  mkConsumer =
    {
      extraParts ? _: { },
    }:
    {
      meta = {
        version = "test";
        description = "Infisical consumer";
        owner = "test";
      };
      build =
        {
          self,
          scope,
          infisicalOperator,
          ...
        }:
        let
          identityRef = key: {
            inherit ((self.identity.out.keyRef key).valueFrom.secretKeyRef) name key;
            namespace = scope.namespaceName;
          };
        in
        {
          identity = scope.mkSecretRef {
            name = "infisical-identity";
            keys = [
              "clientId"
              "clientSecret"
            ];
          };
          auth = infisicalOperator.out.mkInfisicalAuth scope {
            name = "billing";
            spec = {
              method = "universal";
              universal = {
                clientIdRef = identityRef "clientId";
                clientSecretRef = identityRef "clientSecret";
              };
            };
          };
          sync = infisicalOperator.out.mkInfisicalStaticSecret scope {
            name = "billing";
            spec = {
              infisicalAuthRef = {
                name = self.auth.out.name;
                namespace = scope.namespaceName;
              };
              syncOptions.refreshInterval = "1m";
              sources = [
                {
                  projectId = "project";
                  environmentSlug = "prod";
                  secretPath = "/";
                }
              ];
              targets = [
                {
                  name = "billing";
                  kind = "Secret";
                  creationPolicy = "Owner";
                }
                {
                  name = "billing-config";
                  kind = "ConfigMap";
                  creationPolicy = "Owner";
                  metadata.labels.team = "billing";
                }
              ];
            };
          };
          credentials = self.sync.out.secretRef { keys = [ "API_KEY" ]; };
          legacy = infisicalOperator.out.mkInfisicalSecret scope {
            name = "legacy";
            spec = {
              authentication.universalAuth = {
                credentialsRef = {
                  secretName = "infisical-identity";
                  secretNamespace = scope.namespaceName;
                };
                secretsScope = {
                  envSlug = "prod";
                  secretsPath = "/";
                };
              };
              managedKubeSecretReferences = [
                {
                  secretName = "legacy";
                  creationPolicy = "Owner";
                }
              ];
            };
          };
          legacyCredentials = self.legacy.out.secretRef { keys = [ "TOKEN" ]; };
          push = scope.mkCR infisicalOperator.out.crds.InfisicalPushSecret {
            name = "push";
            spec = {
              destination = {
                projectId = "project";
                environmentSlug = "prod";
                secretsPath = "/";
              };
              push.secret = {
                secretName = "legacy";
                secretNamespace = scope.namespaceName;
              };
            };
          };
          root = {
            resource = self.sync;
            requires = [
              self.credentials
              self.legacy
              self.legacyCredentials
              self.push
            ];
          };
        }
        // extraParts {
          inherit self scope infisicalOperator;
        };
    };

  # A prometheus provider whose ServiceMonitor builder renders the
  # arguments as a ServiceMonitor.
  prometheusStub = {
    meta = {
      version = "test";
      defaultAliases = [ "prometheus" ];
    };
    build =
      { self, scope, ... }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "prometheus";
        };
        root = {
          resource = self.cm;
          out.mkServiceMonitor =
            consumerScope: args:
            consumerScope.mkResource (
              args
              // {
                apiVersion = "monitoring.coreos.com/v1";
                kind = "ServiceMonitor";
              }
            );
        };
      };
  };

  clusterWith =
    {
      config ? { },
      consumer ? mkConsumer { },
      modules ? [ ],
    }:
    mkCluster (
      [
        {
          instances.infisical.infisical-operator = {
            package = operatorPackage;
            inherit config;
          };
          instances.infisical.consumer.package = consumer;
        }
      ]
      ++ modules
    );

  cluster = clusterWith { };
  ms = manifests cluster;
  find = kind: name: byName name (ofKind kind ms);
  hashOf =
    inst: part:
    builtins.unsafeDiscardStringContext
      cluster.instances.infisical.${inst}.raw.${part}.out.identityHash;
  dependsOn = m: lib.splitString "," ((m.metadata.annotations or { }).${kixKeys.dependsOn} or "");
  readinessOf = m: (m.metadata.annotations or { }).${kixKeys.readiness} or null;
  envOf =
    c:
    builtins.listToAttrs (
      map (e: lib.nameValuePair e.name e.value)
        (builtins.head (byName "infisical-operator" (ofKind "Deployment" (manifests c)))
          .spec.template.spec.containers).env
    );
in
{
  # Every target gets explicit metadata and a namespace; a v1alpha1
  # reference without a template gets every key and empty metadata.
  infisical-operator-pinning =
    let
      targets = (find "InfisicalStaticSecret" "billing").spec.targets;
      secretTarget = builtins.elemAt targets 0;
      configTarget = builtins.elemAt targets 1;
      legacyRef = builtins.head (find "InfisicalSecret" "legacy").spec.managedKubeSecretReferences;
    in
    (
      secretTarget.metadata == {
        annotations = { };
        labels = { };
      }
      && secretTarget.namespace == "infisical"
      &&
        configTarget.metadata == {
          annotations = { };
          labels.team = "billing";
        }
      && legacyRef.secretNamespace == "infisical"
      &&
        legacyRef.template == {
          includeAllSecrets = true;
          metadata = { };
        }
    )
    || throw "infisical-operator pinning: targets ${builtins.toJSON targets}, legacy ${builtins.toJSON legacyRef}";

  # The readiness each kind's controller reports on success, stamped on the
  # builders' custom resources, the one built from out.crds, and the
  # default connection.
  infisical-operator-readiness =
    let
      cond =
        type: status:
        builtins.toJSON {
          condition = {
            inherit status;
            type = "secrets.infisical.com/${type}";
          };
        };
      got = {
        static = readinessOf (find "InfisicalStaticSecret" "billing");
        legacy = readinessOf (find "InfisicalSecret" "legacy");
        auth = readinessOf (find "InfisicalAuth" "billing");
        push = readinessOf (find "InfisicalPushSecret" "push");
        connection = readinessOf (find "InfisicalConnection" "default");
      };
    in
    got == {
      static = cond "LastReconcileStatus" "True";
      legacy = cond "ReadyToSyncSecrets" "True";
      auth = cond "IsReady" "True";
      push = cond "Reconcile" "False";
      connection = cond "IsReady" "True";
    }
    || throw "infisical-operator readiness: ${builtins.toJSON got}";

  # The auth names the default connection and depends on it; the Secret
  # builders require it; each secretRef marker requires its custom
  # resource; the consumer raises no warnings.
  infisical-operator-edges =
    let
      connection = hashOf "infisical-operator" "connection";
      auth = find "InfisicalAuth" "billing";
      marker = name: find "PackageInstance" "secret-ref-consumer-${name}";
      warnings = cluster.instances.infisical.consumer._diagnostics.warnings;
    in
    (
      auth.spec.infisicalConnectionRef == {
        name = "default";
        namespace = "infisical";
      }
      && builtins.elem connection (dependsOn auth)
      && builtins.elem "requires:${connection}" (dependsOn (find "InfisicalStaticSecret" "billing"))
      && builtins.elem "requires:${connection}" (dependsOn (find "InfisicalSecret" "legacy"))
      && builtins.elem "requires:${hashOf "consumer" "sync"}" (dependsOn (marker "billing"))
      && builtins.elem "requires:${hashOf "consumer" "legacy"}" (dependsOn (marker "legacy"))
      && warnings == [ ]
    )
    || throw "infisical-operator edges: connection ${connection}, sync ${hashOf "consumer" "sync"}, legacy ${hashOf "consumer" "legacy"}, auth ${builtins.toJSON auth.metadata}, markers ${
      builtins.toJSON [
        (marker "billing").metadata
        (marker "legacy").metadata
      ]
    }, warnings ${builtins.toJSON warnings}";

  # InfisicalSecret and InfisicalStaticSecret have no handle: a custom
  # resource built from one would skip the metadata pinning.
  infisical-operator-out-crds =
    let
      names = builtins.attrNames cluster.instances.infisical.infisical-operator.raw.root.out.crds;
    in
    names == [
      "ClusterGenerator"
      "InfisicalAuth"
      "InfisicalConnection"
      "InfisicalPushSecret"
    ]
    || throw "infisical-operator out.crds: ${builtins.toJSON names}";

  # A trailing "/" and "/api" are removed, as the operator does, and
  # "/api" is appended for INFISICAL_HOST_API.
  infisical-operator-address =
    let
      c = clusterWith { config.address = "https://x/api/"; };
      connection = byName "default" (ofKind "InfisicalConnection" (manifests c));
      env = envOf c;
    in
    (connection.spec.address == "https://x" && env.INFISICAL_HOST_API == "https://x/api")
    || throw "infisical-operator address: connection ${builtins.toJSON connection.spec}, env ${builtins.toJSON env}";

  # The metrics Service and ServiceMonitor render only with a prometheus
  # provider and metrics.enabled.
  infisical-operator-metrics =
    let
      withPrometheus =
        config:
        clusterWith {
          inherit config;
          modules = [ { instances.monitoring.prometheus.package = prometheusStub; } ];
        };
      on = manifests (withPrometheus { });
      off = manifests (withPrometheus {
        metrics.enabled = false;
      });
      service = byName "infisical-operator-metrics" (ofKind "Service" on);
      ports = map (p: p.port) service.spec.ports;
    in
    (
      ports == [ 8080 ]
      && byName "infisical-operator" (ofKind "ServiceMonitor" on) != null
      && ofKind "Service" ms == [ ]
      && ofKind "Service" off == [ ]
      && ofKind "ServiceMonitor" off == [ ]
    )
    || throw "infisical-operator metrics: service ${builtins.toJSON service}";

  # Under egress enforcement an address the package's intent does not cover
  # fails the build; the default address builds.
  infisical-operator-egress =
    let
      enforced =
        config:
        clusterWith {
          inherit config;
          modules = [ netpolOn ];
        };
    in
    (
      evalFails (enforced {
        address = "http://infisical.example:8080";
      })
      && evalFails (enforced {
        address = "https://infisical.infisical.svc";
      })
      && !(evalFails (enforced { }))
    )
    || throw "infisical-operator egress: the egress check accepted or refused the wrong address";

  infisical-operator-refusals =
    let
      withParts = extraParts: clusterWith { consumer = mkConsumer { inherit extraParts; }; };
      legacySpec = scope: {
        authentication.universalAuth = {
          credentialsRef = {
            secretName = "infisical-identity";
            secretNamespace = scope.namespaceName;
          };
          secretsScope = {
            envSlug = "prod";
            secretsPath = "/";
          };
        };
      };
      cases = {
        managedSecretReference = withParts (
          { scope, infisicalOperator, ... }:
          {
            old = infisicalOperator.out.mkInfisicalSecret scope {
              name = "old";
              spec = legacySpec scope // {
                managedSecretReference.secretName = "old";
                managedKubeSecretReferences = [ { secretName = "old"; } ];
              };
            };
          }
        );
        noReferences = withParts (
          { scope, infisicalOperator, ... }:
          {
            empty = infisicalOperator.out.mkInfisicalSecret scope {
              name = "empty";
              spec = legacySpec scope;
            };
          }
        );
        unknownSecretRef = withParts (
          { self, ... }:
          {
            wrong = self.sync.out.secretRef {
              name = "missing";
              keys = [ "API_KEY" ];
            };
          }
        );
        dynamicSecret = withParts (
          { scope, infisicalOperator, ... }:
          {
            dynamic = infisicalOperator.out.mkInfisicalDynamicSecret scope { name = "lease"; };
          }
        );
        hostEnv = clusterWith { config.env.INFISICAL_HOST_API = "https://y/api"; };
        leaderElect = clusterWith { config.extraArgs = [ "--leader-elect=false" ]; };
        otherMinor = clusterWith { config.image.tag = "v0.12.0"; };
        latest = clusterWith { config.image.tag = "latest"; };
      };
      accepted = builtins.attrNames (lib.filterAttrs (_: c: !(evalFails c)) cases);
    in
    (
      accepted == [ ]
      && !(evalFails (clusterWith {
        config.image.tag = "v0.11.3";
      }))
    )
    || throw "infisical-operator refusals: these built: ${builtins.toJSON accepted}";
}

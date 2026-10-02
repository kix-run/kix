# Tests for kix/packages/infisical-operator: the custom resource builders,
# readiness, ordering, metrics gating, address handling, the egress check,
# and refusals. The operator and a consumer both run in namespace
# `infisical`.

{
  lib,
  kixKeys,
  mkCluster,
  netpolOn,
  manifests,
  ofKind,
  byName,
  evalFails,
  prometheusStub,
  ...
}:

let
  operatorPackage = import ../../../packages/infisical-operator;
  egress = import ../../../packages/infisical-operator/egress.nix { inherit lib; };

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
  # resource built from one would skip the metadata pinning. InfisicalAuth
  # has none because mkInfisicalAuth adds the connection.
  infisical-operator-out-crds =
    let
      names = builtins.attrNames cluster.instances.infisical.infisical-operator.raw.root.out.crds;
    in
    names == [
      "ClusterGenerator"
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
  # fails the build, and the platform intent the message gives makes it
  # build. An intent in another namespace or for another port does not.
  infisical-operator-egress =
    let
      selectorLabels = (byName "infisical-operator" (ofKind "Deployment" ms)).spec.selector.matchLabels;
      intent = to: port: {
        namespace = "infisical";
        podSelector = selectorLabels;
        egress = [
          {
            inherit to;
            ports = [
              {
                inherit port;
                protocol = "TCP";
              }
            ];
          }
        ];
      };
      enforced =
        {
          address ? null,
          intents ? { },
        }:
        clusterWith {
          config = lib.optionalAttrs (address != null) { inherit address; };
          modules = [
            netpolOn
            { networkPolicy.platformIntents = intents; }
          ];
        };
      external = "http://infisical.example:8080";
      inCluster = "https://infisical.infisical.svc";
      message = egress.check {
        who = "infisical-operator infisical/infisical-operator";
        clusterConfig = {
          clusterDomain = "cluster.test";
          networkPolicy = {
            enable = true;
            enforced.egress = true;
          };
        };
        address = external;
        namespace = "infisical";
        inherit selectorLabels;
        intentName = "infisical-operator-egress";
      };
      remedyCnp = byName "infisical-operator-egress" (
        ofKind "CiliumNetworkPolicy" (
          manifests (enforced {
            address = external;
            intents.infisical-operator-egress = intent "world" 8080;
          })
        )
      );
    in
    (
      evalFails (enforced {
        address = external;
      })
      && evalFails (enforced {
        address = inCluster;
      })
      && !(evalFails (enforced { }))
      && remedyCnp != null
      && !(evalFails (enforced {
        address = inCluster;
        intents.infisical-operator-egress = intent "all-pods" 8080;
      }))
      && evalFails (enforced {
        address = external;
        intents.elsewhere = intent "world" 8080 // {
          namespace = "other";
        };
      })
      && evalFails (enforced {
        address = external;
        intents.wrong-port = intent "world" 9090;
      })
      && lib.hasInfix "infisical-operator-egress = { namespace = \"infisical\"; podSelector = { " message
      && lib.hasInfix "egress = [ { to = \"world\"; ports = [ { port = 8080; protocol = \"TCP\"; } ]; } ]; };" message
    )
    || throw "infisical-operator egress: remedy CNP ${builtins.toJSON remedyCnp}, message ${builtins.toJSON message}";

  # Each refused case fails and its corrected form builds, so a refusal
  # cannot pass on an unrelated failure in the fixture.
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
      legacy =
        spec:
        withParts (
          { scope, infisicalOperator, ... }:
          {
            extra = infisicalOperator.out.mkInfisicalSecret scope {
              name = "extra";
              spec = legacySpec scope // spec;
            };
          }
        );
      static =
        targets: refArgs:
        withParts (
          {
            self,
            scope,
            infisicalOperator,
            ...
          }:
          {
            extra = infisicalOperator.out.mkInfisicalStaticSecret scope {
              name = "extra";
              spec = {
                infisicalAuthRef = {
                  name = self.auth.out.name;
                  namespace = scope.namespaceName;
                };
                sources = [
                  {
                    projectId = "project";
                    environmentSlug = "prod";
                    secretPath = "/";
                  }
                ];
              }
              // lib.optionalAttrs (targets != null) { inherit targets; };
            };
          }
          // lib.optionalAttrs (refArgs != null) { extraRef = self.extra.out.secretRef refArgs; }
        );
      secretTarget = {
        name = "extra";
        kind = "Secret";
      };
      configMapTarget = {
        name = "extra-config";
        kind = "ConfigMap";
      };
      cases = {
        managedSecretReference = {
          bad = legacy {
            managedSecretReference.secretName = "old";
            managedKubeSecretReferences = [ { secretName = "old"; } ];
          };
          good = legacy { managedKubeSecretReferences = [ { secretName = "old"; } ]; };
        };
        noReferences = {
          bad = legacy { };
          good = legacy { managedKubeConfigMapReferences = [ { configMapName = "old"; } ]; };
        };
        noTargets = {
          bad = static null null;
          good = static [ configMapTarget ] null;
        };
        emptyTargets = {
          bad = static [ ] null;
          good = static [ secretTarget ] null;
        };
        configMapOnlySecretRef = {
          bad = static [ configMapTarget ] { keys = [ "K" ]; };
          good = static [ configMapTarget secretTarget ] { keys = [ "K" ]; };
        };
        unknownSecretRef = {
          bad = static [ secretTarget ] {
            name = "missing";
            keys = [ "K" ];
          };
          good = static [ secretTarget ] {
            name = "extra";
            keys = [ "K" ];
          };
        };
        hostEnv = {
          bad = clusterWith { config.env.INFISICAL_HOST_API = "https://y/api"; };
          good = clusterWith { config.env.GODEBUG = "x509ignoreCN=0"; };
        };
        leaderElect = {
          bad = clusterWith { config.extraArgs = [ "--leader-elect=false" ]; };
          good = clusterWith { config.extraArgs = [ "--zap-log-level=debug" ]; };
        };
        otherMinor = {
          bad = clusterWith { config.image.tag = "v0.12.0"; };
          good = clusterWith { config.image.tag = "v0.11.3"; };
        };
      };
      wrong = builtins.attrNames (lib.filterAttrs (_: c: !(evalFails c.bad) || evalFails c.good) cases);
      dynamicSecret = withParts (
        { scope, infisicalOperator, ... }:
        {
          dynamic = infisicalOperator.out.mkInfisicalDynamicSecret scope { name = "lease"; };
        }
      );
    in
    (wrong == [ ] && evalFails dynamicSecret)
    || throw "infisical-operator refusals: bad case built or good case failed: ${builtins.toJSON wrong}";

  # The image tag assertion names the tag, the release minor, and the fix
  # for a cluster author; the sources.txt assertion holds. The package's
  # assertions read only `config`, and a failed one stops the cluster before
  # its diagnostics can be read, so the test calls them directly.
  infisical-operator-image-tag-message =
    let
      failed =
        tag:
        map (a: a.message) (
          builtins.filter (a: !a.assertion) (assertionsOf {
            config.image.tag = tag;
          })
        );
      # The assertions use only `lib` from the package arguments.
      assertionsOf =
        (operatorPackage {
          inherit lib;
          scope = { };
          kix = { };
          availability = null;
        }).assertions;
      latest = failed "latest";
    in
    (
      builtins.length latest == 1
      && lib.hasPrefix "image.tag \"latest\" is not a v0.11 release" (builtins.head latest)
      && lib.hasInfix "Remove image.tag or set a v0.11 tag." (builtins.head latest)
      && failed "v0.11.3" == [ ]
    )
    || throw "infisical-operator image tag: ${builtins.toJSON latest}";
}

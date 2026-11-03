# Tests for kix/packages/external-secrets: the webhook check gate on every
# custom resource, the builders' pinning and edges, the webhook
# configurations, metrics gating, the alert rules of the three components,
# the release checks, and refusals. The
# operator runs in namespace `external-secrets` and the consumer in `app`.

{
  lib,
  kixKeys,
  kixlib,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  prometheusStub,
  alertRulesOf,
  allSelect,
  ...
}:

let
  operatorPackage = import ../../../packages/external-secrets;
  secretRefPackage = import ../../../packages/secret-ref;

  # The package header's consumer pattern, plus a Password generator, an
  # ExternalSecret reading it through dataFrom, and a ClusterSecretStore. `extraParts` adds parts for the refusal cases.
  mkConsumer =
    {
      extraParts ? _: { },
    }:
    {
      meta = {
        version = "test";
        description = "External Secrets consumer";
        owner = "test";
      };
      build =
        {
          self,
          scope,
          externalSecrets,
          vaultToken,
          ...
        }:
        {
          store = externalSecrets.out.mkSecretStore scope {
            name = "vault";
            spec.provider.vault = {
              server = "https://vault.example.com";
              path = "secret";
              version = "v2";
              auth.tokenSecretRef = (vaultToken.out.keyRef "token").valueFrom.secretKeyRef;
            };
          };
          sync = externalSecrets.out.mkExternalSecret scope {
            name = "billing";
            spec = {
              secretStoreRef = {
                name = self.store.out.name;
                kind = "SecretStore";
              };
              refreshInterval = "1h";
              data = [
                {
                  secretKey = "API_KEY";
                  remoteRef = {
                    key = "billing";
                    property = "api-key";
                  };
                }
              ];
            };
          };
          credentials = self.sync.out.secretRef { keys = [ "API_KEY" ]; };

          password = scope.mkCR externalSecrets.out.crds.Password {
            name = "db";
            spec = {
              length = 32;
              digits = 5;
              symbols = 0;
              noUpper = false;
              allowRepeat = true;
            };
          };
          generated = externalSecrets.out.mkExternalSecret scope {
            name = "db";
            spec = {
              refreshInterval = "0";
              target = {
                name = "db-password";
                template.metadata.labels.team = "billing";
              };
              dataFrom = [
                {
                  sourceRef.generatorRef = {
                    apiVersion = "generators.external-secrets.io/v1alpha1";
                    kind = "Password";
                    name = self.password.out.name;
                  };
                }
              ];
            };
          };
          dbPassword = self.generated.out.secretRef { keys = [ "password" ]; };

          clusterStore = externalSecrets.out.mkClusterSecretStore scope {
            name = "fake";
            spec.provider.fake.data = [
              {
                key = "k";
                value = "v";
              }
            ];
          };

          root = {
            resource = self.credentials;
            requires = [
              self.dbPassword
              self.clusterStore
            ];
          };
        }
        // extraParts {
          inherit self scope externalSecrets;
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
          instances.external-secrets.external-secrets = {
            package = operatorPackage;
            inherit config;
          };
          instances.app = {
            consumer.package = consumer;
            vault-token = {
              package = secretRefPackage;
              aliases = [ "vaultToken" ];
              config.keys = [ "token" ];
            };
          };
        }
      ]
      ++ modules
    );

  cluster = clusterWith { };
  ms = manifests cluster;
  find = kind: name: byName name (ofKind kind ms);
  hashOf =
    nsName: inst: part:
    builtins.unsafeDiscardStringContext
      cluster.instances.${nsName}.${inst}.raw.${part}.out.identityHash;
  dependsOn = m: lib.splitString "," ((m.metadata.annotations or { }).${kixKeys.dependsOn} or "");
  readinessOf = m: (m.metadata.annotations or { }).${kixKeys.readiness} or null;
  ready = builtins.toJSON {
    condition = {
      status = "True";
      type = "Ready";
    };
  };

  # The package's assertions read only `config` and `lib`.
  assertionsOf =
    (operatorPackage {
      inherit lib;
      scope = { };
      kix = { };
      availability = null;
    }).assertions;
  failedAssertions =
    config:
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (assertionsOf {
        inherit config;
      })
    );
  defaultConfig = {
    image.tag = "v2.11.0";
    extraArgs = [ ];
  };
in
{
  # Every custom resource built from `out`, through a builder or a handle,
  # requires the webhook check Job, so none reaches the API server before
  # the webhook's CA is injected.
  external-secrets-crd-handles-gated =
    let
      job = hashOf "external-secrets" "external-secrets" "webhookCheck";
      crs = [
        (find "SecretStore" "vault")
        (find "ExternalSecret" "billing")
        (find "ExternalSecret" "db")
        (find "Password" "db")
        (find "ClusterSecretStore" "fake")
      ];
      ungated = builtins.filter (m: !(lib.any (lib.hasInfix job) (dependsOn m))) crs;
    in
    (builtins.all (m: m != null) crs && ungated == [ ])
    || throw "external-secrets gate: job ${job}, ungated ${
      builtins.toJSON (map (m: m.metadata) ungated)
    }";

  # ExternalSecret, SecretStore, and ClusterSecretStore have no handle, so
  # their custom resources always go through the builders; GeneratorState is
  # the controller's.
  external-secrets-out-crds =
    let
      names = builtins.attrNames cluster.instances.external-secrets.external-secrets.raw.root.out.crds;
      expected = [
        "ACRAccessToken"
        "BeyondtrustWorkloadCredentialsDynamicSecret"
        "CloudsmithAccessToken"
        "ClusterExternalSecret"
        "ClusterGenerator"
        "ClusterPushSecret"
        "ECRAuthorizationToken"
        "Fake"
        "GCRAccessToken"
        "GithubAccessToken"
        "GitlabDeployToken"
        "Grafana"
        "MFA"
        "Password"
        "PushSecret"
        "QuayAccessToken"
        "SSHKey"
        "STSSessionToken"
        "UUID"
        "VaultDynamicSecret"
        "Webhook"
      ];
    in
    names == expected || throw "external-secrets out.crds: ${builtins.toJSON names}";

  # Ready=True on the kinds whose controllers set it; none on a generator.
  external-secrets-readiness =
    let
      got = {
        store = readinessOf (find "SecretStore" "vault");
        sync = readinessOf (find "ExternalSecret" "billing");
        clusterStore = readinessOf (find "ClusterSecretStore" "fake");
        password = readinessOf (find "Password" "db");
      };
    in
    got == {
      store = ready;
      sync = ready;
      clusterStore = ready;
      password = null;
    }
    || throw "external-secrets readiness: ${builtins.toJSON got}";

  # A target without a template gets empty template metadata; a template's
  # own metadata is kept.
  external-secrets-template-pinning =
    let
      billing = (find "ExternalSecret" "billing").spec.target;
      db = (find "ExternalSecret" "db").spec.target;
    in
    (
      billing == {
        template.metadata = { };
      }
      &&
        db == {
          name = "db-password";
          template.metadata.labels.team = "billing";
        }
    )
    || throw "external-secrets pinning: billing ${builtins.toJSON billing}, db ${builtins.toJSON db}";

  # The store depends on the token Secret it names; each secretRef marker
  # names the ExternalSecret's target Secret and requires the
  # ExternalSecret.
  external-secrets-edges =
    let
      store = find "SecretStore" "vault";
      marker = name: find "PackageInstance" "secret-ref-consumer-${name}";
      # The secret-ref instance depends on its marker, and the marker on
      # what the instance's other parts also depend on.
      tokenMarker = find "PackageInstance" "secret-ref-vault-token-vault-token";
      tokenRefs = lib.subtractLists (dependsOn tokenMarker) (
        dependsOn (find "PackageInstance" "vault-token")
      );
    in
    (
      store.spec.provider.vault.auth.tokenSecretRef == {
        name = "vault-token";
        key = "token";
      }
      && builtins.length tokenRefs == 1
      && builtins.elem (builtins.head tokenRefs) (dependsOn store)
      && builtins.elem "requires:${hashOf "app" "consumer" "sync"}" (dependsOn (marker "billing"))
      && builtins.elem "requires:${hashOf "app" "consumer" "generated"}" (
        dependsOn (marker "db-password")
      )
    )
    || throw "external-secrets edges: store ${builtins.toJSON store.metadata}, markers ${
      builtins.toJSON [
        (marker "billing")
        (marker "db-password")
      ]
    }";

  # The webhook entries carry the label the cert-controller selects, name
  # the webhook Service, and leave caBundle to the cert-controller.
  external-secrets-webhook-configs =
    let
      configs = ofKind "ValidatingWebhookConfiguration" ms;
      entries = lib.concatMap (c: c.webhooks) configs;
      service = find "Service" "external-secrets-webhook";
    in
    (
      builtins.length configs == 2
      && builtins.all (c: c.metadata.labels."external-secrets.io/component" == "webhook") configs
      && builtins.length entries == 3
      && builtins.all (
        e:
        e.clientConfig.service == {
          name = "external-secrets-webhook";
          namespace = "external-secrets";
          path = e.clientConfig.service.path;
        }
        && !(e.clientConfig ? caBundle)
        && e.failurePolicy == "Fail"
      ) entries
      && service != null
    )
    || throw "external-secrets webhook configs: ${builtins.toJSON configs}";

  # The metrics Services, the webhook Service's metrics port, and the
  # ServiceMonitors render only with a prometheus provider and
  # metrics.enabled; each monitor selects one Service.
  external-secrets-metrics =
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
      services = ofKind "Service";
      monitors = ofKind "ServiceMonitor" on;
      selected =
        monitor:
        builtins.filter (
          s:
          lib.all (k: (s.metadata.labels or { }).${k} or null == monitor.spec.selector.matchLabels.${k}) (
            builtins.attrNames monitor.spec.selector.matchLabels
          )
        ) (services on);
    in
    (
      builtins.length (services on) == 3
      && builtins.length monitors == 3
      && builtins.all (m: builtins.length (selected m) == 1) monitors
      && builtins.length (services ms) == 1
      && builtins.length (services off) == 1
      && map (p: p.name) (find "Service" "external-secrets-webhook").spec.ports == [ "webhook" ]
      && ofKind "ServiceMonitor" off == [ ]
    )
    || throw "external-secrets metrics: monitors ${
      builtins.toJSON (map (m: m.spec.selector) monitors)
    }";

  # Each component's rules render under its own name, select its own
  # metrics Service, and need a prometheus dependency and metrics.enabled.
  external-secrets-alerts =
    let
      withPrometheus =
        config:
        manifests (clusterWith {
          inherit config;
          modules = [ { instances.monitoring.prometheus.package = prometheusStub; } ];
        });
      on = withPrometheus { };
      off = withPrometheus { metrics.enabled = false; };
      rulesOf = m: name: alertRulesOf "PrometheusRule" name m;
      controller = rulesOf on "external-secrets";
      webhook = rulesOf on "external-secrets-webhook";
      certController = rulesOf on "external-secrets-cert-controller";
      sel = service: ''namespace="external-secrets",service="${service}"'';
    in
    (
      allSelect (sel "external-secrets-metrics") controller
      && allSelect (sel "external-secrets-webhook") webhook
      && allSelect (sel "external-secrets-cert-controller-metrics") certController
      &&
        builtins.attrNames controller == [
          "ExternalSecretNotReady"
          "ExternalSecretsClusterSecretStoreNotReady"
          "ExternalSecretsControllerDown"
          "ExternalSecretsSecretStoreNotReady"
        ]
      && builtins.attrNames webhook == [ "ExternalSecretsWebhookDown" ]
      && builtins.attrNames certController == [ "ExternalSecretsCertControllerDown" ]
      && ofKind "PrometheusRule" ms == [ ]
      && ofKind "PrometheusRule" off == [ ]
    )
    || throw "external-secrets alerts: ${
      builtins.toJSON (map (r: r.metadata.name) (ofKind "PrometheusRule" on))
    }";

  # The definitions keep the vendored label the cert-controller's partial
  # cache selects, and the check Job dry-runs one object per webhook
  # configuration.
  external-secrets-cert-controller-cache =
    let
      crds = builtins.filter (c: lib.hasSuffix "external-secrets.io" c.spec.group) (
        ofKind "CustomResourceDefinition" ms
      );
      unlabelled = builtins.filter (
        c: (c.metadata.labels or { })."external-secrets.io/component" or null != "controller"
      ) crds;
      certArgs =
        (builtins.head (find "Deployment" "external-secrets-cert-controller").spec.template.spec.containers)
        .args;
      checkFiles = builtins.attrNames (find "ConfigMap" "external-secrets-webhook-check").data;
      checkKinds = map (
        f: (builtins.fromJSON (find "ConfigMap" "external-secrets-webhook-check").data.${f}).kind
      ) checkFiles;
    in
    (
      builtins.length crds == 25
      && unlabelled == [ ]
      && builtins.elem "--enable-partial-cache=true" certArgs
      &&
        checkKinds == [
          "ExternalSecret"
          "SecretStore"
        ]
    )
    || throw "external-secrets cert-controller cache: unlabelled ${
      builtins.toJSON (map (c: c.metadata.name) unlabelled)
    }, args ${builtins.toJSON certArgs}, check ${builtins.toJSON checkKinds}";

  # crds/sources.txt fetches the release the package pins.
  external-secrets-sources-match-release =
    let
      release =
        (operatorPackage {
          inherit lib;
          scope = { };
          kix = { };
          availability = null;
        }).meta.version;
      urls = builtins.filter (l: l != "" && !lib.hasPrefix "#" l) (
        lib.splitString "\n" (builtins.readFile ../../../packages/external-secrets/crds/sources.txt)
      );
    in
    (urls != [ ] && lib.all (lib.hasInfix "/${release}/") urls)
    || throw "external-secrets sources.txt is not at ${release}: ${builtins.toJSON urls}";

  # The assertions name the tag, the release minor, and the fix, and refuse
  # generic targets in any spelling but =false.
  external-secrets-assertions =
    let
      latest = failedAssertions (defaultConfig // { image.tag = "latest"; });
      generic = failedAssertions (defaultConfig // { extraArgs = [ "--unsafe-allow-generic-targets" ]; });
    in
    (
      failedAssertions defaultConfig == [ ]
      && failedAssertions (defaultConfig // { image.tag = "v2.11.3"; }) == [ ]
      && builtins.length latest == 1
      && lib.hasPrefix "image.tag \"latest\" is not a v2.11 release" (builtins.head latest)
      && lib.hasInfix "Remove image.tag or set a v2.11.x tag." (builtins.head latest)
      && builtins.length generic == 1
      && lib.hasInfix "--unsafe-allow-generic-targets" (builtins.head generic)
      &&
        failedAssertions (defaultConfig // { extraArgs = [ "--unsafe-allow-generic-targets=false" ]; })
        == [ ]
      &&
        failedAssertions (defaultConfig // { extraArgs = [ "--unsafe-allow-generic-targets=true" ]; })
        != [ ]
    )
    || throw "external-secrets assertions: latest ${builtins.toJSON latest}, generic ${builtins.toJSON generic}";

  # Each refused case fails and its corrected form builds, so a refusal
  # cannot pass on an unrelated failure in the fixture.
  external-secrets-refusals =
    let
      withParts = extraParts: clusterWith { consumer = mkConsumer { inherit extraParts; }; };
      store =
        tokenSecretRef:
        withParts (
          { scope, externalSecrets, ... }:
          {
            extraStore = externalSecrets.out.mkSecretStore scope {
              name = "extra";
              spec.provider.vault = {
                server = "https://vault.example.com";
                path = "secret";
                auth.tokenSecretRef = tokenSecretRef;
              };
            };
          }
        );
      clusterStore =
        tokenSecretRef:
        withParts (
          { externalSecrets, scope, ... }:
          {
            extraClusterStore = externalSecrets.out.mkClusterSecretStore scope {
              name = "extra";
              spec.provider.vault = {
                server = "https://vault.example.com";
                path = "secret";
                auth.tokenSecretRef = tokenSecretRef;
              };
            };
          }
        );
      untracked = kixlib.untrackedRef {
        name = "vault-token";
        kind = "Secret";
      };
      externalSecret =
        target: refArgs:
        withParts (
          {
            self,
            scope,
            externalSecrets,
            ...
          }:
          {
            extra = externalSecrets.out.mkExternalSecret scope {
              name = "extra";
              spec = {
                secretStoreRef = {
                  name = self.store.out.name;
                  kind = "SecretStore";
                };
                inherit target;
                data = [
                  {
                    secretKey = "A";
                    remoteRef.key = "a";
                  }
                ];
              };
            };
          }
          // lib.optionalAttrs (refArgs != null) { extraRef = self.extra.out.secretRef refArgs; }
        );
      cases = {
        literalSelector = {
          bad = store {
            name = "vault-token";
            key = "token";
          };
          good = store {
            name = kixlib.untrackedRef {
              name = "vault-token";
              kind = "Secret";
            };
            key = "token";
          };
        };
        clusterStoreLiteral = {
          bad = clusterStore {
            name = "vault-token";
            key = "token";
            namespace = "app";
          };
          good = clusterStore {
            name = untracked;
            key = "token";
            namespace = "app";
          };
        };
        clusterStoreNoNamespace = {
          bad = clusterStore {
            name = untracked;
            key = "token";
          };
          good = clusterStore {
            name = untracked;
            key = "token";
            namespace = "app";
          };
        };
        manifestTarget = {
          bad = externalSecret {
            manifest = {
              apiVersion = "v1";
              kind = "ConfigMap";
            };
          } null;
          good = externalSecret { name = "extra"; } null;
        };
        creationPolicyNone = {
          bad = externalSecret { creationPolicy = "None"; } { keys = [ "A" ]; };
          good = externalSecret { creationPolicy = "Orphan"; } { keys = [ "A" ]; };
        };
        unknownKey = {
          bad = externalSecret { } { keys = [ "B" ]; };
          good = externalSecret { } { keys = [ "A" ]; };
        };
        # Merge keeps the keys another writer put in the Secret.
        unknownKeyUnlessMerge = {
          bad = externalSecret { creationPolicy = "Owner"; } { keys = [ "B" ]; };
          good = externalSecret { creationPolicy = "Merge"; } { keys = [ "B" ]; };
        };
        templateReplacesKeys = {
          bad = externalSecret { template.data.URL = "https://{{ .A }}"; } { keys = [ "A" ]; };
          good =
            externalSecret
              {
                template = {
                  mergePolicy = "Merge";
                  data.URL = "https://{{ .A }}";
                };
              }
              {
                keys = [
                  "A"
                  "URL"
                ];
              };
        };
        leaderElect = {
          bad = clusterWith { config.extraArgs = [ "--enable-leader-election=false" ]; };
          good = clusterWith { config.extraArgs = [ "--concurrent=4" ]; };
        };
        genericTargets = {
          bad = clusterWith { config.extraArgs = [ "--unsafe-allow-generic-targets=true" ]; };
          good = clusterWith { config.extraArgs = [ "--unsafe-allow-generic-targets=false" ]; };
        };
        otherMinor = {
          bad = clusterWith { config.image.tag = "v2.12.0"; };
          good = clusterWith { config.image.tag = "v2.11.1"; };
        };
      };
      wrong = builtins.attrNames (lib.filterAttrs (_: c: !(evalFails c.bad) || evalFails c.good) cases);
    in
    wrong == [ ]
    || throw "external-secrets refusals: bad case built or good case failed: ${builtins.toJSON wrong}";
}

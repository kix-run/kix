# Tests for dependency resolution around meta.scope = "namespace" (an
# instance with that scope is never resolved or activated for a requester in
# another namespace), and for the external-dns package's checks and derived
# resources.

{
  lib,
  eval,
  kixlib,
  kixKeys,
  mkCluster,
  mkCmPackage,
  manifests,
  ofKind,
  hasName,
  byName,
  evalFails,
  alertRulesOf,
  allSelect,
  prometheusStub,
  ...
}:

let
  credentialsPackage =
    {
      name,
      scope ? "namespace",
    }:
    mkCmPackage {
      inherit name;
      metaExtra = {
        inherit scope;
        defaultAliases = [ "providerCredentials" ];
      };
    };

  # Records which instance `providerCredentials` resolved to in a ConfigMap,
  # or "none".
  describeDep =
    dep: if dep == null then "none" else "${dep._meta.namespaceName}/${dep._meta.instanceName}";

  optionalConsumer = {
    meta.version = "test";
    build =
      {
        self,
        scope,
        providerCredentials ? null,
        ...
      }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "consumer";
          extra.data.dep = describeDep providerCredentials;
        };
        root = self.cm;
      };
  };

  requiredConsumer = {
    meta.version = "test";
    build =
      {
        self,
        scope,
        providerCredentials,
        ...
      }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "consumer";
          extra.data.dep = describeDep providerCredentials;
        };
        root = self.cm;
      };
  };

  resolvedDep = cluster: (byName "consumer" (ofKind "ConfigMap" (manifests cluster))).data.dep;

  externalDnsPackage = import ../../../packages/external-dns;
  secretPackage = import ../../../packages/secret;
  prometheusOperatorPackage = import ../../../packages/prometheus-operator;

  # The package's `assertions` and `warnings` called directly, with a config
  # evaluated against its options. tryEval drops a throw's message, so this
  # is how the tests read the message text. `keys` stands in for the
  # providerCredentials dependency; null means none is wired.
  externalDns =
    {
      enforcer ? null,
    }:
    externalDnsPackage {
      scope = {
        instanceName = "edns";
        namespaceName = "dns";
        rbac = throw "external-dns tests: rbac is not used by assertions or warnings";
        networkPolicyEnforcer = enforcer;
      };
      inherit lib;
      kix = kixlib;
    };
  ednsConfig =
    config:
    eval.evaluateInstanceConfig {
      packageOptions = (externalDns { }).options;
      instCfg.config.imports = [ config ];
      namespaceName = "dns";
      instanceName = "edns";
    };
  ednsDeps =
    keys:
    lib.optionalAttrs (keys != null) {
      providerCredentials.out = {
        name = "creds";
        inherit keys;
      };
    };
  failedMessages =
    {
      config,
      keys ? null,
    }:
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (
        (externalDns { }).assertions {
          config = ednsConfig config;
          deps = ednsDeps keys;
        }
      )
    );
  warningsFor =
    {
      config,
      enforcer ? null,
    }:
    (externalDns { inherit enforcer; }).warnings { config = ednsConfig config; };

  cloudflare =
    extra:
    {
      provider = "cloudflare";
      policy = "sync";
      txtOwnerId = "test";
    }
    // extra;
  inmemory =
    extra:
    {
      provider = "inmemory";
      policy = "sync";
      txtOwnerId = "test";
    }
    // extra;

  # True when one of `messages` contains every fragment.
  someMessageHas =
    fragments: messages: builtins.any (m: builtins.all (f: lib.hasInfix f m) fragments) messages;

  ednsCluster =
    config:
    mkCluster [
      {
        instances.dns.edns = {
          package = externalDnsPackage;
          inherit config;
        };
      }
    ];
in
{
  # Consumer in `edns`, namespace-scoped `providerCredentials` instances only
  # in other namespaces. An optional dep resolves to null and the cluster
  # builds; a required dep fails with the not-found error; a cluster-scoped
  # instance beside two foreign namespace-scoped ones is the one chosen.
  external-dns-optional-dep-skips-namespace-scoped-elsewhere =
    let
      optional = mkCluster [
        {
          instances.edns.consumer.package = optionalConsumer;
          instances.other.creds.package = credentialsPackage { name = "other-creds"; };
        }
      ];
      required = mkCluster [
        {
          instances.edns.consumer.package = requiredConsumer;
          instances.other.creds.package = credentialsPackage { name = "other-creds"; };
        }
      ];
      mixed = mkCluster [
        {
          instances.edns.consumer.package = requiredConsumer;
          instances.other.creds.package = credentialsPackage { name = "other-creds"; };
          instances.third.creds.package = credentialsPackage { name = "third-creds"; };
          instances.shared.creds.package = credentialsPackage {
            name = "shared-creds";
            scope = "cluster";
          };
        }
      ];
    in
    (resolvedDep optional == "none" && evalFails required && resolvedDep mixed == "shared/creds")
    || throw "namespace-scoped candidates elsewhere: optional ${resolvedDep optional}, mixed ${resolvedDep mixed}, required fails ${builtins.toJSON (evalFails required)}";

  # Optional instances answering a required dep of `edns/consumer`: a
  # namespace-scoped one in `other` and a cluster-scoped one in `shared`.
  # Activation picks the cluster-scoped one, as resolution does, and leaves
  # the namespace-scoped one inactive.
  external-dns-pick-optional-skips-namespace-scoped-elsewhere =
    let
      cluster = mkCluster [
        {
          instances.edns.consumer.package = requiredConsumer;
          instances.other.creds = {
            package = credentialsPackage { name = "other-creds"; };
            optional = true;
          };
          instances.shared.creds = {
            package = credentialsPackage {
              name = "shared-creds";
              scope = "cluster";
            };
            optional = true;
          };
        }
      ];
      cms = ofKind "ConfigMap" (manifests cluster);
    in
    (
      resolvedDep cluster == "shared/creds" && hasName "shared-creds" cms && !(hasName "other-creds" cms)
    )
    || throw "pickOptional with a namespace-scoped optional elsewhere: dep ${resolvedDep cluster}, ConfigMaps ${
      builtins.toJSON (map (m: m.metadata.name) cms)
    }";

  # Each credential assertion fires for its case and names the fix; valid
  # configurations fail none.
  external-dns-credential-assertions =
    let
      cases = {
        noCredentials = failedMessages { config = cloudflare { }; };
        unmappedKey = failedMessages {
          config = cloudflare { };
          keys = [ "api-token" ];
        };
        wrongKey = failedMessages {
          config = cloudflare { secretEnv.CF_API_TOKEN = "token"; };
          keys = [ "api-token" ];
        };
        secretEnvWithoutDep = failedMessages {
          config = inmemory { secretEnv.CF_API_TOKEN = "api-token"; };
        };
        pdnsWithoutDep = failedMessages { config = inmemory { provider = "pdns"; }; };
        mapped = failedMessages {
          config = cloudflare { secretEnv.CF_API_TOKEN = "api-token"; };
          keys = [ "api-token" ];
        };
        envFromNamedKeys = failedMessages {
          config = cloudflare { };
          keys = [ "CF_API_TOKEN" ];
        };
      };
    in
    (
      someMessageHas [
        "reads its API credentials from CF_API_TOKEN, or CF_API_KEY and CF_API_EMAIL"
        "deps.providerCredentials = ref.dns.<instance>"
      ] cases.noCredentials
      && someMessageHas [
        "providerCredentials \"creds\" declares api-token"
        "secretEnv.CF_API_TOKEN"
      ] cases.unmappedKey
      && someMessageHas [
        "secretEnv.CF_API_TOKEN names key \"token\""
        "Map one of those keys, or add \"token\" to that instance's keys."
      ] cases.wrongKey
      && someMessageHas [ "no providerCredentials dependency is wired" ] cases.secretEnvWithoutDep
      && someMessageHas [ "EXTERNAL_DNS_PDNS_API_KEY" ] cases.pdnsWithoutDep
      && cases.mapped == [ ]
      && cases.envFromNamedKeys == [ ]
    )
    || throw "external-dns credential assertions: ${builtins.toJSON cases}";

  # A literal string in `env` for a credential variable is refused, for a
  # provider's own variables and for the EXTERNAL_DNS_ form of a credential
  # flag; CF_API_EMAIL is not a secret. In envFrom mode, a Secret key named
  # like the variable of a flag the package sets is refused.
  external-dns-refuses-literal-credentials-and-owned-keys =
    let
      cases = {
        literalToken = failedMessages { config = cloudflare { env.CF_API_TOKEN = "literal"; }; };
        literalFlagVar = failedMessages {
          config = inmemory { env.EXTERNAL_DNS_PDNS_API_KEY = "literal"; };
        };
        email = failedMessages { config = inmemory { env.CF_API_EMAIL = "dns@example.com"; }; };
        ownedKey = failedMessages {
          config = cloudflare { };
          keys = [
            "CF_API_TOKEN"
            "EXTERNAL_DNS_POLICY"
          ];
        };
        ownedKeyMapped = failedMessages {
          config = cloudflare { secretEnv.CF_API_TOKEN = "CF_API_TOKEN"; };
          keys = [
            "CF_API_TOKEN"
            "EXTERNAL_DNS_POLICY"
          ];
        };
      };
    in
    (
      someMessageHas [
        "env sets CF_API_TOKEN to a literal string"
        "secretEnv.CF_API_TOKEN = \"<key>\""
      ] cases.literalToken
      && someMessageHas [ "env sets EXTERNAL_DNS_PDNS_API_KEY to a literal string" ] cases.literalFlagVar
      && cases.email == [ ]
      && someMessageHas [
        "providerCredentials \"creds\" declares EXTERNAL_DNS_POLICY"
        "inject only the credential keys with secretEnv"
      ] cases.ownedKey
      && cases.ownedKeyMapped == [ ]
    )
    || throw "external-dns literal credentials and owned keys: ${builtins.toJSON cases}";

  # `--registry=crd` warns about the CRD and its RBAC in both flag forms; a
  # provider on another port warns only under an enforcer.
  external-dns-warnings =
    let
      cases = {
        crdRegistry = warningsFor { config = inmemory { extraArgs = [ "--registry=crd" ]; }; };
        crdRegistrySpaced = warningsFor {
          config = inmemory {
            extraArgs = [
              "--registry"
              "crd"
            ];
          };
        };
        listenerSets = warningsFor { config = inmemory { extraArgs = [ "--gateway-listener-sets" ]; }; };
        rfc2136Enforced = warningsFor {
          config = inmemory { provider = "rfc2136"; };
          enforcer = "cilium";
        };
        rfc2136 = warningsFor { config = inmemory { provider = "rfc2136"; }; };
      };
    in
    (
      someMessageHas [ "dnsrecords.externaldns.k8s.io" "dnsrecords/status" ] cases.crdRegistry
      && someMessageHas [ "dnsrecords.externaldns.k8s.io" ] cases.crdRegistrySpaced
      && someMessageHas [ "listenersets" ] cases.listenerSets
      && someMessageHas [ "provider rfc2136 uses port 53" ] cases.rfc2136Enforced
      && cases.rfc2136 == [ ]
    )
    || throw "external-dns warnings: ${builtins.toJSON cases}";

  # Flags the package sets, credential flags, and `--once` are refused in
  # `extraArgs` in both flag forms; the variable of a flag the package sets
  # is refused in `env`; an image tag of another minor release fails. A
  # patch release of the same minor builds.
  external-dns-refuses-owned-flags-and-other-releases =
    let
      fails = map (config: evalFails (ednsCluster (inmemory config))) [
        { extraArgs = [ "--policy=sync" ]; }
        {
          extraArgs = [
            "--policy"
            "sync"
          ];
        }
        { extraArgs = [ "--pdns-api-key=secret" ]; }
        {
          extraArgs = [
            "--rfc2136-tsig-secret"
            "secret"
          ];
        }
        { extraArgs = [ "--once" ]; }
        { env.EXTERNAL_DNS_POLICY = "sync"; }
        { env.EXTERNAL_DNS_POLICY = null; }
        {
          image = {
            tag = "v0.24.0";
            digest = null;
          };
        }
      ];
      patch = evalFails (
        ednsCluster (inmemory {
          image = {
            tag = "v0.23.1";
            digest = null;
          };
        })
      );
    in
    (builtins.all (x: x) fails && !patch)
    || throw "external-dns refusals: fails ${builtins.toJSON fails}, patch release fails ${builtins.toJSON patch}";

  # Two gateway-sourced instances in one namespace each declare their own CRD
  # reference markers. Overlapping sources list nodes and pods once. A Secret
  # built by Kix puts its identity hash on the pod template. With a
  # prometheus dependency every alert selects the instance's metrics
  # Service.
  external-dns-derived-resources =
    let
      ms = manifests (mkCluster [
        {
          instances.monitoring.prometheus-operator.package = prometheusOperatorPackage;
          instances.dns = {
            creds = {
              package = secretPackage;
              aliases = [ "providerCredentials" ];
              config.stringData.api-token = "token";
            };
            edns = {
              package = externalDnsPackage;
              config = cloudflare {
                sources = [
                  "service"
                  "pod"
                ];
                secretEnv.CF_API_TOKEN = "api-token";
              };
            };
          };
          instances.gw = {
            public = {
              package = externalDnsPackage;
              config = inmemory { sources = [ "gateway-httproute" ]; };
            };
            private = {
              package = externalDnsPackage;
              config = inmemory { sources = [ "gateway-httproute" ]; };
            };
          };
        }
      ]);
      markerNames = map (m: m.metadata.name) (
        builtins.filter (m: lib.hasPrefix "crd-ref-" m.metadata.name) (ofKind "PackageInstance" ms)
      );
      expectedMarkers =
        lib.concatMap
          (instance: [
            "crd-ref-${instance}-gateways-gateway-networking-k8s-io"
            "crd-ref-${instance}-httproutes-gateway-networking-k8s-io"
          ])
          [
            "public"
            "private"
          ];
      role = byName "edns-dns" (ofKind "ClusterRole" ms);
      coreResources = lib.concatMap (r: r.resources) (
        builtins.filter (r: r.apiGroups == [ "" ]) (role.rules or [ ])
      );
      count = x: builtins.length (builtins.filter (y: y == x) coreResources);
      deployment = byName "edns" (ofKind "Deployment" ms);
      podAnnotations = deployment.spec.template.metadata.annotations or { };
      rules = alertRulesOf "PrometheusRule" "edns" ms;
    in
    (
      builtins.all (n: builtins.elem n markerNames) expectedMarkers
      && count "nodes" == 1
      && count "pods" == 1
      && podAnnotations ? "checksum/provider-credentials"
      && allSelect ''namespace="dns",service="edns"'' rules
      &&
        builtins.attrNames rules == [
          "ExternalDNSDown"
          "ExternalDNSSyncStale"
        ]
    )
    || throw "external-dns derived resources: markers ${builtins.toJSON markerNames}, core resources ${builtins.toJSON coreResources}, pod annotations ${builtins.toJSON podAnnotations}, alerts ${builtins.toJSON (builtins.attrNames rules)}";

  # No alerts render without a prometheus dependency or with
  # metrics.enabled = false; with one, the stale threshold follows the
  # interval and never drops under 15 minutes.
  external-dns-alerts-gated =
    let
      rulesOf =
        {
          extra ? { },
          prometheus ? true,
        }:
        alertRulesOf "PrometheusRule" "edns" (
          manifests (mkCluster [
            {
              instances.dns.edns = {
                package = externalDnsPackage;
                config = inmemory extra;
              };
            }
            (lib.optionalAttrs prometheus { instances.monitoring.prometheus.package = prometheusStub; })
          ])
        );
      staleExpr = extra: (rulesOf { inherit extra; }).ExternalDNSSyncStale.expr;
    in
    (
      rulesOf { prometheus = false; } == null
      && rulesOf { extra.metrics.enabled = false; } == null
      && lib.hasSuffix "> 900" (staleExpr { })
      && lib.hasSuffix "> 1800" (staleExpr {
        interval = "10m";
      })
    )
    || throw "external-dns alerts: ${staleExpr { }}, ${staleExpr { interval = "10m"; }}";
}

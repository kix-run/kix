# Tests for a platform cluster and the consumer clusters it hosts
# (eval/consumers.nix). The platform `prod` grants consumer `acme` the
# namespaces `acme-*`, a Secret in acme-app, the service dbns/db and a
# ClusterRole, and
# writes acme's interface file. The consumer, a cluster it names `acme-prod`,
# loads the copy checked in as ./consumers/prod.json, which must equal what
# the platform writes.

{
  lib,
  eval,
  baseInstances,
  netpolOn,
  mkCmPackage,
  manifests,
  ofKind,
  evalFails,
  ...
}:

let
  kixKeys = (import ../../core/annotations.nix).keys;
  consumerLabel = kixKeys.consumerLabel;

  grant = {
    consumers.acme = {
      namespaces = {
        "acme-*" = {
          podSecurity = "restricted";
          quota.pods = "10";
        };
        acme-app.secrets = [
          {
            name = "postgres";
            keys = [
              "password"
              "user"
            ];
          }
        ];
      };
      services = [ "dbns/db" ];
      clusterScoped = [
        {
          kind = "ClusterRole";
          name = "acme-reader";
        }
      ];
    };
    reservedNamespaces = [ "kube-system" ];
    secretsRecipient = "age1test";
  };

  platformWith =
    modules:
    eval.buildCluster {
      name = "prod";
      modules = [ baseInstances ] ++ modules;
    };

  platform = platformWith [ grant ];

  interfaceOf = cluster: builtins.fromJSON (builtins.readFile cluster.interfaces.acme);

  # The platform's interface, forced: a refusal throws here.
  refused = cluster: !(builtins.tryEval (builtins.deepSeq (interfaceOf cluster) true)).success;

  fixture = ./consumers/prod.json;

  recordOf = cluster: builtins.head (ofKind "Activation" (manifests cluster));

  clusterRole = name: {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        role = scope.mkClusterResource {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "ClusterRole";
          inherit name;
        };
        root = self.role;
      };
  };

  # A consumer cluster built from `file`, with `modules` beside it.
  consumerWith =
    {
      name ? "acme-prod",
      file ? fixture,
    }:
    modules:
    eval.buildCluster {
      inherit name;
      modules = [
        (eval.interface {
          inherit file;
          importNamespace = "acme-app";
        })
        { instances.acme-app.web.package = mkCmPackage { name = "web"; }; }
      ]
      ++ modules;
    };

  consumer = consumerWith { } [ ];

  inNamespace = ns: ms: builtins.filter (m: (m.metadata.namespace or null) == ns) ms;
  named =
    kind: name: ms:
    builtins.filter (m: m.metadata.name == name) (ofKind kind ms);

  # A Deployment whose container is `container`.
  deploymentPackage = container: {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        deployment = scope.mkDeployment {
          name = "app";
          spec = {
            selector.matchLabels = scope.selectorLabels;
            template = {
              metadata.labels = scope.selectorLabels;
              spec.containers = [
                (
                  {
                    name = "app";
                    image = "registry.example.com/app:1";
                  }
                  // container
                )
              ];
            };
          };
        };
        root = self.deployment;
      };
  };

  # A container that meets Pod Security "baseline" and breaks "restricted".
  baselinePackage = deploymentPackage { securityContext.runAsNonRoot = true; };

  # `fixture` with `change` applied, as a file.
  fixtureWith =
    change:
    builtins.toFile "prod.json" (
      builtins.toJSON (change (builtins.fromJSON (builtins.readFile fixture)))
    );
in
{
  lib-consumers-interface-shape =
    let
      i = interfaceOf platform;
      db = i.services."dbns/db";
    in
    (
      i.version == 2
      && i.platform == "prod"
      && i.consumer == "acme"
      && !(i ? slice)
      && i.facts.clusterDomain == "cluster.local"
      && i.facts.networkPolicy == false
      &&
        i.namespaces == {
          "acme-*" = {
            podSecurity = "restricted";
            quota.pods = "10";
            max = null;
            secrets = [ ];
          };
          acme-app = {
            podSecurity = null;
            quota = { };
            max = null;
            secrets = [
              {
                name = "postgres";
                keys = [
                  "password"
                  "user"
                ];
                type = "Opaque";
              }
            ];
          };
        }
      &&
        i.platformNamespaces == [
          "appns"
          "dbns"
          "dns"
          "kube-system"
        ]
      && i.claimedNamespaces == [ ]
      && db.namespace == "dbns"
      && db.instance == "db"
      && db.out.fqdn == "db.dbns.svc.cluster.local"
      && !(db.out ? url)
      &&
        i.clusterScoped == [
          {
            kind = "ClusterRole";
            name = "acme-reader";
          }
        ]
      && i.secretsRecipient == "age1test"
    )
    || throw "unexpected interface: ${builtins.readFile platform.interfaces.acme}";

  # The consumer tests load the checked-in copy, so it must be what the
  # platform writes.
  lib-consumers-fixture-is-the-platforms =
    interfaceOf platform == builtins.fromJSON (builtins.readFile fixture)
    || throw "kix/lib/tests/units/consumers/prod.json is stale. Write it again from: ${builtins.readFile platform.interfaces.acme}";

  lib-consumers-platform-renders-no-consumer-namespace =
    let
      ms = manifests platform;
    in
    (named "Namespace" "acme-app" ms == [ ] && named "ResourceQuota" "acme-app-quota" ms == [ ])
    || throw "the platform rendered a namespace of its consumer";

  lib-consumers-record-names-the-consumers =
    (recordOf platform).spec.consumers == {
      acme = {
        interface = builtins.unsafeDiscardStringContext (toString platform.interfaces.acme);
        sha256 = builtins.hashFile "sha256" platform.interfaces.acme;
      };
    }
    || throw "unexpected spec.consumers: ${builtins.toJSON (recordOf platform).spec}";

  # A cluster without consumers or interfaces keeps its record as it was.
  lib-consumers-none-keeps-the-record =
    let
      spec = (recordOf (platformWith [ ])).spec;
    in
    (
      !(spec ? consumers)
      && !(spec ? interfaces)
      &&
        (platformWith [ ]).activation.outPath == (platformWith [ { consumers = { }; } ]).activation.outPath
    )
    || throw "a cluster without consumers changed its record: ${builtins.toJSON spec}";

  lib-consumers-store-path-in-out-refused =
    refused (platformWith [
      grant
      {
        instances.dbns.leaky.package = mkCmPackage {
          name = "leaky";
          out.config = "${builtins.toFile "leaky.conf" "secret"}";
        };
        consumers.acme.services = [ "dbns/leaky" ];
      }
    ])
    || throw "an out value naming a store path reached the interface";

  lib-consumers-platform-namespace-not-grantable =
    refused (platformWith [
      grant
      { consumers.acme.namespaces.appns = { }; }
    ])
    && refused (platformWith [
      grant
      { consumers.acme.namespaces.kube-system = { }; }
    ])
    || throw "a namespace the platform uses or reserves was granted";

  lib-consumers-one-wildcard =
    refused (platformWith [
      grant
      {
        consumers.acme.namespaces."*" = { };
        consumers.globex.namespaces."*" = { };
      }
    ])
    && !refused (platformWith [
      grant
      { consumers.globex.namespaces."*" = { }; }
    ])
    || throw "two consumers held \"*\", or one could not";

  # `*` is what nobody else claims. The holder's interface lists the other
  # consumers' patterns, without their names.
  lib-consumers-wildcard-lists-claimed-patterns =
    let
      cluster = platformWith [
        grant
        {
          consumers.globex.namespaces."*" = { };
          consumers.initech.namespaces = {
            reports = { };
            "initech-*" = { };
          };
        }
      ];
      claimedOf = c: (builtins.fromJSON (builtins.readFile cluster.interfaces.${c})).claimedNamespaces;
    in
    (
      claimedOf "globex" == [
        "acme-*"
        "acme-app"
        "initech-*"
        "reports"
      ]
      && claimedOf "acme" == [ ]
      && claimedOf "initech" == [ ]
    )
    || throw "the \"*\" holder's claimed patterns are wrong: ${builtins.toJSON (claimedOf "globex")}";

  lib-consumers-wildcard-secret-in-claimed-namespace-refused =
    let
      with' =
        namespace:
        platformWith [
          grant
          {
            consumers.globex.namespaces = {
              "*" = { };
              ${namespace}.secrets = [ { name = "token"; } ];
            };
          }
        ];
    in
    (refused (with' "acme-app") && !refused (with' "globex-app"))
    || throw "a Secret for the \"*\" holder was refused outside the claimed namespaces, or allowed in one";

  lib-consumers-overlapping-patterns-refused =
    let
      with' =
        patterns:
        platformWith [
          grant
          { consumers.globex.namespaces = lib.genAttrs patterns (_: { }); }
        ];
    in
    (
      refused (with' [ "acme-reports" ])
      && refused (with' [ "acme-reports-*" ])
      && refused (with' [ "acme*" ])
      && !refused (with' [ "globex-*" ])
    )
    || throw "overlapping patterns of two consumers were granted, or separate ones refused";

  lib-consumers-pattern-syntax-refused =
    refused (platformWith [
      grant
      { consumers.acme.namespaces."acme-*-app" = { }; }
    ])
    || throw "a pattern with '*' inside was accepted";

  lib-consumers-secret-outside-namespaces-refused =
    refused (platformWith [
      grant
      {
        consumers.acme.namespaces.dbns.secrets = [ { name = "postgres"; } ];
      }
    ])
    || throw "a Secret in a platform namespace was granted";

  lib-consumers-unknown-service-refused =
    refused (platformWith [
      grant
      { consumers.acme.services = [ "dbns/nope" ]; }
    ])
    || throw "a service that is not an instance was granted";

  lib-consumers-ingress-by-label-only-with-network-policy =
    let
      policy = cluster: named "NetworkPolicy" "kix-consumer-acme-db" (manifests cluster);
      on = policy (platformWith [
        grant
        netpolOn
      ]);
    in
    (
      policy platform == [ ]
      && builtins.length on == 1
      && (builtins.head on).metadata.namespace == "dbns"
      &&
        (builtins.head (builtins.head on).spec.ingress).from == [
          { namespaceSelector.matchLabels.${consumerLabel} = "acme"; }
        ]
    )
    || throw "expected the ingress policy by label only with networkPolicy.enable; with it: ${builtins.toJSON on}";

  # Any name: the consumer chooses it.
  lib-consumers-consumer-builds =
    let
      ms = manifests consumer;
    in
    (
      named "ConfigMap" "web" (inNamespace "acme-app" ms) != [ ]
      && named "PackageInstance" "db" (inNamespace "acme-app" ms) != [ ]
      && consumer.name == "acme-prod"
      && builtins.deepSeq (manifests (consumerWith { name = "staging"; } [ ])) true
    )
    || throw "unexpected consumer manifests: ${
      builtins.toJSON (map (m: "${m.kind}/${m.metadata.name}") ms)
    }";

  lib-consumers-consumer-stamps-its-namespaces =
    let
      ms = manifests consumer;
      ns = named "Namespace" "acme-app" ms;
      labels = (builtins.head ns).metadata.labels;
    in
    (
      builtins.length ns == 1
      && labels.${consumerLabel} == "acme"
      && labels."pod-security.kubernetes.io/enforce" == "restricted"
      && named "ResourceQuota" "acme-app-quota" (inNamespace "acme-app" ms) != [ ]
    )
    || throw "the consumer's namespace lacks its label, level or quota: ${builtins.toJSON ns}";

  # A namespace's quota is applied after the namespace, never before: a
  # first deploy that created both failed with "namespaces not found".
  lib-consumers-quota-waits-for-its-namespace =
    let
      ms = manifests consumer;
      dependsOn = m: m.metadata.annotations.${kixKeys.dependsOn} or "";
      ns = builtins.head (named "Namespace" "acme-app" ms);
      quota = builtins.head (named "ResourceQuota" "acme-app-quota" ms);
    in
    (dependsOn quota != "" && dependsOn ns == "")
    || throw "the quota must wait for its namespace, not the other way: namespace ${dependsOn ns}, quota ${dependsOn quota}";

  lib-consumers-record-names-the-interface =
    (recordOf consumer).spec.interfaces == {
      prod = {
        consumer = "acme";
        path = "kix/lib/tests/units/consumers/prod.json";
        sha256 = builtins.hashString "sha256" (
          builtins.toJSON (builtins.fromJSON (builtins.readFile fixture))
        );
      };
    }
    || throw "unexpected spec.interfaces: ${builtins.toJSON (recordOf consumer).spec}";

  # The fixture is reformatted JSON; the record pins it by the hash of the
  # file the platform writes, so `kix status` can compare the two records.
  lib-consumers-reformatted-copy-pins-the-platform-file =
    (recordOf consumer).spec.interfaces.prod.sha256 == (recordOf platform).spec.consumers.acme.sha256
    || throw "the pinned hash differs from the platform's file: ${builtins.toJSON (recordOf consumer).spec.interfaces}";

  # The platform's k8sVersion reaches the consumer through the interface
  # file, and the consumer's index names the platform, so a version mismatch
  # at deploy offers a new interface file as the fix. A consumer that sets
  # its own value overrides the file, and the index names no platform.
  lib-consumers-index-names-the-platform-that-set-k8s-version =
    let
      versioned = platformWith [
        grant
        { k8sVersion = "1.31"; }
      ];
      inherited = consumerWith { file = versioned.interfaces.acme; } [ ];
      overridden = consumerWith { file = versioned.interfaces.acme; } [ { k8sVersion = "1.32"; } ];
      kubernetesOf = cluster: cluster.packageIndexContent.kubernetes;
    in
    kubernetesOf inherited == {
      uid = null;
      version = "1.31";
      versionFrom = "prod";
    }
    &&
      kubernetesOf overridden == {
        uid = null;
        version = "1.32";
        versionFrom = null;
      }
    && (kubernetesOf consumer).versionFrom == null
    || throw "versionFrom: ${
      builtins.toJSON (
        map kubernetesOf [
          inherited
          overridden
          consumer
        ]
      )
    }";

  lib-consumers-interface-reads-in-modules =
    (consumer.instances.acme-app.db.out.fqdn == "db.dbns.svc.cluster.local")
    || throw "the db import does not carry the platform's out";

  # With an exact name among the patterns, the imports go there unasked;
  # with none, the consumer must name the namespace.
  lib-consumers-imports-namespace =
    let
      patternsOnly = fixtureWith (i: i // { namespaces = removeAttrs i.namespaces [ "acme-app" ]; });
      built = eval.buildCluster {
        name = "acme-prod";
        modules = [ (eval.interface fixture) ];
      };
      unnamed = eval.buildCluster {
        name = "acme-prod";
        modules = [ (eval.interface patternsOnly) ];
      };
    in
    (built.instances.acme-app.db.out.fqdn == "db.dbns.svc.cluster.local" && evalFails unnamed)
    || throw "imports did not go to the exact namespace, or went somewhere unnamed";

  lib-consumers-granted-cluster-object-builds = builtins.deepSeq (manifests (
    consumerWith { } [
      { instances.acme-app.reader.package = clusterRole "acme-reader"; }
    ]
  )) true;

  lib-consumers-ungranted-cluster-object-refused =
    evalFails (
      consumerWith { } [
        { instances.acme-app.admin.package = clusterRole "acme-admin"; }
      ]
    )
    || throw "a cluster-scoped object the interface does not allow was built";

  lib-consumers-namespace-matching-no-pattern-refused =
    evalFails (
      consumerWith { } [
        { instances.monitoring.extra.package = mkCmPackage { name = "extra"; }; }
      ]
    )
    || throw "an object in a namespace no pattern matches was built";

  # Name the namespace a refused Namespace would create, and a refused object
  # by the namespace it is in.
  lib-consumers-namespace-refusal-names-what-it-creates =
    let
      consumers = import ../../eval/consumers.nix {
        inherit lib;
        k8s = null;
        mkImport = null;
        instancePinsLib = null;
      };
      check = consumers.consumer {
        name = "acme-prod";
        cfg.interfaces.prod = builtins.fromJSON (builtins.readFile fixture) // {
          file = fixture;
        };
        self = null;
      };
      messages = map (a: a.message) (
        check.assertionsFor [
          {
            kind = "Namespace";
            metadata.name = "other-team";
          }
          {
            kind = "ConfigMap";
            metadata = {
              name = "extra";
              namespace = "other-team";
            };
          }
        ]
      );
    in
    messages == [
      "kix: acme-prod may not create Namespace other-team, which matches none of your namespaces (acme-*, acme-app)."
      "kix: ConfigMap other-team/extra is in namespace other-team, which matches none of your namespaces (acme-*, acme-app)."
    ]
    || throw "unexpected refusals: ${builtins.toJSON messages}";

  lib-consumers-platform-namespace-refused =
    evalFails (
      consumerWith
        {
          file = fixtureWith (
            i:
            i
            // {
              namespaces."*" = i.namespaces."acme-*";
            }
          );
        }
        [
          { instances.dbns.extra.package = mkCmPackage { name = "extra"; }; }
        ]
    )
    || throw "an object in the platform's namespace was built";

  lib-consumers-claimed-namespace-refused =
    let
      wildcard =
        modules:
        consumerWith {
          file = fixtureWith (
            i:
            i
            // {
              namespaces."*" = i.namespaces."acme-*";
              claimedNamespaces = [ "globex-*" ];
            }
          );
        } modules;
    in
    (
      evalFails (wildcard [
        { instances.globex-app.extra.package = mkCmPackage { name = "extra"; }; }
      ])
      && builtins.deepSeq (manifests (wildcard [
        { instances.other.extra.package = mkCmPackage { name = "extra"; }; }
      ])) true
    )
    || throw "the \"*\" holder built into another consumer's namespace";

  lib-consumers-unknown-version-refused =
    evalFails (consumerWith { file = fixtureWith (i: i // { version = 1; }); } [ ])
    || throw "an interface of version 1 was loaded";

  # The fixture's namespaces enforce "restricted": a baseline container
  # breaks it, so the build refuses it; a container that meets it builds.
  lib-consumers-pod-security-refuses-at-build =
    evalFails (consumerWith { } [ { instances.acme-app.echo.package = baselinePackage; } ])
    && builtins.deepSeq (manifests (
      consumerWith { } [
        {
          instances.acme-app.app.package = deploymentPackage {
            securityContext = {
              runAsNonRoot = true;
              allowPrivilegeEscalation = false;
              capabilities.drop = [ "ALL" ];
              seccompProfile.type = "RuntimeDefault";
            };
          };
        }
      ]
    )) true
    || throw "a baseline container built under \"restricted\", or a restricted container did not";

  # Under "baseline" or no level, a baseline container builds; a privileged
  # container still fails "baseline".
  lib-consumers-pod-security-follows-the-interface-level =
    let
      levelled =
        level: modules:
        consumerWith {
          file = fixtureWith (
            i:
            i
            // {
              namespaces = i.namespaces // {
                "acme-*" = i.namespaces."acme-*" // {
                  podSecurity = level;
                };
              };
            }
          );
        } modules;
      echo = [ { instances.acme-app.echo.package = baselinePackage; } ];
    in
    (
      builtins.deepSeq (manifests (levelled "baseline" echo)) true
      && builtins.deepSeq (manifests (levelled null echo)) true
      && evalFails (
        levelled "baseline" [
          { instances.acme-app.app.package = deploymentPackage { securityContext.privileged = true; }; }
        ]
      )
    )
    || throw "the check did not follow the interface's level";

  # An exact name inside a pattern adjusts that namespace: its quota keys
  # join the pattern's and its level replaces the pattern's. Other
  # namespaces the pattern matches keep the pattern's settings.
  lib-consumers-exact-name-adjusts-its-namespace =
    let
      cluster =
        consumerWith
          {
            file = fixtureWith (
              i:
              i
              // {
                namespaces = i.namespaces // {
                  acme-app = i.namespaces.acme-app // {
                    podSecurity = "baseline";
                    quota."requests.memory" = "2Gi";
                  };
                };
              }
            );
          }
          [
            { instances.acme-other.extra.package = mkCmPackage { name = "extra"; }; }
          ];
      ms = manifests cluster;
      hardOf = ns: (builtins.head (named "ResourceQuota" "${ns}-quota" ms)).spec.hard;
      levelOf =
        ns: (builtins.head (named "Namespace" ns ms)).metadata.labels."pod-security.kubernetes.io/enforce";
    in
    (
      hardOf "acme-app" == {
        pods = "10";
        "requests.memory" = "2Gi";
      }
      && hardOf "acme-other" == { pods = "10"; }
      && levelOf "acme-app" == "baseline"
      && levelOf "acme-other" == "restricted"
    )
    || throw "unexpected settings: acme-app ${builtins.toJSON (hardOf "acme-app")}, acme-other ${builtins.toJSON (hardOf "acme-other")}";

  lib-consumers-secret-under-pattern-refused =
    refused (platformWith [
      grant
      { consumers.acme.namespaces."acme-*".secrets = [ { name = "token"; } ]; }
    ])
    || throw "a Secret under a pattern was granted";

  lib-consumers-max-on-exact-name-refused =
    refused (platformWith [
      grant
      { consumers.acme.namespaces.acme-app.max = 2; }
    ])
    && !refused (platformWith [
      grant
      { consumers.acme.namespaces."acme-*".max = 2; }
    ])
    || throw "max on an exact name was granted, or max on a pattern refused";

  # One consumer's patterns may not match the same namespace; an exact name
  # inside a pattern may.
  lib-consumers-own-overlapping-patterns-refused =
    refused (platformWith [
      grant
      { consumers.acme.namespaces."acme-app-*" = { }; }
    ])
    && refused (platformWith [
      grant
      { consumers.acme.namespaces."*" = { }; }
    ])
    && !refused (platformWith [
      grant
      { consumers.acme.namespaces.acme-reports = { }; }
    ])
    || throw "overlapping patterns of one consumer were granted, or an exact name inside one refused";

  # `max` counts every namespace the build renders that matches the
  # pattern, exact names inside it included.
  lib-consumers-max-exceeded-refused =
    let
      limited = consumerWith {
        file = fixtureWith (
          i:
          i
          // {
            namespaces = i.namespaces // {
              "acme-*" = i.namespaces."acme-*" // {
                max = 1;
              };
            };
          }
        );
      };
    in
    (
      evalFails (limited [
        { instances.acme-other.extra.package = mkCmPackage { name = "extra"; }; }
      ])
      && builtins.deepSeq (manifests (limited [ ])) true
    )
    || throw "a build with more namespaces than max allows was built, or one within it was not";
}

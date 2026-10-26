# Tests for a platform cluster and the consumer clusters it hosts
# (eval/consumers.nix). The platform `lab1` grants consumer `acme` a
# namespace, the service dbns/db, a Secret and a ClusterRole, and writes
# acme's interface file. The consumer `lab1-acme` loads the copy checked in
# as ./consumers/lab1.json, which must equal what the platform writes.

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
  grant = {
    consumers.acme = {
      namespaces.acme-app = {
        resourceQuota.pods = "10";
        podSecurity = "restricted";
      };
      services = [ "dbns/db" ];
      secrets = [
        {
          name = "postgres";
          namespace = "acme-app";
          keys = [
            "password"
            "user"
          ];
        }
      ];
      clusterScoped = [
        {
          kind = "ClusterRole";
          name = "acme-reader";
        }
      ];
    };
    secretsRecipient = "age1test";
  };

  platformWith =
    modules:
    eval.buildCluster {
      name = "lab1";
      modules = [ baseInstances ] ++ modules;
    };

  platform = platformWith [ grant ];

  interfaceOf = cluster: builtins.fromJSON (builtins.readFile cluster.interfaces.acme);

  fixture = ./consumers/lab1.json;

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
      name ? "lab1-acme",
      file ? fixture,
    }:
    modules:
    eval.buildCluster {
      inherit name;
      modules = [
        (eval.interface file)
        { instances.acme-app.web.package = mkCmPackage { name = "web"; }; }
      ]
      ++ modules;
    };

  consumer = consumerWith { } [ ];

  inNamespace = ns: ms: builtins.filter (m: (m.metadata.namespace or null) == ns) ms;
  named =
    kind: name: ms:
    builtins.filter (m: m.metadata.name == name) (ofKind kind ms);
in
{
  lib-consumers-interface-shape =
    let
      i = interfaceOf platform;
      ns = i.namespaces.acme-app;
      db = i.services."dbns/db";
    in
    (
      i.version == 1
      && i.platform == "lab1"
      && i.consumer == "acme"
      && i.slice == "lab1-acme"
      && i.facts.clusterDomain == "cluster.local"
      && i.facts.networkPolicy == false
      && ns.podSecurity == "restricted"
      && ns.resourceQuota == { pods = "10"; }
      && builtins.elem {
        apiVersion = "v1";
        kind = "ResourceQuota";
        name = "acme-app-quota";
      } ns.platformObjects
      && db.namespace == "dbns"
      && db.instance == "db"
      && db.out.fqdn == "db.dbns.svc.cluster.local"
      && !(db.out ? url)
      &&
        i.secrets == [
          {
            name = "postgres";
            namespace = "acme-app";
            keys = [
              "password"
              "user"
            ];
            type = "Opaque";
          }
        ]
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
    || throw "kix/lib/tests/units/consumers/lab1.json is stale. Write it again from: ${builtins.readFile platform.interfaces.acme}";

  lib-consumers-platform-renders-the-namespace =
    let
      ms = manifests platform;
      ns = named "Namespace" "acme-app" ms;
    in
    (
      builtins.length ns == 1
      && (builtins.head ns).metadata.labels."pod-security.kubernetes.io/enforce" == "restricted"
      && named "ResourceQuota" "acme-app-quota" ms != [ ]
    )
    || throw "the platform did not render namespace acme-app with its quota";

  lib-consumers-record-names-the-consumers =
    (recordOf platform).spec.consumers == {
      acme = {
        slice = "lab1-acme";
        interface = builtins.unsafeDiscardStringContext (toString platform.interfaces.acme);
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
    let
      leaky = platformWith [
        grant
        {
          instances.dbns.leaky.package = mkCmPackage {
            name = "leaky";
            out.config = "${builtins.toFile "leaky.conf" "secret"}";
          };
          consumers.acme.services = [ "dbns/leaky" ];
        }
      ];
    in
    !(builtins.tryEval (builtins.deepSeq (interfaceOf leaky) true)).success
    || throw "an out value naming a store path reached the interface";

  lib-consumers-platform-namespace-not-grantable =
    evalFails (platformWith [
      grant
      { consumers.acme.namespaces.appns = { }; }
    ])
    || throw "a namespace the platform uses itself was granted";

  lib-consumers-unknown-service-refused =
    !(builtins.tryEval (
      builtins.deepSeq (interfaceOf (platformWith [
        grant
        { consumers.acme.services = [ "dbns/nope" ]; }
      ])) true
    )).success
    || throw "a service that is not an instance was granted";

  lib-consumers-ingress-only-with-network-policy =
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
          {
            namespaceSelector.matchExpressions = [
              {
                key = "kubernetes.io/metadata.name";
                operator = "In";
                values = [ "acme-app" ];
              }
            ];
          }
        ]
    )
    || throw "expected the ingress policy only with networkPolicy.enable; with it: ${builtins.toJSON on}";

  lib-consumers-consumer-builds =
    let
      ms = manifests consumer;
    in
    (
      named "ConfigMap" "web" (inNamespace "acme-app" ms) != [ ]
      && named "PackageInstance" "db" (inNamespace "acme-app" ms) != [ ]
      && ofKind "Namespace" ms == [ ]
      && consumer.name == "lab1-acme"
    )
    || throw "unexpected consumer manifests: ${
      builtins.toJSON (map (m: "${m.kind}/${m.metadata.name}") ms)
    }";

  lib-consumers-record-names-the-interface =
    (recordOf consumer).spec.interfaces == {
      lab1 = {
        consumer = "acme";
        path = "kix/lib/tests/units/consumers/lab1.json";
        sha256 = builtins.hashString "sha256" (
          builtins.toJSON (builtins.fromJSON (builtins.readFile fixture))
        );
      };
    }
    || throw "unexpected spec.interfaces: ${builtins.toJSON (recordOf consumer).spec}";

  # The fixture is reformatted JSON; the record pins it by the hash of the
  # file the platform writes, so a server can compare the two.
  lib-consumers-reformatted-copy-pins-the-platform-file =
    (recordOf consumer).spec.interfaces.lab1.sha256
    == builtins.hashFile "sha256" platform.interfaces.acme
    || throw "the pinned hash differs from the platform's file: ${builtins.toJSON (recordOf consumer).spec.interfaces}";

  lib-consumers-interface-reads-in-modules =
    (consumer.instances.acme-app.db.out.fqdn == "db.dbns.svc.cluster.local")
    || throw "the db import does not carry the platform's out";

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

  lib-consumers-object-outside-namespaces-refused =
    evalFails (
      consumerWith { } [
        { instances.monitoring.extra.package = mkCmPackage { name = "extra"; }; }
      ]
    )
    || throw "an object outside the granted namespaces was built";

  lib-consumers-platform-object-refused =
    evalFails (
      consumerWith { } [
        {
          instances.acme-app.quota.package = {
            meta.version = "test";
            build =
              { self, scope, ... }:
              {
                quota = scope.mkResource {
                  apiVersion = "v1";
                  kind = "ResourceQuota";
                  name = "acme-app-quota";
                };
                root = self.quota;
              };
          };
        }
      ]
    )
    || throw "an object the platform owns was built";

  lib-consumers-name-must-be-the-slice =
    evalFails (consumerWith { name = "acme"; } [ ])
    || throw "a consumer cluster not named lab1-acme was built";

  lib-consumers-unknown-version-refused =
    evalFails (
      consumerWith {
        file = builtins.toFile "lab1.json" (
          builtins.toJSON (builtins.fromJSON (builtins.readFile fixture) // { version = 2; })
        );
      } [ ]
    )
    || throw "an interface of version 2 was loaded";
}

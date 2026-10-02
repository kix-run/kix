# Tests for auto-instantiating a shelf package that runs once per cluster
# (a `cluster:<own key>` meta.conflictsWith entry, or a meta.roles claim).
# Auto-instantiation places it in the requesting namespace and refuses a
# cluster that would place it in more than one (eval/auto.nix
# spreadRefusals). A declared instance that answers the dependency serves
# every namespace. A declared instance that claims the same key without
# answering the consumer is refused by conflictsWith. Two instances that
# render the same cluster-scoped object, such as a CRD, fail evaluation
# (eval/cluster.nix sharedClusterObjectAssertions).

{
  lib,
  mkCluster,
  mkCmPackage,
  manifests,
  ofKind,
  byName,
  eval,
  ...
}:

let
  singleton = mkCmPackage {
    name = "op";
    metaExtra = {
      defaultAliases = [ "op" ];
      conflictsWith = [ "cluster:op" ];
    };
    out.who = "op";
  };

  # The same package without the marker: a plain shelf dependency, placed
  # once per requesting namespace.
  plain = mkCmPackage {
    name = "op";
    metaExtra.defaultAliases = [ "op" ];
    out.who = "op";
  };

  # A package that requires `op` and records the instance it got as
  # `<namespace>/<out.who>`.
  mkConsumer = name: {
    meta.version = "test";
    build =
      {
        self,
        scope,
        op,
        ...
      }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          inherit name;
          extra.data.who = "${op._meta.namespaceName or "?"}/${op.out.who}";
        };
        root = self.cm;
      };
  };

  consumer = mkConsumer "consumer";

  # A plain shelf package that requires `op`. Each namespace that demands
  # `mid` gets its own copy, which then demands `op`.
  middle = {
    meta = {
      version = "test";
      defaultAliases = [ "mid" ];
    };
    build =
      {
        self,
        scope,
        op,
        ...
      }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "mid";
        };
        root = self.cm;
      };
  };

  midConsumer = {
    meta.version = "test";
    build =
      {
        self,
        scope,
        mid,
        ...
      }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "mc";
        };
        root = self.cm;
      };
  };

  fails = cluster: !(builtins.tryEval (builtins.deepSeq (manifests cluster) true)).success;

  opNamespaces =
    ms:
    builtins.sort (a: b: a < b) (
      map (m: m.metadata.namespace) (builtins.filter (m: m.metadata.name == "op") (ofKind "ConfigMap" ms))
    );

  whoIn =
    ns: ms:
    (lib.findFirst (m: m.metadata.namespace == ns) { } (
      builtins.filter (m: m.metadata.name == "consumer") (ofKind "ConfigMap" ms)
    )).data.who or "missing";

  shelfWith = package: { availablePackages.op.package = package; };

  # A package that ships one CRD, with `metaExtra` merged into its meta. It
  # answers `op`, so `consumer` can depend on it.
  mkCrdOwner = metaExtra: {
    meta = {
      version = "test";
      defaultAliases = [ "op" ];
    }
    // metaExtra;
    build =
      { self, scope, ... }:
      {
        widgets = scope.mkCRD {
          spec = {
            group = "example.test";
            names = {
              kind = "Widget";
              plural = "widgets";
            };
            scope = "Namespaced";
            versions = [
              {
                name = "v1";
                served = true;
                storage = true;
                schema.openAPIV3Schema.type = "object";
              }
            ];
          };
        };
        root = {
          resource = self.widgets;
          out.who = "op";
        };
      };
  };

in
{
  # With no instance anywhere, the first consumer pulls the singleton into
  # its own namespace, and a second consumer there shares it.
  singleton-auto-one-namespace-instantiates =
    let
      ms = manifests (mkCluster [
        (shelfWith singleton)
        {
          instances.a.consumer.package = consumer;
          instances.a.other.package = mkConsumer "other";
        }
      ]);
    in
    (opNamespaces ms == [ "a" ] && whoIn "a" ms == "a/op")
    || throw "singleton not auto-instantiated once: ${builtins.toJSON (opNamespaces ms)}";

  # Consumers in a and b with no declared instance: auto-instantiation would
  # place op in both namespaces, so the cluster is refused.
  singleton-auto-two-namespaces-fail =
    fails (mkCluster [
      (shelfWith singleton)
      {
        instances.a.consumer.package = consumer;
        instances.b.consumer.package = consumer;
      }
    ])
    || throw "a singleton demanded from two namespaces evaluated";

  # A meta.roles claim makes a shelf package one per cluster too, also when
  # the demand names the package rather than the role.
  singleton-auto-role-claimer-two-namespaces-fail =
    let
      claimer = mkCmPackage {
        name = "op";
        metaExtra = {
          defaultAliases = [ "op" ];
          roles = [ "snapshotController" ];
        };
        out.who = "op";
      };
    in
    fails (mkCluster [
      (shelfWith claimer)
      {
        instances.a.consumer.package = consumer;
        instances.b.consumer.package = consumer;
      }
    ])
    || throw "a role-claiming shelf package demanded from two namespaces evaluated";

  # mid floats into a and b and requires op in each, which would place op
  # twice.
  singleton-auto-transitive-two-namespaces-fail =
    fails (mkCluster [
      {
        availablePackages = {
          op.package = singleton;
          mid.package = middle;
        };
        instances.a.mc.package = midConsumer;
        instances.b.mc.package = midConsumer;
      }
    ])
    || throw "a singleton demanded through mid from two namespaces evaluated";

  # Declaring op once answers mid's demand in every namespace.
  singleton-auto-transitive-declared-builds =
    let
      ms = manifests (mkCluster [
        {
          availablePackages = {
            op.package = singleton;
            mid.package = middle;
          };
          instances.ops.op.package = singleton;
          instances.a.mc.package = midConsumer;
          instances.b.mc.package = midConsumer;
        }
      ]);
    in
    opNamespaces ms == [ "ops" ]
    || throw "transitive declared op placed in ${builtins.toJSON (opNamespaces ms)}";

  # ops/myop replaces its default aliases, so it does not answer `op` and
  # the consumer's demand places a/op beside it. ops/myop's conflictsWith
  # entry refuses the cluster.
  singleton-auto-declared-instance-not-answering-fails =
    fails (mkCluster [
      (shelfWith singleton)
      {
        instances.ops.myop = {
          package = singleton;
          aliases = [ "other" ];
        };
        instances.a.consumer.package = consumer;
      }
    ])
    || throw "a second op beside a declared instance that does not answer `op` evaluated";

  # Two declared instances answer `op` in other namespaces, so the consumer
  # in c has more than one to bind to and resolution refuses it.
  singleton-auto-two-declared-instances-elsewhere-fail =
    fails (mkCluster [
      {
        instances.x.op.package = plain;
        instances.y.op.package = plain;
        instances.c.consumer.package = consumer;
      }
    ])
    || throw "a consumer with two candidate instances in other namespaces evaluated";

  # With autoNamespace, two singletons demanded from two namespaces are
  # each placed once, in that namespace.
  singleton-auto-two-singletons-auto-namespace =
    let
      op2 = mkCmPackage {
        name = "op2";
        metaExtra = {
          defaultAliases = [ "op2" ];
          conflictsWith = [ "cluster:op2" ];
        };
      };
      both = {
        meta.version = "test";
        build =
          {
            self,
            scope,
            op,
            op2,
            ...
          }:
          {
            cm = scope.mkResource {
              apiVersion = "v1";
              kind = "ConfigMap";
              name = "both";
            };
            root = self.cm;
          };
      };
      ms = manifests (mkCluster [
        {
          availablePackages = {
            op.package = singleton;
            op2.package = op2;
          };
          autoNamespace = "ops";
          instances.a.both.package = both;
          instances.b.both.package = both;
        }
      ]);
      op2Namespaces = map (m: m.metadata.namespace) (
        builtins.filter (m: m.metadata.name == "op2") (ofKind "ConfigMap" ms)
      );
    in
    (opNamespaces ms == [ "ops" ] && op2Namespaces == [ "ops" ])
    || throw "expected op and op2 once in ops, got ${builtins.toJSON (opNamespaces ms)} and ${builtins.toJSON op2Namespaces}";

  # An explicit binding to the instance in a also works.
  singleton-auto-bound-consumer-shares-instance =
    let
      ms = manifests (mkCluster [
        (shelfWith singleton)
        (
          { ref, ... }:
          {
            instances.a.consumer.package = consumer;
            instances.b.consumer = {
              package = consumer;
              deps.op = ref.a.op;
            };
          }
        )
      ]);
    in
    (opNamespaces ms == [ "a" ] && whoIn "b" ms == "a/op")
    || throw "bound consumer did not share the instance: ${builtins.toJSON (opNamespaces ms)}, b sees ${whoIn "b" ms}";

  # One declared instance answers consumers in every namespace.
  singleton-auto-declared-instance-serves-every-namespace =
    let
      ms = manifests (mkCluster [
        (shelfWith singleton)
        {
          instances.ops.op.package = singleton;
          instances.a.consumer.package = consumer;
          instances.b.consumer.package = consumer;
        }
      ]);
    in
    (opNamespaces ms == [ "ops" ] && whoIn "a" ms == "ops/op" && whoIn "b" ms == "ops/op")
    || throw "declared singleton not shared: ${builtins.toJSON (opNamespaces ms)}";

  # A shelf entry with a fixed namespace places the singleton once whoever
  # demands it.
  singleton-auto-fixed-shelf-namespace-builds =
    let
      ms = manifests (mkCluster [
        {
          availablePackages.op = {
            package = singleton;
            namespace = "ops";
          };
          instances.a.consumer.package = consumer;
          instances.b.consumer.package = consumer;
        }
      ]);
    in
    (opNamespaces ms == [ "ops" ] && whoIn "a" ms == "ops/op" && whoIn "b" ms == "ops/op")
    || throw "fixed-namespace singleton placed in ${builtins.toJSON (opNamespaces ms)}";

  # Each namespace's optional instance answers its own consumer, even though
  # the shelf entry for `op` runs once per cluster; the shelf is not used.
  singleton-auto-optional-per-namespace-selection =
    let
      ms = manifests (mkCluster [
        (shelfWith singleton)
        {
          instances.a.op = {
            package = plain;
            optional = true;
          };
          instances.b.op = {
            package = plain;
            optional = true;
          };
          instances.a.consumer.package = consumer;
          instances.b.consumer.package = consumer;
        }
      ]);
    in
    (whoIn "a" ms == "a/op" && whoIn "b" ms == "b/op")
    || throw "optional selection: a sees ${whoIn "a" ms}, b sees ${whoIn "b" ms}";

  # Without the marker, each namespace gets its own copy.
  singleton-auto-plain-package-placed-per-namespace =
    let
      ms = manifests (mkCluster [
        (shelfWith plain)
        {
          instances.a.consumer.package = consumer;
          instances.b.consumer.package = consumer;
        }
      ]);
    in
    opNamespaces ms == [
      "a"
      "b"
    ]
    || throw "plain shelf package placed in ${builtins.toJSON (opNamespaces ms)}";

  # One instance of a CRD owner evaluates without any conflictsWith entry;
  # two in different namespaces render the same CRD and fail.
  singleton-auto-shared-crd-fails =
    let
      owner = mkCrdOwner { };
    in
    (
      !(fails (mkCluster [ { instances.ops.op.package = owner; } ]))
      && fails (mkCluster [
        {
          instances.ops.op.package = owner;
          instances.ops2.op.package = owner;
        }
      ])
    )
    || throw "two instances rendering the same CRD evaluated, or one failed";

  # The same holds when auto-instantiation places a plain CRD owner once per
  # requesting namespace.
  singleton-auto-shared-crd-from-auto-instantiation-fails =
    fails (mkCluster [
      (shelfWith (mkCrdOwner { }))
      {
        instances.a.consumer.package = mkConsumer "consumer";
        instances.b.consumer.package = mkConsumer "consumer";
      }
    ])
    || throw "two auto-instantiated copies of a CRD owner evaluated";

  # Two instances that render identical ClusterRoles of the same name fail
  # too. Differing content would also fail the duplicate-resource check;
  # identical content would otherwise be deduplicated into one object.
  singleton-auto-shared-cluster-role-fails =
    let
      roleOwner = {
        meta.version = "test";
        build =
          { self, scope, ... }:
          {
            role = scope.mkClusterResource {
              apiVersion = "rbac.authorization.k8s.io/v1";
              kind = "ClusterRole";
              name = "shared";
              extra.rules = [
                {
                  apiGroups = [ "" ];
                  resources = [ "pods" ];
                  verbs = [ "get" ];
                }
              ];
            };
            root = self.role;
          };
      };
    in
    fails (mkCluster [
      {
        instances.a.r.package = roleOwner;
        instances.b.r.package = roleOwner;
      }
    ])
    || throw "two instances rendering an identical ClusterRole shared evaluated";
}

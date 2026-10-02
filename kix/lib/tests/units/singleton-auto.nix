# Tests for auto-instantiating a cluster singleton: a shelf package whose
# meta limits it to one instance per cluster (meta.clusterSingletonClaims).
# One consumer, or several in one namespace, still pulls it in. Consumers in
# two namespaces would place it twice, and a declared instance that claims
# the same slot without answering the consumer's key would get a second
# copy beside it. eval.planAutoInstances reports both as singletonConflicts,
# and computeAutoInstances refuses them.

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
  meta = import ../../meta.nix { inherit lib; };

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

  # eval.planAutoInstances over raw instance attrsets, without a cluster.
  plan =
    {
      instances,
      shelf ? {
        op.package = singleton;
      },
    }:
    eval.planAutoInstances {
      explicitInstances = instances;
      availablePackages = shelf;
      autoNamespace = null;
    };

  conflictsOf = args: (plan args).singletonConflicts;

  # tryEval in the test runner catches a throw but not an empty `head`.
  firstConflict = cs: if cs == [ ] then throw "no singleton conflict reported" else builtins.head cs;

  computeFails =
    instances:
    !(builtins.tryEval (
      eval.computeAutoInstances {
        explicitInstances = instances;
        availablePackages.op.package = singleton;
        autoNamespace = null;
      }
    )).success;

  hasLine = line: c: builtins.elem line (lib.splitString "\n" c.message);

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

  rules = import ../../rules { inherit lib; };

  # A package that ships one CRD, with `metaExtra` merged into its meta.
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
        root = self.widgets;
      };
  };

  crdRuleFindings =
    metaExtra:
    builtins.filter (f: f.rule == "architecture.crdOwnerIsClusterSingleton")
      (mkCluster [
        {
          scorecard.rules.architecture = { inherit (rules.architecture) crdOwnerIsClusterSingleton; };
          instances.ops.op.package = mkCrdOwner metaExtra;
        }
      ]).scorecardReport.findings;
in
{
  singleton-auto-markers =
    let
      markers =
        packageMeta:
        meta.clusterSingletonMarkers {
          inherit packageMeta;
          keys = [ "op" ];
        };
      cases = {
        selfConflict =
          markers { conflictsWith = [ "cluster:op" ]; } == [ "meta.conflictsWith = [ \"cluster:op\" ]" ];
        roleClaim = markers { roles = [ "dns" ]; } == [ "meta.roles = [ \"dns\" ]" ];
        otherPackage = markers { conflictsWith = [ "cluster:other" ]; } == [ ];
        namespaceConflict = markers { conflictsWith = [ "op" ]; } == [ ];
        none = markers { } == [ ];
      };
    in
    builtins.all lib.id (builtins.attrValues cases)
    || throw "clusterSingletonMarkers: ${builtins.toJSON cases}";

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

  # Consumers in a and b: one conflict naming both placements, with
  # declaring op once first and the binding for b second.
  singleton-auto-two-namespaces-conflict =
    let
      cs = conflictsOf {
        instances = {
          a.consumer.package = consumer;
          b.consumer.package = consumer;
        };
      };
      c = firstConflict cs;
      cases = {
        one = builtins.length cs == 1;
        name = c.name == "op";
        namespaces =
          map (p: p.ns) c.placements == [
            "a"
            "b"
          ];
        consumers =
          map (p: p.requester) c.placements == [
            "a/consumer"
            "b/consumer"
          ];
        dependency =
          map (p: p.depName) c.placements == [
            "op"
            "op"
          ];
        declared = c.declared == [ ];
        declareFirst =
          lib.hasInfix "Declare op once" c.message
          && lib.hasInfix "  instances.<namespace>.op.package = packages.op;" c.message
          && lib.hasPrefix "Declare op once" (builtins.elemAt (lib.splitString "\n" c.message) 3);
        binding = hasLine "  instances.b.consumer.deps.op = ref.a.op;" c;
        autoLabel = lib.hasInfix "the copy auto-instantiated as a/op" c.message;
      };
    in
    builtins.all lib.id (builtins.attrValues cases)
    || throw "two-namespace singleton conflict: ${builtins.toJSON cases}\n${c.message or ""}";

  # computeAutoInstances itself refuses the conflict; the later
  # conflictsWith assertion would refuse the cluster without it.
  singleton-auto-compute-refuses =
    computeFails {
      a.consumer.package = consumer;
      b.consumer.package = consumer;
    }
    && !(computeFails { a.consumer.package = consumer; });

  # mid floats into a and b and requires op there. The mid copies are
  # auto-instantiated, so the message marks them and prints no binding.
  singleton-auto-transitive-requester-has-no-binding =
    let
      c = firstConflict (conflictsOf {
        instances = {
          a.mc.package = midConsumer;
          b.mc.package = midConsumer;
        };
        shelf = {
          op.package = singleton;
          mid.package = middle;
        };
      });
      cases = {
        origins =
          map (p: p.origin) c.placements == [
            "a/mc"
            "b/mc"
          ];
        marked = hasLine "  b/op, for dependency 'op' of b/mid (auto-instantiated for b/mc)" c;
        noBinding = !(lib.hasInfix ".deps.op = ref." c.message);
        explained = lib.hasInfix "b/mid is auto-instantiated" c.message;
      };
    in
    builtins.all lib.id (builtins.attrValues cases)
    || throw "transitive singleton conflict: ${builtins.toJSON cases}\n${c.message or ""}";

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
  # the consumer's demand would place a/op beside it. The conflict names the
  # declared instance and both fixes.
  singleton-auto-declared-instance-not-answering =
    let
      cs = conflictsOf {
        instances = {
          ops.myop = {
            package = singleton;
            aliases = [ "other" ];
          };
          a.consumer.package = consumer;
        };
      };
      c = firstConflict cs;
      cases = {
        one = builtins.length cs == 1;
        declared = c.declared == [ "ops/myop" ];
        aliases = hasLine "  instances.ops.myop.aliases = [ \"other\" \"op\" ];" c;
        binding = hasLine "  instances.a.consumer.deps.op = ref.ops.myop;" c;
      };
    in
    builtins.all lib.id (builtins.attrValues cases)
    || throw "declared singleton conflict: ${builtins.toJSON cases}\n${c.message or ""}";

  # Two singletons, each demanded from two namespaces: both are reported.
  singleton-auto-reports-every-conflict =
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
      cs = conflictsOf {
        instances = {
          a.both.package = both;
          b.both.package = both;
        };
        shelf = {
          op.package = singleton;
          op2.package = op2;
        };
      };
    in
    map (c: c.name) cs == [
      "op"
      "op2"
    ]
    || throw "expected conflicts for op and op2, got ${builtins.toJSON (map (c: c.name) cs)}";

  # The binding the error recommends: the second consumer names the first
  # instance, so it places no demand of its own.
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

  # The other fix: one declared instance answers consumers in every
  # namespace.
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

  # The rule flags a CRD owner that is not marked one per cluster, and
  # passes one that is.
  singleton-auto-crd-owner-rule =
    let
      cases = {
        unmarked = builtins.length (crdRuleFindings { }) == 1;
        selfConflict = crdRuleFindings { conflictsWith = [ "cluster:op" ]; } == [ ];
        otherConflict =
          builtins.length (crdRuleFindings {
            conflictsWith = [ "cluster:other" ];
          }) == 1;
      };
    in
    builtins.all lib.id (builtins.attrValues cases)
    || throw "crdOwnerIsClusterSingleton: ${builtins.toJSON cases}";
}

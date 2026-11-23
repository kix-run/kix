# Tests that evaluation errors name the instance, the requester, and the
# dependency they are about, and give the reason and the fix:
# eval/resolve.nix `resolveArg` (an instance Kix added, a missing role),
# meta.nix (`deps.<name>.assertions` and `meta.conflictsWith`),
# scope/default.nix `forNamespace`, and eval/auto.nix `spreadRefusals`.
# Thrown messages are read from files loaded through `caught` (caught.nix).

{
  lib,
  k8s,
  kixlib,
  mkCluster,
  mkCmPackage,
  evalFails,
  ...
}:

let
  helpers = import ../caught.nix { inherit lib; };
  resolveCaught = helpers.caught ../../eval/resolve.nix { inherit lib kixlib; };
  meta = import ../../meta.nix { inherit lib; };
  autoCaught = helpers.caught ../../eval/auto.nix {
    inherit lib kixlib meta;
    resolve = import ../../eval/resolve.nix { inherit lib kixlib; };
    roles = import ../../eval/roles.nix { inherit lib; };
  };

  # The evaluator loaded so that a failed assertion does not stop the
  # build, which leaves `diagnostics.failedAssertions` readable.
  evalCaught = helpers.loadCaught ../../eval {
    inherit lib k8s;
    self = ../../../..;
  };
  mkClusterCaught =
    modules:
    evalCaught.buildCluster {
      name = "test";
      inherit modules;
    };

  missing =
    args:
    (resolveCaught.resolveArg (
      {
        resolutionIndex.byKey = { };
        requesterNamespace = "immich";
        hasDefault = false;
        explicitOverride = null;
        requester = "immich/valkey";
        requesterName = "valkey";
      }
      // args
    )).thrown or "";

  singleton = mkCmPackage {
    name = "op";
    metaExtra = {
      defaultAliases = [ "op" ];
      conflictsWith = [
        {
          key = "cluster:op";
          reason = "Its CRDs are cluster-wide.";
        }
      ];
    };
  };

  # A package that requires `op`.
  consumer = {
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
          name = "consumer";
        };
        root = self.cm;
      };
  };
in
{
  # An instance that auto-instantiation added keeps `<namespace>/<name>` in
  # `instance`, and the message says which instances made Kix add it.
  lib-eval-messages-missing-dep-names-auto-instantiator =
    let
      added = missing {
        argName = "valkeyPassword";
        addedFor = [ "immich/immich" ];
      };
      declared = missing { argName = "valkeyPassword"; };
      says = lib.hasInfix "Kix added it from availablePackages because immich/immich depends on it.";
    in
    (
      lib.hasPrefix "immich/valkey: dependency 'valkeyPassword'" added
      && says added
      && declared != ""
      && !(says declared)
    )
    || throw "missing dep of an added instance: ${added}";

  # A missing role names the packages that claim it and does not ask for an
  # instance named after the role in the requester's namespace.
  lib-eval-messages-missing-role-names-claimants =
    let
      text = missing { argName = "gatewayApi"; };
    in
    (
      lib.hasInfix "dependency 'gatewayApi' names a cluster role" text
      && lib.hasInfix "instances.<namespace>.<name>.package = packages.experimental.gateway-api;" text
      && lib.hasInfix "roles = [ \"gatewayApi\" ]" text
      && !(lib.hasInfix "instances.immich.gatewayApi" text)
    )
    || throw "missing role: ${text}";

  # An assertion from `deps.<name>.assertions` carries the dependency's name,
  # whatever name the contract gives it.
  lib-eval-messages-dependency-assertions-name-dependency =
    let
      result = meta.evaluatePackageDiagnostics {
        raw = { };
        evaluatedConfig = { };
        parts = { };
        resolvedDepMeta.otlpTraces.value = { };
        depsEnrichment.otlpTraces.assertions = _dep: [
          {
            assertion = false;
            message = "broken";
          }
        ];
        resolvedDeps.otlpTraces = { };
      };
    in
    (map (a: a.dependency or null) result.assertions == [ "otlpTraces" ])
    || throw "dependency assertions: ${builtins.toJSON result.assertions}";

  # A conflict gives the package's reason and says how to fix it.
  lib-eval-messages-conflict-gives-reason-and-fix =
    let
      cluster = mkClusterCaught [
        {
          instances.a.op.package = singleton;
          instances.b.op.package = singleton;
        }
      ];
      failed = builtins.filter (
        a: lib.hasInfix "It conflicts with 'op'" a.message
      ) cluster.diagnostics.failedAssertions;
    in
    (
      failed != [ ]
      && builtins.all (
        a:
        lib.hasInfix "The package gives this reason: Its CRDs are cluster-wide." a.message
        && lib.hasPrefix "Keep one instance that answers 'op' in the whole cluster" (a.fix or "")
      ) failed
    )
    || throw "conflict: ${builtins.toJSON failed}";

  # A conflictsWith entry that is neither a key nor `{ key; reason; }` fails.
  lib-eval-messages-conflict-entry-form =
    evalFails (mkCluster [
      {
        instances.a.op.package = mkCmPackage {
          name = "op";
          metaExtra.conflictsWith = [ { name = "cluster:op"; } ];
        };
      }
    ])
    || throw "a malformed conflictsWith entry was accepted";

  # forNamespace on a namespace the cluster does not have fails.
  lib-eval-messages-fornamespace-missing-namespace =
    evalFails (mkCluster [
      {
        instances.a.app.package = {
          meta.version = "test";
          build =
            { self, scope, ... }:
            {
              cm = (scope.forNamespace "nope").mkResource {
                apiVersion = "v1";
                kind = "ConfigMap";
                name = "app";
              };
              root = self.cm;
            };
        };
      }
    ])
    || throw "forNamespace accepted a missing namespace";

  # A package that runs once per cluster, demanded from two namespaces, is
  # refused with the same message form and fix as the refusal beside one
  # consumer.
  lib-eval-messages-spread-refusal =
    let
      text =
        (autoCaught.computeAutoInstances {
          explicitInstances = {
            a.consumer.package = consumer;
            b.consumer.package = consumer;
          };
          availablePackages.op.package = singleton;
          autoNamespace = null;
        }).thrown or "";
    in
    (
      lib.hasInfix "op runs once per cluster (meta.conflictsWith \"cluster:op\"), and nothing names its namespace. Kix would add it to 2 namespaces" text
      && lib.hasInfix "Or set autoNamespace to place every package Kix adds there." text
      && !(lib.hasInfix "kix: op" text)
    )
    || throw "spread refusal: ${text}";
}

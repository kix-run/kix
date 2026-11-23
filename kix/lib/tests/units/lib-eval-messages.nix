# Tests that evaluation errors name the instance, the requester, and the
# dependency they are about, and give the reason and the fix:
# eval/resolve.nix `resolveArg` (an instance Kix added, a missing role),
# meta.nix (`deps.<name>.assertions` and `meta.conflictsWith`),
# scope/default.nix `forNamespace`, vocab/contract.nix `require`, and
# eval/auto.nix (`spreadRefusals` and the ambiguous-provider refusal).
# Thrown messages are read from files loaded through `caught` (caught.nix).

{
  lib,
  k8s,
  kixlib,
  mkCmPackage,
  ofKind,
  byName,
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

  # The evaluator loaded so that `kix.fail` and `scope.fail` return
  # `{ thrown = <full text>; }`, whose first line names the instance.
  loadRaw =
    path:
    builtins.scopedImport {
      import = p: if baseNameOf p == "error.nix" then helpers.caught p else loadRaw p;
    } path;
  evalRaw = loadRaw ../../eval {
    inherit lib k8s;
    self = ../../../..;
  };

  contractCaught = helpers.caught ../../vocab/contract.nix { inherit lib; };
  gatewayLike = contractCaught.mkContract {
    name = "gateway";
    alias = "gateway";
    here = "test";
    fields.gatewayRef = {
      shape = "a string";
      test = builtins.isString;
    };
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
      says = lib.hasInfix "The cluster definition does not declare immich/valkey (auto-instantiated for immich/immich).";
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
      lib.hasInfix "dependency 'gatewayApi' is a cluster role" text
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
        lib.hasInfix "Reason: Its CRDs are cluster-wide." a.message
        && lib.hasPrefix "Remove either " (a.fix or "")
      ) failed
    )
    || throw "conflict: ${builtins.toJSON failed}";

  # A conflictsWith entry that is neither a key nor `{ key; reason; }` is
  # refused with the form it should take.
  lib-eval-messages-conflict-entry-form =
    let
      entries = (helpers.caught ../../meta.nix { inherit lib; }).conflictEntries {
        conflictsWith = [ { name = "cluster:op"; } ];
      };
      text = (builtins.head entries).thrown or "";
    in
    (
      lib.hasInfix "meta.conflictsWith contains an invalid entry: {\"name\":\"cluster:op\"}." text
      && lib.hasInfix "{ key = " text
    )
    || throw "conflictsWith entry form: ${text}";

  # forNamespace on a namespace the cluster does not have names the
  # instance that asked for it, and the namespaces the cluster has.
  lib-eval-messages-fornamespace-missing-namespace =
    let
      cluster = evalRaw.buildCluster {
        name = "test";
        modules = [
          {
            instances.a.app.package = {
              meta.version = "test";
              build =
                { self, scope, ... }:
                {
                  cm = scope.mkResource {
                    apiVersion = "v1";
                    kind = "ConfigMap";
                    name = "app";
                    extra.data.error = (scope.forNamespace "nope").namespace.thrown or "none";
                  };
                  root = self.cm;
                };
            };
          }
        ];
      };
      text = (byName "app" (ofKind "ConfigMap" cluster.rawManifests)).data.error;
    in
    (
      lib.hasPrefix "a/app: scope.forNamespace requested namespace 'nope', which does not exist in this cluster. Declared namespaces: a." text
      && lib.hasInfix "namespaces.nope = { };" text
    )
    || throw "forNamespace: ${text}";

  # A contract error raised through `require` names the dependency by the
  # contract's alias, and through `requireAs` by the name the consumer gives.
  lib-eval-messages-require-names-dependency =
    let
      dependencyOf = r: map (e: e.dependency or null) (helpers.records (r.thrown or ""));
      byAlias = gatewayLike.require "kix.expose (a/web)" { out = { }; };
      byGivenName = gatewayLike.requireAs "edge" "kix.expose (a/web)" { out = { }; };
    in
    (
      dependencyOf byAlias == [ "gateway" ]
      && dependencyOf byGivenName == [ "edge" ]
      && lib.hasInfix "kix.expose (a/web): for this dependency" (byAlias.thrown or "")
    )
    || throw "require: ${byAlias.thrown or ""} / ${byGivenName.thrown or ""}";

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
      lib.hasInfix "op runs once per cluster (meta.conflictsWith \"cluster:op\"), but no namespace is set for it, so Kix refused to auto-instantiate separate copies in 2 namespaces" text
      && lib.hasInfix "Or set `autoNamespace = \"<namespace>\";` (or `availablePackages.op.namespace`) to place auto-instantiated packages there." text
      && !(lib.hasInfix "kix: op" text)
    )
    || throw "spread refusal: ${text}";

  # When two availablePackages entries answer a dependency, the suggested
  # line for each declares the instance that auto-instantiation creates when
  # that entry is the only one: the same namespace, name, and aliases.
  lib-eval-messages-ambiguous-provider-keeps-instance =
    let
      pg = {
        meta = {
          version = "test";
          defaultAliases = [ "postgres" ];
        };
        build =
          { self, scope, ... }:
          {
            cm = scope.mkResource {
              apiVersion = "v1";
              kind = "ConfigMap";
              name = "pg";
            };
            root = self.cm;
          };
      };
      wanting = {
        meta.version = "test";
        build =
          {
            self,
            scope,
            postgres,
            ...
          }:
          {
            cm = scope.mkResource {
              apiVersion = "v1";
              kind = "ConfigMap";
              name = "app";
            };
            root = self.cm;
          };
      };
      withCatalog =
        availablePackages:
        autoCaught.computeAutoInstances {
          explicitInstances.shop.app.package = wanting;
          inherit availablePackages;
          autoNamespace = null;
        };
      one.db = {
        package = pg;
        aliases = [ "database" ];
      };
      created = (withCatalog one).autoInstances;
      ns = builtins.head (builtins.attrNames created);
      name = builtins.head (builtins.attrNames created.${ns});
      expected = "instances.${ns}.${name} = { package = <package for db>; optional = true; aliases = [ ${
        lib.concatMapStringsSep " " builtins.toJSON created.${ns}.${name}.aliases
      } ]; };";
      text = (withCatalog (one // { other.package = pg; })).thrown or "";
    in
    (
      ns == "shop"
      && name == "db"
      && lib.hasInfix "and 2 packages in availablePackages match 'postgres'" text
      && lib.hasInfix expected text
    )
    || throw "ambiguous provider: expected ${expected} in ${text}";
}

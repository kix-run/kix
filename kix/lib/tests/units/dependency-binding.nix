# Tests for the rules that decide which instance a dependency binds
# (eval/resolve.nix, eval/auto.nix, eval/cluster.nix phase 1): an instance
# never binds itself, a `deps` key the package does not take is refused, an
# inactive optional instance resolves nothing, and a post-hook that does not
# reach root gets a warning. Messages are read from eval/resolve.nix loaded
# through `caught`.

{
  lib,
  kixlib,
  mkCluster,
  mkCmPackage,
  manifests,
  ofKind,
  byName,
  evalFails,
  ...
}:

let
  caught = builtins.scopedImport {
    throw = message: { thrown = message; };
    import = path: if baseNameOf path == "error.nix" then caught path else import path;
  };
  resolveCaught = caught ../../eval/resolve.nix { inherit lib kixlib; };

  provider = mkCmPackage { name = "provider"; };

  # A package that takes `svc` and records the instance it bound.
  consumer = {
    meta.version = "test";
    build =
      {
        self,
        scope,
        svc,
        ...
      }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${scope.instanceName}-svc";
          extra.data.svc = svc._meta.instanceName;
        };
        root = self.cm;
      };
  };

  boundBy = name: cluster: (byName "${name}-svc" (ofKind "ConfigMap" (manifests cluster))).data.svc;

  # A package whose post-hook reads only a ConfigMap of its own, or also
  # its root when `reachesRoot` is true.
  hookPackage = reachesRoot: {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        main = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "main";
        };
        settings = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "settings";
        };
        hook = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "hook";
          extra.data = {
            settings = self.settings.out.name;
          }
          // lib.optionalAttrs reachesRoot { main = self.main.out.name; };
        };
        root = {
          resource = self.main;
          postHooks = [ self.hook ];
        };
      };
  };

  postHookWarned =
    reachesRoot:
    builtins.any (w: lib.hasPrefix "Post-hook ConfigMap/hook" (w.message or "")) (
      (mkCluster [ { instances.a.app.package = hookPackage reachesRoot; } ])
      .instances.a.app._diagnostics.warnings
    );
in
{
  # An instance that answers its own dependency name binds the other
  # instance that answers it.
  dependency-binding-skips-own-alias =
    let
      cluster = mkCluster [
        {
          instances.a.svc.package = provider;
          instances.a.app = {
            package = consumer;
            aliases = [ "svc" ];
          };
        }
      ];
    in
    boundBy "app" cluster == "svc" || throw "app bound ${boundBy "app" cluster}";

  # With no other instance answering the name, the dependency is missing,
  # and the build fails with an error instead of a stack overflow.
  dependency-binding-own-alias-alone-is-missing =
    let
      result = resolveCaught.resolveArg {
        argName = "svc";
        resolutionIndex.byKey.svc = [
          {
            namespace = "a";
            instName = "app";
            meta = { };
          }
        ];
        requesterNamespace = "a";
        requesterName = "app";
        requester = "a/app";
        hasDefault = false;
        explicitOverride = null;
      };
    in
    lib.hasInfix "dependency 'svc' has no matching instance in namespace 'a'" (result.thrown or "")
    || throw "own alias alone: ${builtins.toJSON result}";

  # A ref to the instance itself is refused.
  dependency-binding-self-ref-refused =
    let
      result = resolveCaught.resolveArg {
        argName = "svc";
        resolutionIndex.byKey = { };
        requesterNamespace = "a";
        requesterName = "app";
        requester = "a/app";
        hasDefault = false;
        explicitOverride = {
          _type = "kix-ref";
          namespace = "a";
          instanceName = "app";
        };
      };
    in
    lib.hasInfix "instances.a.app.deps.svc points to ref.a.app, which is the instance itself." (
      result.thrown or ""
    )
    || throw "self ref: ${builtins.toJSON result}";

  # A `deps` key the package does not take is refused, and the control with
  # the right key builds.
  dependency-binding-undeclared-key-refused =
    let
      withDeps =
        deps:
        mkCluster [
          (
            { ref, ... }:
            {
              instances.a.svc.package = provider;
              instances.a.app = {
                package = consumer;
                deps = deps ref;
              };
            }
          )
        ];
      result = resolveCaught.checkDepsKeys {
        mergedInstances.a.app = {
          package = consumer;
          deps.svcc = null;
        };
        phase1Instances.a.app = {
          discoveredDeps.svc.optional = false;
          depsEnrichment = { };
        };
      };
    in
    (
      evalFails (
        withDeps (ref: {
          svcc = ref.a.svc;
        })
      )
      && !(evalFails (
        withDeps (ref: {
          svc = ref.a.svc;
        })
      ))
      &&
        lib.hasInfix
          "[K3646] a/app: instances.a.app.deps.svcc is not a dependency of this instance's package, so Kix cannot wire 'svcc'. Valid dependencies for this package: svc."
          (result.thrown or "")
    )
    || throw "undeclared deps key: ${builtins.toJSON result}";

  # A key that a dependency had before a rename names the new name and the
  # rename's change record.
  dependency-binding-renamed-key-names-new-name =
    let
      result = resolveCaught.checkDepsKeys {
        mergedInstances.a.app = {
          package = consumer;
          deps.valkey = null;
        };
        phase1Instances.a.app = {
          discoveredDeps.redis.optional = true;
          depsEnrichment.redis.renamedFrom = {
            name = "valkey";
            id = "K9191";
          };
        };
      };
    in
    lib.hasInfix
      "[K9191] a/app: instances.a.app.deps.valkey uses an old dependency name. The package renamed it to 'redis', so Kix cannot wire it."
      (result.thrown or "")
    || throw "renamed deps key: ${builtins.toJSON result}";

  # An inactive optional instance whose required dependency has no active
  # provider does not fail the cluster.
  dependency-binding-dormant-instance-resolves-nothing =
    let
      cluster = mkCluster [
        {
          instances.a.base.package = provider;
          instances.a.app = {
            package = consumer;
            optional = true;
          };
          instances.a.svc = {
            package = provider;
            optional = true;
          };
        }
      ];
    in
    !(evalFails cluster) || throw "a dormant instance with an unmet dependency failed the cluster";

  # A post-hook that reaches only its own resources is reported, and one
  # that also reads root is not.
  dependency-binding-post-hook-warning =
    (postHookWarned false && !(postHookWarned true))
    || throw "post-hook warning: without root ${builtins.toJSON (postHookWarned false)}, with root ${builtins.toJSON (postHookWarned true)}";
}

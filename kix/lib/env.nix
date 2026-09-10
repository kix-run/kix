# lib/env.nix — `mkEnv`, which stamps instance sets into env-prefixed
# namespaces so one definition can describe several environments.
#
# The isolation is the namespace and nothing else. Each set becomes
# `"${envName}-${setName}"`, and `eval/auto.nix` resolves a non-role
# auto-instantiated dependency into `requesterNs`, so a package pulled in by
# `development-app` lands in `development-app` and the `production-app` copy
# is a separate instance. Two exceptions, both deliberate: a package that
# declares its own `namespace` in `availablePackages`, and a cluster that
# sets `autoNamespace`, are pinned there and therefore shared. Role-named
# deps are cluster-scoped by design (`auto.nix`: "two consumers in two
# namespaces share one provider"), so a role provider is shared across
# environments too.
#
# There used to be a second mechanism: every generated instance carried
# `_envScope = envName`, a resolution hint for an auto-install design that
# was going to scope by tag rather than by namespace (archive/06 §"The
# auto-install system needs to respect _envScope"). That design was not the
# one built. Nothing has ever read the attribute, and because it was never
# declared in the instance submodule, the module system refused every
# assignment of a `mkEnv` result to `instances`:
#
#   error: The option `instances.development-app.web._envScope' does not exist.
#
# So `mkEnv` has never worked for its documented purpose. The attribute is
# gone rather than declared, because declaring an unused field would only
# make the build pass while leaving two rival scoping stories in the tree.

{ lib }:

rec {

  mkEnv =
    envName: envConfig: instanceSets:
    let
      config = envConfig.config or { };
      overrides = envConfig.overrides or { };

      env = {
        name = envName;
        inherit config;
      };

      processSet =
        setName: setFn:
        let
          nsName = "${envName}-${setName}";
          rawInstances = setFn {
            ref = { };
            inherit env;
          };
          setOverrides = overrides.${setName} or { };
        in
        {
          name = nsName;
          value = lib.mapAttrs (
            instName: instConfig:
            let
              instOverrides = setOverrides.${instName} or { };
              mergedConfig =
                if instOverrides ? config then
                  (instConfig.config or { }) // instOverrides.config
                else
                  instConfig.config or { };
              mergedParts = if instOverrides ? parts then instOverrides.parts else instConfig.parts or null;
            in
            instConfig
            // {
              config = mergedConfig;
            }
            // lib.optionalAttrs (mergedParts != null) { parts = mergedParts; }
          ) rawInstances;
        };

    in
    builtins.listToAttrs (
      map (setName: processSet setName instanceSets.${setName}) (builtins.attrNames instanceSets)
    );

}

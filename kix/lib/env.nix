# Build instance sets under namespaces named "${envName}-${setName}".
# Each set function receives { env = { name; config; }; ref = {}; }.
# Per-instance overrides shallow-merge config and replace parts when supplied.
#
# In eval/auto.nix, non-role dependencies default to the requester's namespace.
# An availablePackages namespace or cluster autoNamespace overrides that default;
# role providers are shared across environments.

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

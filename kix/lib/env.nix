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
              _envScope = envName;
            }
            // lib.optionalAttrs (mergedParts != null) { parts = mergedParts; }
          ) rawInstances;
        };

    in
    builtins.listToAttrs (
      map (setName: processSet setName instanceSets.${setName}) (builtins.attrNames instanceSets)
    );

}

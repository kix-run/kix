# v2 environment stamping — mkEnv.
#
# Stamps instance sets into namespaces prefixed by environment name.
# Enables running the same services in dev/staging/prod with different configs.

{ lib }:

rec {

  # Stamps instance sets into env-prefixed namespaces.
  #
  # mkEnv "dev" { config = {...}; overrides = {...}; } { app = appStack; data = dataStack; }
  #
  # Produces:
  #   { "dev-app" = { api = ...; worker = ...; };
  #     "dev-data" = { postgres = ...; }; }
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
          # Call the instance set function
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
              # Merge config overrides
              mergedConfig =
                if instOverrides ? config then
                  (instConfig.config or { }) // instOverrides.config
                else
                  instConfig.config or { };
              # Apply parts override if present
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

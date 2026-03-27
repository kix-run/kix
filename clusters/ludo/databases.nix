# Databases — shared Postgres (StackGres) with Immich extensions.
# Valkey auto-instantiates with defaults via availablePackages.

{
  packages,
  ...
}:
{
  config.instances.data.postgres = {
    package = packages.stackgres-cluster;
    aliases = [ "postgres" ];
    config = {
      instances = 1;
      postgres = {
        version = "16";
        extensions = [
          {
            name = "vectors";
            publisher = "tensorchord";
            version = "0.3.0";
          }
        ];
      };
      storage.size = "50Gi";
      instanceProfile = {
        cpu = "2";
        memory = "2Gi";
      };
    };
  };
}

# The half of the swap fixture that must not notice the swap: Metabase,
# which reads its application database through `deps.database` and asks it
# for the citext extension. Called with `packages` by stackgres.nix and
# cnpg.nix, which each add a PostgreSQL provider and a `database` instance
# named metabase-db.
{ packages }:
# region:postgresSwapConsumer
{
  instances.app = {
    metabase.package = packages.metabase;
    metabase-encryption-key = {
      package = packages.secret;
      aliases = [ "encryptionKey" ];
      # Test values only.
      config.stringData.key = "0123456789abcdef0123456789abcdef";
    };
  };
}
# endregion:postgresSwapConsumer

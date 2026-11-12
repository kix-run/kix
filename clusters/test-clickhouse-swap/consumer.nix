# The half of the swap fixture that must not notice the swap: a database on
# "whatever answers clickhouse" and an application that reads its address
# and credentials from it. Called with `packages` by both bare.nix and
# replicated.nix.
{ packages }:
{
  instances.app = {
    events-db = {
      package = packages.experimental.clickhouse-database;
      config = {
        database = "events";
        user = "events";
        privileges = [
          "INSERT"
          "SELECT"
        ];
        schema."01-events.sql" = ''
          CREATE TABLE IF NOT EXISTS {database:Identifier}.events ON CLUSTER '{cluster}'
          (ts DateTime, message String)
          ENGINE = ReplicatedMergeTree ORDER BY ts
        '';
      };
    };
    events-db-password = {
      package = packages.secret;
      aliases = [ "password" ];
      config = {
        source = ../dev-secrets/swap-fixture-db.sops.yaml;
        hash = "sha256-S6OA4+BOL7HbLYUJCq1lhtu/Z8pg2Um/ws0nhRFUSWc=";
        keys = [ "password" ];
      };
    };

    consumer.package = {
      meta.version = "test";
      build =
        {
          self,
          scope,
          kix,
          clickhouseDatabase,
          ...
        }:
        {
          root = self.deployment;
          deployment = scope.mkDeployment {
            name = "consumer";
            spec = {
              selector.matchLabels = scope.selectorLabels;
              template.spec.containers = [
                {
                  name = "consumer";
                  image = "example/consumer:1";
                  securityContext = {
                    runAsNonRoot = true;
                    runAsUser = 1000;
                    allowPrivilegeEscalation = false;
                    capabilities.drop = [ "ALL" ];
                  };
                  env = kix.mkEnvVars {
                    CLICKHOUSE_URL = clickhouseDatabase.out.httpUrl;
                    CLICKHOUSE_NATIVE = clickhouseDatabase.out.nativeEndpoint;
                    CLICKHOUSE_DATABASE = clickhouseDatabase.out.database;
                    CLICKHOUSE_USER = clickhouseDatabase.out.username;
                    CLICKHOUSE_PASSWORD = clickhouseDatabase.out.credentials.out.keyRef "password";
                  };
                }
              ];
            };
          };
        };
    };
  };
}

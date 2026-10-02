# Tests for kix/packages/metabase: the variables the package owns, the
# metrics toggle and the prometheus dependency, the encryption key check,
# the checksum annotations, and the citext request. Metabase runs in
# namespace `bi` with a database stub and a `secret` encryption key.

{
  lib,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  ...
}:

let
  metabasePackage = import ../../../packages/metabase;
  secretPackage = import ../../../packages/secret;

  # A `database` provider with stackgres-database's out shape. Its
  # ConfigMap records the extensions consumers ask for.
  databasePackage =
    { lib, ... }:
    {
      meta = {
        version = "test";
        description = "database stub";
        owner = "test";
        defaultAliases = [ "database" ];
      };
      options = {
        extensions = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
        };
        password = lib.mkOption {
          type = lib.types.str;
          default = "pw";
        };
      };
      build =
        {
          self,
          config,
          scope,
          ...
        }:
        {
          credentials = scope.mkSecret {
            name = "db-credentials";
            keys = [
              "username"
              "password"
            ];
            stringData = {
              username = "metabase";
              password = config.password;
            };
          };
          extensionsCm = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "db-extensions";
            data.extensions = lib.concatStringsSep "," config.extensions;
          };
          root = {
            resource = self.credentials;
            out = {
              host = "db.bi.svc";
              port = 5432;
              database = "metabase";
              credentials = self.credentials;
            };
          };
        };
    };

  # A prometheus provider whose builders render their arguments.
  prometheusStub = {
    meta = {
      version = "test";
      defaultAliases = [ "prometheus" ];
    };
    build =
      { self, scope, ... }:
      let
        as =
          kind: consumerScope: args:
          consumerScope.mkResource (
            args
            // {
              apiVersion = "monitoring.coreos.com/v1";
              inherit kind;
            }
          );
      in
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "prometheus";
        };
        root = {
          resource = self.cm;
          out = {
            mkServiceMonitor = as "ServiceMonitor";
            mkPrometheusRule = as "PrometheusRule";
          };
        };
      };
  };

  clusterWith =
    {
      config ? { },
      keyData ? {
        key = "0123456789abcdef";
      },
      dbPassword ? "pw",
      prometheus ? false,
    }:
    mkCluster [
      {
        instances.bi = {
          metabase = {
            package = metabasePackage;
            inherit config;
          };
          metabase-db = {
            package = databasePackage;
            config.password = dbPassword;
          };
          metabase-key = {
            package = secretPackage;
            aliases = [ "encryptionKey" ];
            config.stringData = keyData;
          };
        };
      }
      (lib.optionalAttrs prometheus {
        instances.monitoring.prometheus.package = prometheusStub;
      })
    ];

  deploymentOf = cluster: byName "metabase" (ofKind "Deployment" (manifests cluster));
  containerOf = cluster: builtins.head (deploymentOf cluster).spec.template.spec.containers;
  envOf =
    cluster:
    builtins.listToAttrs (
      map (e: {
        inherit (e) name;
        value = e.value or e.valueFrom;
      }) (containerOf cluster).env
    );
  containerPortsOf = cluster: map (p: p.name) (containerOf cluster).ports;
  servicePortsOf =
    cluster: map (p: p.name) (byName "metabase" (ofKind "Service" (manifests cluster))).spec.ports;
  hasServiceMonitor = cluster: ofKind "ServiceMonitor" (manifests cluster) != [ ];
  annotationsOf = cluster: (deploymentOf cluster).spec.template.metadata.annotations;
in
{
  # Metrics on (the default) without a prometheus dependency: the container
  # serves metrics, the Service and ServiceMonitor leave them out. Adding the
  # dependency adds the Service port and the ServiceMonitor and leaves the
  # pod template unchanged.
  metabase-prometheus-leaves-pod-template =
    let
      plain = clusterWith { };
      scraped = clusterWith { prometheus = true; };
    in
    (
      (envOf plain).MB_PROMETHEUS_SERVER_PORT == "9191"
      &&
        containerPortsOf plain == [
          "http"
          "metrics"
        ]
      && servicePortsOf plain == [ "http" ]
      && !(hasServiceMonitor plain)
      &&
        servicePortsOf scraped == [
          "http"
          "metrics"
        ]
      && hasServiceMonitor scraped
      && (deploymentOf plain).spec.template == (deploymentOf scraped).spec.template
    )
    || throw "metabase metrics: plain ${builtins.toJSON (deploymentOf plain).spec.template} scraped ${builtins.toJSON (deploymentOf scraped).spec.template}";

  # metrics.enabled = false removes the variable, the container port, the
  # Service port, and the ServiceMonitor, and refuses the variable in env.
  metabase-metrics-disabled =
    let
      off = clusterWith {
        prometheus = true;
        config.metrics.enabled = false;
      };
    in
    (
      !((envOf off) ? MB_PROMETHEUS_SERVER_PORT)
      && containerPortsOf off == [ "http" ]
      && servicePortsOf off == [ "http" ]
      && !(hasServiceMonitor off)
      && evalFails (clusterWith {
        config.metrics.enabled = false;
        config.env.MB_PROMETHEUS_SERVER_PORT = "9000";
      })
    )
    || throw "metabase metrics.enabled = false: env ${builtins.toJSON (envOf off)}";

  # Every variable the package owns throws when env sets it, also to null.
  metabase-owned-env-refused =
    let
      refused =
        builtins.filter
          (
            name:
            !(evalFails (clusterWith {
              config.env.${name} = "x";
            }))
          )
          [
            "MB_DB_TYPE"
            "MB_DB_HOST"
            "MB_DB_PASS"
            "MB_DB_CONNECTION_URI"
            "MB_DB_CONNECTION_URI_FILE"
            "MB_DB_USER_FILE"
            "MB_DB_PASS_FILE"
            "MB_ENCRYPTION_SECRET_KEY"
            "MB_JETTY_HOST"
            "MB_JETTY_PORT"
            "MB_PROMETHEUS_SERVER_PORT"
          ];
    in
    (
      refused == [ ]
      && evalFails (clusterWith {
        config.env.MB_DB_HOST = null;
      })
    )
    || throw "metabase env accepted owned names: ${builtins.toJSON refused}";

  # The defaults (anonymous tracking off, the heap setting, the site URL)
  # yield to env, and null removes them.
  metabase-env-defaults-overridable =
    let
      base = envOf (clusterWith { });
      over = envOf (clusterWith {
        config.env = {
          MB_ANON_TRACKING_ENABLED = "true";
          JAVA_OPTS = "-Xmx3g";
          MB_SITE_URL = "https://bi.example.org";
        };
      });
      dropped = envOf (clusterWith {
        config.env.JAVA_OPTS = null;
      });
    in
    (
      base.MB_ANON_TRACKING_ENABLED == "false"
      && base.JAVA_OPTS == "-XX:MaxRAMPercentage=50"
      && !(base ? MB_SITE_URL)
      && over.MB_ANON_TRACKING_ENABLED == "true"
      && over.JAVA_OPTS == "-Xmx3g"
      && over.MB_SITE_URL == "https://bi.example.org"
      && !(dropped ? JAVA_OPTS)
    )
    || throw "metabase env defaults: base ${builtins.toJSON base}, over ${builtins.toJSON over}";

  # An encryption key secret without the key `key` fails the build.
  metabase-encryption-key-checked = evalFails (clusterWith {
    keyData.value = "0123456789abcdef";
  });

  # A new key moves only checksum/encryption-key; a new database password
  # moves only checksum/database.
  metabase-checksums-move-alone =
    let
      base = annotationsOf (clusterWith { });
      newKey = annotationsOf (clusterWith {
        keyData.key = "fedcba9876543210";
      });
      newPassword = annotationsOf (clusterWith {
        dbPassword = "other";
      });
    in
    (
      base ? "checksum/database"
      && base ? "checksum/encryption-key"
      && newKey."checksum/database" == base."checksum/database"
      && newKey."checksum/encryption-key" != base."checksum/encryption-key"
      && newPassword."checksum/encryption-key" == base."checksum/encryption-key"
      && newPassword."checksum/database" != base."checksum/database"
    )
    || throw "metabase checksums: base ${builtins.toJSON base}, key ${builtins.toJSON newKey}, password ${builtins.toJSON newPassword}";

  # The package asks its database for citext.
  metabase-requests-citext =
    let
      cm = byName "db-extensions" (ofKind "ConfigMap" (manifests (clusterWith { })));
    in
    cm.data.extensions == "citext" || throw "metabase citext: ${builtins.toJSON cm}";
}

# Tests for kix/packages/plausible: the variables the package owns, the
# routed or explicit BASE_URL, the privileges it asks of its
# clickhouse-database and the ClickHouse stand-ins it refuses, the citext
# request and sslmode, the migrations and replicate init container on a
# replicated server, the secretKeyBase key check, the smtpPassword
# pairing with SMTP_USER_NAME, literal credentials in env, the mail relay
# egress, the checksum annotations, and two instances in two namespaces.
# Also clickhouse-database's check on its grants keys.
#
# Plausible runs in namespace `web` with a database stub. The ClickHouse
# server runs in `events`, reached through a real clickhouse-database.
# Nothing routes to the instance, so BASE_URL comes from env. tryEval
# drops a throw's message, so each refusal is checked with evalFails beside
# a passing control, and assertion texts by calling the dependency's
# assertions function.

{
  lib,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  storageClassImport,
  netpolOn,
  ...
}:

let
  plausiblePackage = import ../../../packages/plausible;
  secretPackage = import ../../../packages/secret;
  clickhousePackage = import ../../../packages/clickhouse;
  facadePackage = import ../../../packages/clickhouse-database;
  pvcPackage = import ../../../packages/persistent-volume-claim;

  # A `database` provider with cnpg-database's out shape. Its ConfigMap
  # records the extensions consumers ask for.
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
        tls = lib.mkOption {
          type = lib.types.nullOr lib.types.bool;
          default = null;
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
            name = "${scope.instanceName}-credentials";
            keys = [
              "username"
              "password"
            ];
            stringData = {
              username = "plausible";
              password = config.password;
            };
          };
          extensionsCm = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "${scope.instanceName}-extensions";
            data.extensions = lib.concatStringsSep "," config.extensions;
          };
          root = {
            resource = self.credentials;
            out = {
              host = "db.${scope.namespaceName}.svc";
              port = "5432";
              database = "plausible";
              credentials = self.credentials;
              inherit (config) tls;
            };
          };
        };
    };

  # A `clickhouseDatabase` provider whose out is given whole, for the
  # refusals. It ignores the config Plausible injects, as a stand-in does.
  facadeStub =
    out:
    { lib, ... }:
    {
      meta = {
        version = "test";
        description = "clickhouse-database stub";
        owner = "test";
        defaultAliases = [ "clickhouseDatabase" ];
      };
      options.grants = lib.mkOption {
        type = lib.types.attrsOf (lib.types.listOf lib.types.str);
        default = { };
      };
      build =
        { self, scope, ... }:
        {
          credentials = scope.mkSecret {
            name = "events-credentials";
            keys = [
              "username"
              "password"
            ];
            stringData = {
              username = "plausible";
              password = "pw";
            };
          };
          root = {
            resource = self.credentials;
            out = {
              host = "ch.${scope.namespaceName}.svc";
              ports = {
                http = "8123";
                native = "9000";
              };
              database = "plausible_events";
              credentials = self.credentials;
            }
            // out;
          };
        };
    };

  goodFacadeOut = {
    replicas = "1";
    privileges = [ "ALL" ];
    grants = {
      "*.*" = [
        "CREATE FUNCTION"
        "DROP FUNCTION"
        "CLUSTER"
      ];
      "system.replicas" = [ "SELECT" ];
      "system.parts" = [ "SELECT" ];
      "system.tables" = [ "SELECT" ];
      "system.columns" = [ "SELECT" ];
      "system.functions" = [ "SELECT" ];
      "system.clusters" = [ "SELECT" ];
    };
  };

  # The facade's out on a server with two replicas.
  twoReplicaFacadeOut = goodFacadeOut // {
    replicas = "2";
    replicaHosts = [
      "ch-0.events.svc"
      "ch-1.events.svc"
    ];
  };

  # The ClickHouse server in `events`, with its claim and credentials.
  clickhouseServer = {
    instances.events = {
      clickhouse.package = clickhousePackage;
      storage = {
        package = pvcPackage;
        config = {
          size = "1Gi";
          storageClassName = "standard";
        };
      };
      standard-class = storageClassImport "standard";
      credentials = {
        package = secretPackage;
        aliases = [ "credentials" ];
        config.stringData.password = "test-admin";
      };
    };
  };

  # One Plausible and its dependencies in namespace `ns`. `facade` is null
  # for the real clickhouse-database, or a facadeStub out.
  plausibleIn =
    {
      ns,
      config ? {
        env.BASE_URL = "https://plausible.example.org";
      },
      keyData ? {
        key = "0123456789abcdef0123456789abcdef";
      },
      dbPassword ? "pw",
      dbTls ? null,
      facade ? null,
      facadeConfig ? { },
      smtp ? false,
    }:
    {
      instances.${ns} = {
        plausible = {
          package = plausiblePackage;
          inherit config;
        };
        plausible-db = {
          package = databasePackage;
          config = {
            password = dbPassword;
            tls = dbTls;
          };
        };
        plausible-events =
          if facade == null then
            {
              package = facadePackage;
              config = {
                password = "events-pw";
              }
              // facadeConfig;
            }
          else
            { package = facadeStub facade; };
        plausible-key = {
          package = secretPackage;
          aliases = [ "secretKeyBase" ];
          config.stringData = keyData;
        };
      }
      // lib.optionalAttrs smtp {
        plausible-smtp = {
          package = secretPackage;
          aliases = [ "smtpPassword" ];
          config.stringData.password = "smtp-pw";
        };
      };
    };

  clusterWith =
    {
      netpol ? false,
      ...
    }@args:
    mkCluster [
      clickhouseServer
      (plausibleIn ({ ns = "web"; } // removeAttrs args [ "netpol" ]))
      (lib.optionalAttrs netpol netpolOn)
    ];

  deploymentOf = cluster: byName "plausible" (ofKind "Deployment" (manifests cluster));
  podSpecOf = cluster: (deploymentOf cluster).spec.template.spec;
  envOf =
    container:
    builtins.listToAttrs (
      map (e: {
        inherit (e) name;
        value = e.value or e.valueFrom;
      }) container.env
    );
  mainEnvOf = cluster: envOf (builtins.head (podSpecOf cluster).containers);
  annotationsOf = cluster: (deploymentOf cluster).spec.template.metadata.annotations;

  # The assertions Plausible holds its clickhouseDatabase to, called on a
  # dependency view with the given out.
  facadeMessages =
    out:
    let
      pkg = plausiblePackage {
        scope = {
          instanceName = "plausible";
          namespaceName = "web";
        };
        inherit lib;
        kix = { };
      };
    in
    map (a: a.message) (pkg.deps.clickhouseDatabase.assertions { inherit out; });
in
{
  # The migrate init container gets the same environment and mounts as the
  # server, and the URLs expand the credentials defined before them.
  plausible-migrate-matches-server =
    let
      spec = podSpecOf (clusterWith { });
      init = builtins.head spec.initContainers;
      main = builtins.head spec.containers;
      names = map (e: e.name) main.env;
      indexOf = n: lib.lists.findFirstIndex (x: x == n) null names;
    in
    (
      init.args == [
        "db"
        "migrate"
      ]
      && init.env == main.env
      && init.volumeMounts == main.volumeMounts
      && indexOf "PLAUSIBLE_PG_PASSWORD" < indexOf "DATABASE_URL"
      && indexOf "PLAUSIBLE_CH_PASSWORD" < indexOf "CLICKHOUSE_DATABASE_URL"
      &&
        (envOf main).CLICKHOUSE_DATABASE_URL
        == "http://$(PLAUSIBLE_CH_USERNAME):$(PLAUSIBLE_CH_PASSWORD)@clickhouse.events.svc.cluster.local:8123/plausible_events"
    )
    || throw "plausible migrate: init ${builtins.toJSON init}, main ${builtins.toJSON main}";

  # Every variable the package owns throws when env sets it, also to null.
  plausible-owned-env-refused =
    let
      refused =
        builtins.filter
          (
            name:
            !(evalFails (clusterWith {
              config.env = {
                BASE_URL = "https://plausible.example.org";
                ${name} = "x";
              };
            }))
          )
          [
            "DATABASE_URL"
            "DATABASE_SOCKET_DIR"
            "PLAUSIBLE_PG_PASSWORD"
            "CLICKHOUSE_DATABASE_URL"
            "PLAUSIBLE_CH_USERNAME"
            "SECRET_KEY_BASE"
            "LISTEN_IP"
            "HTTP_PORT"
            "PORT"
            "HTTPS_PORT"
            "CONFIG_DIR"
            "DATA_DIR"
            "PERSISTENT_CACHE_DIR"
            "DEFAULT_DATA_DIR"
            "RELEASE_DISTRIBUTION"
          ];
    in
    (
      refused == [ ]
      && evalFails (clusterWith {
        config.env = {
          BASE_URL = "https://plausible.example.org";
          DATABASE_URL = null;
        };
      })
    )
    || throw "plausible env accepted owned names: ${builtins.toJSON refused}";

  # BASE_URL is required: nothing routes here, so leaving env.BASE_URL out
  # fails; setting it (the default of clusterWith) is the control.
  plausible-base-url-required =
    (
      evalFails (clusterWith {
        config = { };
      })
      && (mainEnvOf (clusterWith { })).BASE_URL == "https://plausible.example.org"
    )
    || throw "plausible BASE_URL: ${builtins.toJSON (mainEnvOf (clusterWith { }))}";

  # The package asks its database for citext, and its clickhouse-database
  # for CREATE FUNCTION on every database and SELECT on system.replicas,
  # which the bootstrap grants.
  plausible-requests-privileges =
    let
      cluster = clusterWith { };
      cm = byName "plausible-db-extensions" (ofKind "ConfigMap" (manifests cluster));
      sql =
        (byName "plausible-events-web-bootstrap" (ofKind "ConfigMap" (manifests cluster)))
        .data."bootstrap.sql";
    in
    (
      cm.data.extensions == "citext"
      && lib.hasInfix "GRANT ON CLUSTER '{cluster}' CREATE FUNCTION, DROP FUNCTION, CLUSTER ON *.* TO `plausible_events`;" sql
      && lib.hasInfix "GRANT ON CLUSTER '{cluster}' SELECT ON system.replicas TO `plausible_events`;" sql
    )
    || throw "plausible privileges: extensions ${builtins.toJSON cm.data}, sql ${sql}";

  # A clickhouse-database whose user lacks ALL on its database, or one of
  # the grants outside it, is refused; the facade's defaults with the
  # injected grants are the control.
  plausible-refuses-narrow-privileges =
    (
      evalFails (clusterWith {
        facadeConfig.privileges = [ "SELECT" ];
      })
      && evalFails (clusterWith {
        facade = goodFacadeOut // {
          privileges = [ "SELECT" ];
        };
      })
      && evalFails (clusterWith {
        facade = goodFacadeOut // {
          grants."*.*" = [ "CREATE FUNCTION" ];
        };
      })
      && !(evalFails (clusterWith {
        facade = goodFacadeOut;
      }))
    )
    || throw "plausible privileges: a narrow clickhouseDatabase was accepted";

  # On two replicas the migrate container tries each replica's address in
  # order and writes the one it uses to a shared in-memory volume, the
  # replicate init container reads it there and runs its script from a
  # ConfigMap, and the server keeps the load-balanced host. On one replica
  # (the real facade on the bare server) migrate runs `db migrate` against
  # that host and neither the container, the volume, nor the ConfigMap
  # renders.
  plausible-replicated-clickhouse =
    let
      two = clusterWith { facade = twoReplicaFacadeOut; };
      one = clusterWith { };
      inits = cluster: (podSpecOf cluster).initContainers;
      initNamed = cluster: n: builtins.head (builtins.filter (c: c.name == n) (inits cluster));
      migrate = initNamed two "migrate";
      replicate = initNamed two "replicate";
      mountsOf = c: map (m: m.name) c.volumeMounts;
      volumesOf = cluster: map (v: v.name) ((podSpecOf cluster).volumes or [ ]);
      configMaps = cluster: map (c: c.metadata.name) (ofKind "ConfigMap" (manifests cluster));
    in
    (
      map (c: c.name) (inits two) == [
        "migrate"
        "replicate"
      ]
      && builtins.elemAt migrate.command 0 == "/bin/sh"
      && lib.hasInfix "exec /entrypoint.sh db migrate" (builtins.elemAt migrate.command 2)
      && lib.hasInfix "> /run/plausible-replica/host" (builtins.elemAt migrate.command 2)
      && (envOf migrate).CLICKHOUSE_REPLICA_HOSTS == "ch-0.events.svc ch-1.events.svc"
      && !(migrate ? args)
      && lib.hasInfix "@ch.web.svc:8123/" (mainEnvOf two).CLICKHOUSE_DATABASE_URL
      && (envOf replicate).CLICKHOUSE_HOST_FILE == "/run/plausible-replica/host"
      && (envOf replicate).CLICKHOUSE_DATABASE == "plausible_events"
      && (envOf replicate) ? CLICKHOUSE_PASSWORD
      && (envOf replicate).REPLICAS == "2"
      && builtins.elem "replica" (mountsOf migrate)
      && builtins.elem "replica" (mountsOf replicate)
      && builtins.elem "replica" (volumesOf two)
      && builtins.elem "plausible-replicate" (configMaps two)
      && builtins.any (v: (v.configMap.name or null) == "plausible-replicate") (podSpecOf two).volumes
      && (annotationsOf two) ? "checksum/replicate"
      && map (c: c.name) (inits one) == [ "migrate" ]
      &&
        (initNamed one "migrate").args == [
          "db"
          "migrate"
        ]
      && !((initNamed one "migrate") ? command)
      && !(builtins.elem "replica" (volumesOf one))
      && !(builtins.elem "plausible-replicate" (configMaps one))
      && !((annotationsOf one) ? "checksum/replicate")
    )
    || throw "plausible replicated: inits ${
      builtins.toJSON (map (c: c.name) (inits two))
    }, migrate ${builtins.toJSON migrate}";

  # A stand-in that publishes no replica count, or more replicas than
  # replicaHosts, is refused with a message naming the cause.
  plausible-replicas-need-hosts =
    let
      short = facadeMessages (twoReplicaFacadeOut // { replicaHosts = [ "ch-0.events.svc" ]; });
      missing = facadeMessages (removeAttrs goodFacadeOut [ "replicas" ]);
    in
    (
      evalFails (clusterWith {
        facade = twoReplicaFacadeOut // {
          replicaHosts = [ "ch-0.events.svc" ];
        };
      })
      && facadeMessages goodFacadeOut == [ ]
      && facadeMessages twoReplicaFacadeOut == [ ]
      && builtins.length short == 1
      && lib.hasInfix "2 replicas and 1 replicaHosts" (builtins.head short)
      && builtins.length missing == 1
      && lib.hasInfix "publishes no `replicas`" (builtins.head missing)
    )
    || throw "plausible replicas: short ${builtins.toJSON short}, missing ${builtins.toJSON missing}";

  # clickhouse-database refuses a grants key that is not `<db>.<table>`
  # with `*` or a plain identifier on each side, since keys enter the SQL
  # unquoted; the injected keys are the control.
  clickhouse-database-grant-keys-checked =
    (
      evalFails (clusterWith {
        facadeConfig.grants."system.replicas TO x; --" = [ "SELECT" ];
      })
      && evalFails (clusterWith {
        facadeConfig.grants.system = [ "SELECT" ];
      })
      && !(evalFails (clusterWith { }))
    )
    || throw "clickhouse-database grants: a malformed key was accepted";

  # A secretKeyBase without the key `key` fails the build.
  plausible-secret-key-base-checked =
    (
      evalFails (clusterWith {
        keyData.value = "0123456789abcdef0123456789abcdef";
      })
      && !(evalFails (clusterWith { }))
    )
    || throw "plausible secretKeyBase: a secret without `key` was accepted";

  # smtpPassword and env.SMTP_USER_NAME come together: either alone fails.
  # Both together set SMTP_USER_PWD from the secret.
  plausible-smtp-pairing =
    let
      withUser = {
        env = {
          BASE_URL = "https://plausible.example.org";
          SMTP_USER_NAME = "plausible";
        };
      };
      both = mainEnvOf (clusterWith {
        smtp = true;
        config = withUser;
      });
    in
    (
      evalFails (clusterWith {
        smtp = true;
      })
      && evalFails (clusterWith {
        config = withUser;
      })
      && both.SMTP_USER_PWD.secretKeyRef.name == "plausible-smtp"
      && evalFails (clusterWith {
        smtp = true;
        config.env = withUser.env // {
          SMTP_USER_PWD = "x";
        };
      })
    )
    || throw "plausible smtp: ${builtins.toJSON both}";

  # With Bamboo.SMTPAdapter, Plausible accepts SMTP_USER_NAME alone, so the
  # pairing check does not apply.
  plausible-smtp-pairing-only-for-mua =
    !(evalFails (clusterWith {
      config.env = {
        BASE_URL = "https://plausible.example.org";
        MAILER_ADAPTER = "Bamboo.SMTPAdapter";
        SMTP_USER_NAME = "plausible";
      };
    }))
    || throw "plausible smtp: Bamboo.SMTPAdapter with SMTP_USER_NAME alone was refused";

  # A credential variable set to a literal string is refused; the same
  # cluster without it is the control.
  plausible-literal-credentials-refused =
    let
      withEnv =
        extra:
        clusterWith {
          config.env = {
            BASE_URL = "https://plausible.example.org";
            MAILER_ADAPTER = "Bamboo.PostmarkAdapter";
          }
          // extra;
        };
    in
    (
      evalFails (withEnv {
        POSTMARK_API_KEY = "literal";
      })
      && evalFails (withEnv {
        TOTP_VAULT_KEY = "literal";
      })
      && !(evalFails (withEnv { }))
    )
    || throw "plausible credentials: a literal credential in env was accepted";

  # A relay in env renders the mail egress policy under an enforcer, and
  # none without a relay; a port that is not a number is refused. The stub
  # enforcer translates no intents, so the port in the rule is checked in
  # clusters/test-plausible.nix, which renders it with Cilium.
  plausible-mail-egress =
    let
      policyOf =
        env:
        lib.findFirst (r: r.metadata.name == "plausible-mail-egress") null (
          manifests (clusterWith {
            netpol = true;
            smtp = true;
            config.env = {
              BASE_URL = "https://plausible.example.org";
              SMTP_USER_NAME = "plausible";
            }
            // env;
          })
        );
      default = policyOf { SMTP_HOST_ADDR = "smtp.example.org"; };
    in
    (
      default != null
      && policyOf { } == null
      && evalFails (clusterWith {
        netpol = true;
        config.env = {
          BASE_URL = "https://plausible.example.org";
          SMTP_HOST_ADDR = "smtp.example.org";
          SMTP_HOST_PORT = "submission";
        };
      })
    )
    || throw "plausible mail egress: ${builtins.toJSON default}";

  # DATABASE_URL asks for TLS only when the database says it serves it.
  plausible-database-sslmode =
    let
      urlOf =
        tls:
        (mainEnvOf (clusterWith {
          dbTls = tls;
        })).DATABASE_URL;
    in
    (
      lib.hasSuffix "?sslmode=require" (urlOf true)
      && !(lib.hasInfix "sslmode" (urlOf false))
      && !(lib.hasInfix "sslmode" (urlOf null))
    )
    || throw "plausible sslmode: ${urlOf true}";

  # A new database password moves only checksum/database; a new key only
  # checksum/secret-key-base.
  plausible-checksums-move-alone =
    let
      base = annotationsOf (clusterWith { });
      newKey = annotationsOf (clusterWith {
        keyData.key = "fedcba9876543210fedcba9876543210";
      });
      newPassword = annotationsOf (clusterWith {
        dbPassword = "other";
      });
    in
    (
      base ? "checksum/clickhouse"
      && !(base ? "checksum/smtp")
      && newKey."checksum/database" == base."checksum/database"
      && newKey."checksum/secret-key-base" != base."checksum/secret-key-base"
      && newPassword."checksum/secret-key-base" == base."checksum/secret-key-base"
      && newPassword."checksum/database" != base."checksum/database"
    )
    || throw "plausible checksums: base ${builtins.toJSON base}, key ${builtins.toJSON newKey}, password ${builtins.toJSON newPassword}";

  # Two instances named alike in two namespaces, both on the one ClickHouse
  # server, render without a collision and get two databases. Each facade
  # names its own database and user, which default to the instance name.
  plausible-two-namespaces =
    let
      cluster = mkCluster [
        clickhouseServer
        (plausibleIn {
          ns = "web";
          facadeConfig = {
            database = "plausible_web";
            user = "plausible_web";
          };
        })
        (plausibleIn {
          ns = "shop";
          facadeConfig = {
            database = "plausible_shop";
            user = "plausible_shop";
          };
        })
      ];
      urls = map (d: (envOf (builtins.head d.spec.template.spec.containers)).CLICKHOUSE_DATABASE_URL) (
        builtins.filter (d: d.metadata.name == "plausible") (ofKind "Deployment" (manifests cluster))
      );
    in
    (builtins.length urls == 2 && lib.unique urls == urls)
    || throw "plausible two namespaces: ${builtins.toJSON urls}";
}

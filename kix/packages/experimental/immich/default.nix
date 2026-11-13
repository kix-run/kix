# immich: the Immich server, a self-hosted photo and video library. One
# Deployment serves the API and web UI and runs the background jobs; a
# Service fronts it, and `kix.expose` adds the Ingress or HTTPRoute. With
# `settings`, a ConfigMap holds Immich's config file. With a `prometheus`
# dependency, a ServiceMonitor scrapes the API and job metrics.
#
# Dependencies:
#   database (required)         a PostgreSQL database honouring the Postgres
#                               database contract (kix.contracts.postgresDatabase),
#                               such as a stackgres-database instance. The package
#                               adds the extensions Immich needs to that instance's
#                               `extensions`, and a stackgres-database forwards
#                               them to its stackgres-cluster. Declare
#                               `stackgres-operator` once, in its own namespace.
#   redis (required)            the job queue, honouring kix.contracts.redis. An
#                               auto-instantiated valkey lands in this namespace and
#                               reads its password from a `secret` aliased
#                               `valkeyPassword` (key `password`) in this namespace.
#                               A kix.mkImport stands in for an outside server
#                               without TLS. A server that publishes out.sentinel is
#                               reached through Sentinel.
#   storage (required)          the photo library: a ReadWriteOnce claim, such as a
#                               persistent-volume-claim instance.
#   machineLearning (optional)  an immich-machine-learning instance in this
#                               namespace, or a kix.mkImport aliased `machineLearning`
#                               whose out sets `fqdn` and `port`. A worker serves only
#                               its own namespace, so a worker elsewhere is reached
#                               through such an import, and no egress is derived to
#                               an import. Without the dependency the server turns
#                               machine learning off.
#   prometheus (optional)       scrapes the metrics ports while `metrics.enabled`.
#   oidc (optional)             single sign-on, through an OpenID Connect
#                               client honouring kix.contracts.oidc; see below.
#   smtp (optional)             a mail server honouring kix.contracts.smtp, for
#                               email notifications; see below.
#
# A minimal instance, in namespace `photos`:
#
#   photos = {
#     immich.package = packages.experimental.immich;
#     library = { package = packages.persistent-volume-claim; aliases = [ "storage" ]; config.size = "100Gi"; };
#     immich-db = { package = packages.experimental.stackgres-database; aliases = [ "database" ]; };
#     immich-db-password = { package = packages.secret; aliases = [ "password" ]; config = { source = ./immich-db.sops.yaml; hash = "sha256-..."; keys = [ "password" ]; }; };
#     valkey-password = { package = packages.secret; aliases = [ "valkeyPassword" ]; config.stringData.password = "<password>"; };
#   };
#
# `out`: the `<instance>-server` Service on port 2283. The public URL is the
# instance's `exposure` part.
#
# Escape hatches: `env` takes any server variable outside the groups the
# package derives (database, valkey, machine learning, config file, ports,
# and library path). `settings` is Immich's config file; a non-empty value
# makes every setting in the admin UI read-only. `partsOverlays` patches
# the rendered resources.
#
# Single sign-on: with `oidc` wired (an oidc-client instance, or a
# kix.mkImport), Immich's OAuth login uses that client's issuer and its
# `out.credentials`, with `oidc.scopes` and `oidc.autoLogin`
# (`oauth.autoLaunch`). Register a confidential client with the redirect URIs
# `<public URL>/auth/login`, `<public URL>/user-settings`, and
# `app.immich:///oauth-callback` for the mobile app. The settings go into
# the config file, which turns the admin UI read-only. The client id and
# secret reach the container as environment variables, and the container
# writes them into a copy of the config file on a memory-backed volume at
# start, so the ConfigMap holds no credential. Other OAuth keys, such as
# `oauth.roleClaim` and `oauth.autoRegister`, go in `settings`.
#
# Immich links an OAuth sign-in to an existing local account with the same
# email and does not check `email_verified`. If the realm lets users set
# their email without verifying it, a user can take over a local account,
# the administrator's included. Require verified email in the realm, or
# give local accounts emails that only their owners control.
#
# Immich discovers the provider at the issuer URL, the public URL, and
# checks that the issuer it reports matches, so it cannot use a Keycloak
# Service address; its token and userinfo requests go to the public URL
# too. Derived policy has no edge for them. The world:443 intent admits
# them when the public URL resolves to a load balancer outside the cluster.
# When it resolves to an address the cluster's own data plane answers, the
# request reaches the ingress controller from a pod, which its policy does
# not admit.
#
# Mail: with `smtp` wired, the package writes the server and the sender
# (the server's `out.from`, or `mail.from`) into `notifications.smtp` of
# the config file, and turns email notifications on. The login reaches the
# file at start, like the OIDC client. Because the config file then exists,
# the admin UI shows every setting read-only; set them in `settings`.
# Immich's mailer uses STARTTLS only when the server offers it and would
# then send the login in clear text, so a server with credentials must use
# implicit TLS (`tls = "implicit"`, usually port 465). A server outside the
# cluster gets an egress policy for its port.
#
# Known limits: the server runs one pod and rolls out with Recreate, so
# every rollout stops it briefly. A database or valkey password, an OIDC
# client secret, or a mail login from a secret-ref has no identity hash, so
# rotating it restarts the server only with reloader.

{
  scope,
  lib,
  kix,
}:

let
  name = scope.instanceName;
  who = "immich ${scope.namespaceName}/${name}";
  release = import ./release.nix;
  owner = "app-team";

  # Immich's InitialMigration
  # (server/src/schema/migrations/1744910873969-InitialMigration.ts) creates
  # exactly these extensions. vchord (VectorChord) is the vector extension
  # Immich prefers.
  requiredExtensions = [
    {
      name = "vchord";
      version = "0.5.3";
    }
    "uuid-ossp"
    "cube"
    "earthdistance"
    "unaccent"
    "pg_trgm"
  ];
  extensionName = e: if builtins.isString e then e else e.name;

  # A kix.mkImport stand-in publishes only the `out` fields its author
  # wrote, so a missing one fails here with the fields that dependency needs.
  importFields = {
    database = "out.host, out.port, out.database, and out.credentials";
    machineLearning = "out.fqdn and out.port";
  };
  depOut =
    depName: dep: field:
    dep.out.${field} or (scope.fail {
      package = "immich";
      message = "deps.${depName} publishes no out.${field}.";
      fix = "An import standing in for it sets ${importFields.${depName}}.";
    });

  mlFix = "Add an immich-machine-learning instance to this namespace, or a kix.mkImport aliased machineLearning whose out sets fqdn and port.";

  # init-chown-data runs as root. When security.nonRoot would fail the
  # build, the build fails here instead, naming the override that lets the
  # chown deploy through.
  chownHint = "initChownData adds the root init container init-chown-data, which fails the security.nonRoot scorecard rule. For the deploy that runs the chown, set scorecard.ruleOverrides.byNamespace.${scope.namespaceName}.\"security.nonRoot\".severity = \"warning\" in the cluster definition. Once the pod has started, remove that override and set initChownData = false.";
  nonRootFailsBuild =
    clusterConfig:
    kix.scorecard.effectiveSeverity {
      inherit clusterConfig owner;
      rule = "security.nonRoot";
      namespaceName = scope.namespaceName;
    } == "error";
in
{
  meta = {
    version = release.version;
    description = "Immich server: self-hosted photo and video library, serving the API, web UI, and background jobs from one Deployment";
    inherit owner;
    # The library is one ReadWriteOnce claim (`storage`), so the server runs
    # one pod and rolls out with Recreate.
    availability.max = "none";
    # OAuth issuer discovery and token exchange, and the new-release check
    # (`newVersionCheck.enabled`, on by default).
    network.intents.external-https.egress = [
      {
        to = "world";
        ports = [
          {
            port = 443;
            protocol = "TCP";
          }
        ];
      }
    ];
  };

  deps = {
    database.config.extensions = requiredExtensions;

    database.assertions =
      dep:
      let
        published = map extensionName (dep.out.extensions or [ ]);
        missing = builtins.filter (e: !(builtins.elem e published)) (map extensionName requiredExtensions);
      in
      kix.contracts.postgresDatabase.assertions who dep
      ++ lib.optional (dep.out ? extensions && missing != [ ]) {
        assertion = false;
        message = "the database needs the postgres extensions ${
          lib.concatMapStringsSep ", " extensionName requiredExtensions
        }; missing: ${lib.concatStringsSep ", " missing}. For a kix.mkImport database, install them on that server and list them in the import's out.extensions. For a stackgres-database, remove the setting that drops them from its extensions.";
      };

    redis = {
      assertions = dep: kix.contracts.redis.assertions who dep;
      renamedFrom = kix.contracts.redis.helpers.renamedFrom;
    };

    storage.warnings =
      dep:
      let
        bytes = kix.parseQuantity "memory" (dep.out.size or "0");
      in
      lib.optional (bytes != null && bytes < 50 * 1024 * 1024 * 1024)
        "library storage is ${dep.out.size or "unknown"}; recommended minimum is 50Gi for photo libraries";
  };

  # Printed on the build that passes too, as the reminder to undo the
  # override afterwards.
  warnings = { config, ... }: lib.optional config.initChownData chownHint;

  options = {
    image = kix.options.image {
      repository = "ghcr.io/immich-app/immich-server";
      inherit (release) tag;
      digest = release.digests.server;
    };
    # Neither the immich-charts chart nor the compose file sets resources.
    # Immich's requirements page asks for 6 GB of RAM and 2 cores for the
    # whole stack; the server's share leaves room for thumbnail and video
    # jobs, which run in-process.
    resources = kix.options.resources {
      requests = {
        cpu = "250m";
        memory = "1Gi";
      };
      limits = {
        cpu = "4";
        memory = "4Gi";
      };
    };
    env = kix.options.env // {
      description = ''
        Extra environment variables for the server: a string, a `fieldRef`,
        or `kix.untrackedRef` for a Secret managed outside Kix. Credentials
        from a dependency are wired by the package. The package refuses the
        variables it derives from the database, valkey, and machineLearning
        dependencies, `settings`, and its own ports and library path. Null
        removes `IMMICH_TELEMETRY_INCLUDE`, which the package sets while
        metrics are scraped.
      '';
    };
    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        storageTemplate.enabled = true;
        passwordLogin.enabled = false;
      };
      description = ''
        Immich's configuration file (`IMMICH_CONFIG_FILE`), in Immich's own
        JSON vocabulary, as the admin UI's export writes it. Empty leaves
        every setting to the admin UI. A non-empty value makes the admin UI
        read-only for all settings, and a change restarts the server.
        `machineLearning.urls` and `machineLearning.enabled` are refused:
        they follow the `machineLearning` dependency. `oauth.clientSecret`
        is refused, because the ConfigMap would hold it; with
        `oidc` wired the package sets `oauth.enabled`, `oauth.issuerUrl`,
        `oauth.clientId`, `oauth.clientSecret`, `oauth.scope`, and
        `oauth.autoLaunch`, and refuses them here.
        `notifications.smtp.transport.password` is refused for the same
        reason; with `smtp` wired the package sets
        `notifications.smtp.enabled`, `notifications.smtp.from`, and the
        transport's `host`, `port`, `secure`, `ignoreCert`, `username`, and
        `password`, and refuses them here.
      '';
    };
    oidc = kix.contracts.oidc.options {
      scopes = [
        "openid"
        "email"
        "profile"
      ];
      autoLogin = "`oauth.autoLaunch`";
    };
    metrics = kix.options.monitor;
    ingress = kix.options.ingress;
    mail = kix.contracts.smtp.options;
    initChownData = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Run `chown -R 1000:1000` over the library as root in an init
        container before immich-server starts. The server runs as uid 1000,
        and fsGroup does not change ownership on hostPath or local-path
        volumes, so a library written by a root-run Immich (the upstream
        compose file or chart) stays unwritable. The chown walks the whole
        library, so a large one takes a while. The init container fails the
        `security.nonRoot` scorecard rule, so that deploy also needs
        `scorecard.ruleOverrides.byNamespace.<namespace>."security.nonRoot".severity = "warning"`.
        Remove both once the pod has started.
      '';
    };
  };

  build = [
    (
      {
        self,
        config,
        clusterConfig,
        redis,
        database,
        storage,
        machineLearning ? null,
        prometheus ? null,
        oidc ? null,
        smtp ? null,
        ...
      }:
      let
        hasMetrics = config.metrics.enabled && prometheus != null;

        oidcProviderInfo = kix.contracts.oidc.helpers.client {
          inherit who oidc;
          options = config.oidc;
        };
        oidcOn = oidcProviderInfo != null;
        oidcCredentials = oidcProviderInfo.credentials;
        oauthSettings = lib.optionalAttrs oidcOn {
          oauth = {
            enabled = true;
            issuerUrl = oidcProviderInfo.issuerUrl;
            scope = lib.concatStringsSep " " config.oidc.scopes;
            autoLaunch = config.oidc.autoLogin;
          };
        };
        relay = kix.contracts.smtp.helpers.settings {
          inherit who smtp;
          inherit (config.mail) from;
        };
        mailLogin = relay != null && relay.credentials != null;
        # nodemailer sends the login without TLS when `secure` is false and
        # the server offers no STARTTLS, and Immich cannot ask it to require
        # STARTTLS.
        relayCheck =
          if mailLogin && relay.tls == "starttls" then
            scope.fail {
              package = "immich";
              message = "deps.smtp uses tls = \"starttls\" with credentials. Immich's mailer (nodemailer) sends the password without TLS when the server does not offer STARTTLS, so it would leak to anyone who can strip STARTTLS on the way.";
              fix = "Use the server's implicit TLS port: tls = \"implicit\" and port = \"465\" on the SMTP instance.";
            }
          else
            null;
        mailSettings = lib.optionalAttrs (relay != null) {
          notifications.smtp = {
            enabled = true;
            inherit (relay) from;
            transport = {
              inherit (relay) host;
              port = relay.portNumber;
              secure = relay.tls == "implicit";
              ignoreCert = false;
            };
          };
        };
        effectiveSettings = lib.foldl' lib.recursiveUpdate config.settings [
          oauthSettings
          mailSettings
        ];
        # The OIDC client and the mail login reach the config file at start,
        # so the ConfigMap holds no credential.
        runtimeSecrets = oidcOn || mailLogin;

        healthCheck = {
          httpGet = {
            path = "/api/server/ping";
            port = "http";
          };
          periodSeconds = 10;
          timeoutSeconds = 1;
          failureThreshold = 3;
        };

        # A worker from another release answers the server's newer jobs with
        # 500s. `out.version` is the worker's release (release.nix `of`), so
        # hardware variants and digest pins compare by release. It is absent
        # for a tag that names no release and on a dependency that is not the
        # immich-machine-learning package; either skips the check.
        mlVersion = machineLearning.out.version or null;
        imageTag = builtins.unsafeDiscardStringContext config.image.tag;
        serverVersion = release.of imageTag;
        mlUrl =
          if mlVersion != null && serverVersion != null && mlVersion != serverVersion then
            scope.fail {
              package = "immich";
              option = "config.image.tag";
              message = "immich-server runs release ${serverVersion} (image.tag ${imageTag}) but its machineLearning dependency runs ${mlVersion}. Immich publishes both images under one tag.";
              fix = "Set image.tag to the same release on both instances.";
            }
          else
            "http://${depOut "machineLearning" machineLearning "fqdn"}:${
              toString (depOut "machineLearning" machineLearning "port")
            }";

        # The database assertion guarantees vchord whenever the dependency
        # publishes `out.extensions`. A database that publishes none (an
        # external server) gets no setting, and Immich detects the extension.
        vectorExtension = if database.out ? extensions then "vectorchord" else null;
        dbCreds = (depOut "database" database "credentials").out;

        # With Sentinel on, the valkey Service also routes to read-only
        # replicas, so the server finds the primary through Sentinel. Immich
        # takes ioredis options as REDIS_URL=ioredis://<base64 JSON> and then
        # ignores the other REDIS_* variables, so the password goes into that
        # JSON. The container builds REDIS_URL from REDIS_SENTINEL_OPTIONS and
        # REDIS_PASSWORD at start, which keeps the password in its Secret.
        redisServer = kix.contracts.redis.helpers.requirePlaintext who redis;
        useSentinel = kix.contracts.redis.helpers.usesSentinel redisServer;
        sentinelStart = ''
          REDIS_URL="ioredis://$(node -e 'const o = JSON.parse(process.env.REDIS_SENTINEL_OPTIONS); if (process.env.REDIS_PASSWORD) o.password = process.env.REDIS_PASSWORD; process.stdout.write(Buffer.from(JSON.stringify(o)).toString("base64"))')"
          export REDIS_URL
        '';

        # The config file Immich reads while it has a credential: the
        # ConfigMap's copy with the OIDC client and the mail login added,
        # written at start by the image's node to a memory-backed volume.
        runtimeConfigFile = "${self.runtimeConfigMount.mountPath}/immich-config.json";
        runtimeConfigStart = ''
          node -e 'const fs = require("fs"); const e = process.env; const c = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); if (e.OAUTH_CLIENT_ID) { c.oauth.clientId = e.OAUTH_CLIENT_ID; c.oauth.clientSecret = e.OAUTH_CLIENT_SECRET; } if (e.SMTP_USERNAME) { c.notifications.smtp.transport.username = e.SMTP_USERNAME; c.notifications.smtp.transport.password = e.SMTP_PASSWORD; } fs.writeFileSync(process.argv[2], JSON.stringify(c), { mode: 0o600 })' ${self.configMount.mountPath}/immich-config.json ${runtimeConfigFile}
        '';
        startSteps =
          lib.optional useSentinel sentinelStart ++ lib.optional runtimeSecrets runtimeConfigStart;
        startScript = "set -e\n${lib.concatStrings startSteps}exec start.sh\n";
        valkeyPassword = lib.optionalAttrs (redisServer.out ? credentials) {
          REDIS_PASSWORD = redisServer.out.credentials.out.keyRef "password";
        };

        ownedSettings = [
          [
            "machineLearning"
            "urls"
          ]
          [
            "machineLearning"
            "enabled"
          ]
        ];
        # With oidc wired the package owns these oauth keys; clientId and
        # clientSecret are added at start.
        oidcOwnedSettings = lib.optionals oidcOn (
          map
            (k: [
              "oauth"
              k
            ])
            [
              "enabled"
              "issuerUrl"
              "clientId"
              "scope"
              "autoLaunch"
            ]
        );
        # With smtp wired the package owns the server, sender, and login.
        mailOwnedSettings = lib.optionals (relay != null) (
          map
            (
              p:
              [
                "notifications"
                "smtp"
              ]
              ++ p
            )
            [
              [ "enabled" ]
              [ "from" ]
              [
                "transport"
                "host"
              ]
              [
                "transport"
                "port"
              ]
              [
                "transport"
                "secure"
              ]
              [
                "transport"
                "ignoreCert"
              ]
              [
                "transport"
                "username"
              ]
            ]
        );
        settingsCheck =
          let
            hits = builtins.filter (p: lib.hasAttrByPath p config.settings) ownedSettings;
            oidcHits = builtins.filter (p: lib.hasAttrByPath p config.settings) oidcOwnedSettings;
            mailHits = builtins.filter (p: lib.hasAttrByPath p config.settings) mailOwnedSettings;
          in
          if lib.hasAttrByPath [ "notifications" "smtp" "transport" "password" ] config.settings then
            scope.fail {
              package = "immich";
              option = "config.settings";
              message = "settings sets notifications.smtp.transport.password, which the config ConfigMap would hold.";
              fix = "Wire the mail server through deps.smtp instead, whose credentials hold the username and password.";
            }
          else if mailHits != [ ] then
            scope.fail {
              package = "immich";
              option = "config.settings";
              message = "settings sets ${
                lib.concatMapStringsSep ", " (lib.concatStringsSep ".") mailHits
              }, which deps.smtp sets.";
              fix = "Set the server on the SMTP instance, and the sender there or in mail.from.";
            }
          else if lib.hasAttrByPath [ "oauth" "clientSecret" ] config.settings then
            scope.fail {
              package = "immich";
              option = "config.settings";
              message = "settings sets oauth.clientSecret, which the config ConfigMap would hold.";
              fix = "Wire the client through deps.oidc instead, whose credentials hold the client id and secret.";
            }
          else if oidcHits != [ ] then
            scope.fail {
              package = "immich";
              option = "config.settings";
              message = "settings sets ${
                lib.concatMapStringsSep ", " (lib.concatStringsSep ".") oidcHits
              }, which deps.oidc sets.";
              fix = "Use the oidc option and the oidc dependency instead.";
            }
          else if hits == [ ] then
            null
          else
            scope.fail (
              map (p: {
                package = "immich";
                option = "config.settings";
                message = "settings sets ${lib.concatStringsSep "." p}, which follows the optional machineLearning dependency.";
                fix = "Remove it from settings. ${mlFix}";
              }) hits
            );

        env = kix.mergeEnv {
          inherit who;
          defaults = lib.optionalAttrs hasMetrics { IMMICH_TELEMETRY_INCLUDE = "all"; };
          owned = [
            {
              vars = {
                DB_HOSTNAME = depOut "database" database "host";
                DB_PORT = toString (depOut "database" database "port");
                DB_DATABASE_NAME = depOut "database" database "database";
                DB_USERNAME = dbCreds.keyRef "username";
                DB_PASSWORD = dbCreds.keyRef "password";
              }
              // lib.optionalAttrs (vectorExtension != null) { DB_VECTOR_EXTENSION = vectorExtension; };
              names = [ "DB_URL" ];
              from = "the database dependency";
              fix = "Wire a different database through deps.database.";
            }
            (
              if useSentinel then
                {
                  vars = {
                    REDIS_SENTINEL_OPTIONS = builtins.toJSON {
                      sentinels = [
                        {
                          host = redisServer.out.host;
                          port = redisServer.out.sentinel.port;
                        }
                      ];
                      name = redisServer.out.sentinel.primarySet;
                    };
                  }
                  // valkeyPassword;
                  names = [
                    "REDIS_HOSTNAME"
                    "REDIS_PORT"
                    "REDIS_URL"
                    "REDIS_SOCKET"
                    "REDIS_DBINDEX"
                    "REDIS_USERNAME"
                  ];
                  from = "the redis dependency, which runs Sentinel";
                  fix = "The container builds REDIS_URL from the Sentinel options at start, and Immich then ignores the other REDIS_* variables. Wire a different instance through deps.redis.";
                }
              else
                {
                  vars = {
                    REDIS_HOSTNAME = redisServer.out.host;
                    REDIS_PORT = redisServer.out.port;
                  }
                  // valkeyPassword;
                  names = [
                    "REDIS_URL"
                    "REDIS_SOCKET"
                    "REDIS_SENTINEL_OPTIONS"
                  ];
                  from = "the redis dependency";
                  fix = "Wire a different instance through deps.redis.";
                }
            )
            (
              if machineLearning != null then
                {
                  vars.IMMICH_MACHINE_LEARNING_URL = mlUrl;
                  names = [ "IMMICH_MACHINE_LEARNING_ENABLED" ];
                  from = "the optional machineLearning dependency";
                  fix = mlFix;
                }
              else
                {
                  vars.IMMICH_MACHINE_LEARNING_ENABLED = "false";
                  names = [ "IMMICH_MACHINE_LEARNING_URL" ];
                  from = "the machineLearning dependency, and none is wired";
                  fix = "Without one the package turns machine learning off. ${mlFix}";
                }
            )
            (
              {
                from = "the settings option";
                fix = "Set Immich's configuration in settings.";
              }
              // (
                if runtimeSecrets then
                  { vars.IMMICH_CONFIG_FILE = runtimeConfigFile; }
                else if self.configMount != null then
                  { vars.IMMICH_CONFIG_FILE = "${self.configMount.mountPath}/immich-config.json"; }
                else
                  { names = [ "IMMICH_CONFIG_FILE" ]; }
              )
            )
            (
              {
                from = "the oidc dependency";
                fix = "Wire another client through deps.oidc.";
              }
              // (
                if oidcOn then
                  {
                    vars = {
                      OAUTH_CLIENT_ID = oidcCredentials.out.keyRef "clientId";
                      OAUTH_CLIENT_SECRET = oidcCredentials.out.keyRef "clientSecret";
                    };
                  }
                else
                  {
                    names = [
                      "OAUTH_CLIENT_ID"
                      "OAUTH_CLIENT_SECRET"
                    ];
                  }
              )
            )
            (
              {
                from = "the smtp dependency";
                fix = "Wire another mail server through deps.smtp.";
              }
              // (
                if mailLogin then
                  {
                    vars = {
                      SMTP_USERNAME = relay.credentials.out.keyRef "username";
                      SMTP_PASSWORD = relay.credentials.out.keyRef "password";
                    };
                  }
                else
                  {
                    names = [
                      "SMTP_USERNAME"
                      "SMTP_PASSWORD"
                    ];
                  }
              )
            )
            {
              vars.IMMICH_MEDIA_LOCATION = self.libraryMount.mountPath;
              names = [
                "IMMICH_PORT"
                "IMMICH_API_METRICS_PORT"
                "IMMICH_MICROSERVICES_METRICS_PORT"
              ];
              from = "the package";
              fix = "It fixes the server's ports and library path to match its Service, probes, ServiceMonitor, and library mount; remove the setting from env.";
            }
          ];
        } config.env;
      in
      {
        configMap = builtins.seq settingsCheck (
          builtins.seq relayCheck (
            if effectiveSettings == { } then
              null
            else
              scope.mkResource {
                apiVersion = "v1";
                kind = "ConfigMap";
                name = "${name}-config";
                data."immich-config.json" = builtins.toJSON effectiveSettings;
              }
          )
        );

        libraryMount = kix.mount.pvc storage { mountPath = "/usr/src/app/upload"; };
        configMount = kix.mount.configMap self.configMap { mountPath = "/config"; };
        tmpMount = kix.mount.emptyDir {
          name = "tmp";
          mountPath = "/tmp";
          sizeLimit = "1Gi";
        };
        runtimeConfigMount =
          if runtimeSecrets then
            kix.mount.emptyDir {
              name = "runtime-config";
              mountPath = "/run/immich";
              medium = "Memory";
              sizeLimit = "1Mi";
            }
          else
            null;

        deployment =
          {
            name = "${name}-server";
            spec = {
              replicas = 1;
              # The package treats the library as ReadWriteOnce: a surge pod
              # scheduled on another node would fail with Multi-Attach.
              strategy.type = "Recreate";
              selector.matchLabels = scope.selectorLabels;
              # Immich reads its config file and credentials once at start.
              # A secret-ref has no identity hash, so a password rotated
              # outside Kix needs reloader to restart the pod.
              template.metadata.annotations = lib.filterAttrs (_: v: v != null) {
                "checksum/config" = if self.configMap != null then self.configMap.out.identityHash else null;
                "checksum/database" = dbCreds.identityHash or null;
                "checksum/valkey-password" =
                  if redisServer.out ? credentials then
                    redisServer.out.credentials.out.identityHash or null
                  else
                    null;
                "checksum/oidc-client" = if oidcOn then oidcCredentials.out.identityHash or null else null;
                "checksum/smtp" = if mailLogin then relay.credentials.out.identityHash or null else null;
              };
              template.spec = {
                # Kubernetes default: Immich documents no shutdown drain.
                terminationGracePeriodSeconds = 30;
                automountServiceAccountToken = false;
                # uid 1000 is the image's `node` user. Immich supports any
                # non-root uid that can write the library (docs FAQ, "run as
                # non-root"); fsGroup grants that on provisioners that honour
                # it. OnRootMismatch relabels the library only while its root
                # lacks the group, not on every start.
                securityContext = {
                  runAsNonRoot = true;
                  runAsUser = 1000;
                  runAsGroup = 1000;
                  fsGroup = 1000;
                  fsGroupChangePolicy = "OnRootMismatch";
                  seccompProfile.type = "RuntimeDefault";
                };
                ${if config.initChownData then "initContainers" else null} = lib.singleton (
                  if nonRootFailsBuild clusterConfig then
                    scope.fail {
                      package = "immich";
                      option = "config.initChownData";
                      message = chownHint;
                    }
                  else
                    {
                      name = "init-chown-data";
                      # The server image carries coreutils `chown`.
                      image = kix.image.ref config.image;
                      imagePullPolicy = config.image.pullPolicy;
                      command = [
                        "chown"
                        "-R"
                        "1000:1000"
                        self.libraryMount.mountPath
                      ];
                      resources = {
                        requests = {
                          cpu = "10m";
                          memory = "32Mi";
                        };
                        limits = {
                          cpu = "500m";
                          memory = "128Mi";
                        };
                      };
                      # DAC_READ_SEARCH lets root descend into directories
                      # other uids made unreadable to it.
                      securityContext = {
                        runAsNonRoot = false;
                        runAsUser = 0;
                        allowPrivilegeEscalation = false;
                        readOnlyRootFilesystem = true;
                        capabilities = {
                          add = [
                            "CHOWN"
                            "DAC_READ_SEARCH"
                          ];
                          drop = [ "ALL" ];
                        };
                      };
                    }
                );
                containers = [
                  {
                    name = "immich-server";
                    image = kix.image.ref config.image;
                    imagePullPolicy = config.image.pullPolicy;
                    # The image's entrypoint is `tini -- /bin/bash -c` with
                    # CMD `start.sh`, so args replaces only the command string.
                    ${if startSteps != [ ] then "args" else null} = [ startScript ];
                    env = kix.mkEnvVars env;
                    ports = [
                      (kix.port "http" 2283)
                    ]
                    ++ lib.optionals hasMetrics [
                      (kix.port "metrics-api" 8081)
                      (kix.port "metrics-ms" 8082)
                    ];
                    livenessProbe = healthCheck;
                    readinessProbe = healthCheck;
                    startupProbe = healthCheck // {
                      failureThreshold = 30;
                    };
                    resources = config.resources;
                    securityContext = {
                      allowPrivilegeEscalation = false;
                      readOnlyRootFilesystem = true;
                      capabilities.drop = [ "ALL" ];
                    };
                  }
                ];
              };
            };
          }
          |> kix.withMountsOn ([ "immich-server" ] ++ lib.optional config.initChownData "init-chown-data") [
            self.libraryMount
          ]
          |> kix.withMounts [
            self.configMount
            self.tmpMount
            self.runtimeConfigMount
          ]
          |> scope.mkDeployment;

        mailEgress = kix.contracts.smtp.helpers.egressPolicy {
          inherit scope;
          smtp = relay;
          name = "${name}-mail-egress";
          selector = self.deployment.out.selector;
        };

        service =
          self.deployment |> kix.service.fromWorkload { name = "${name}-server"; } |> scope.mkResource;

        root = self.service;
      }
    )
    (kix.expose {
      service = "service";
      # Uploads have no size bound.
      defaultAnnotations = {
        "nginx.ingress.kubernetes.io/proxy-body-size" = "0";
      };
      # The mobile app's /api/sync/stream is long-lived, and a first sync
      # outlasts Envoy Gateway's 15s default request timeout. The app's own
      # 60s socket timeout still bounds the stream.
      timeouts = {
        request = "0s";
        backendRequest = "0s";
      };
    })
    (kix.monitor {
      service = "service";
      port = "metrics-api";
      extraEndpoints = [ { port = "metrics-ms"; } ];
    })
  ];
}

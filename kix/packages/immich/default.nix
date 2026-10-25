# immich: the Immich server, a self-hosted photo and video library. One
# Deployment serves the API and web UI and runs the background jobs; a
# Service fronts it, and `kix.expose` adds the Ingress or HTTPRoute. With
# `settings`, a ConfigMap holds Immich's config file. With a `prometheus`
# dependency, a ServiceMonitor scrapes the API and job metrics.
#
# Required dependencies:
#   database  a PostgreSQL database honouring the Postgres database
#             contract (kix.contracts.postgresDatabase), such as a
#             stackgres-database instance. The package adds the extensions
#             Immich needs to that instance's `extensions`, and a
#             stackgres-database forwards them to its stackgres-cluster.
#             Declare `stackgres-operator` once, in its own namespace.
#   valkey    the job queue. An auto-instantiated valkey lands in this
#             namespace and reads its password from a `secret` aliased
#             `valkeyPassword` (key `password`) in this namespace. A valkey
#             running Sentinel is reached through Sentinel.
#   storage   the photo library: a ReadWriteOnce claim, such as a
#             persistent-volume-claim instance.
# Optional dependencies:
#   machineLearning  an immich-machine-learning instance in this namespace,
#                    or a kix.mkImport aliased `machineLearning` whose out
#                    sets `fqdn` and `port`. A worker serves only its own
#                    namespace, so a worker elsewhere is reached through such
#                    an import, and no egress is derived to an import.
#                    Without the dependency the server turns machine
#                    learning off.
#   prometheus       scrapes the metrics ports while `metrics.enabled`.
#   oidcProvider, oidcClient (with `oidc.enabled`)
#                    single sign-on; see below.
#
# A minimal instance, in namespace `photos`:
#
#   photos = {
#     immich.package = packages.immich;
#     library = { package = packages.persistent-volume-claim; aliases = [ "storage" ]; config.size = "100Gi"; };
#     immich-db = { package = packages.stackgres-database; aliases = [ "database" ]; config.password = "<password>"; };
#     valkey-password = { package = packages.secret; aliases = [ "valkeyPassword" ]; config.stringData.password = "<password>"; };
#   };
#
# out: the `<instance>-server` Service on port 2283. The public URL is the
# instance's `exposure` part.
#
# Escape hatches: `env` takes any server variable outside the groups the
# package derives (database, valkey, machine learning, config file, ports,
# and library path). `settings` is Immich's config file; a non-empty value
# makes every setting in the admin UI read-only. `partsOverlays` patches
# the rendered resources.
#
# Single sign-on: with `oidc.enabled`, Immich's OAuth login uses the
# `oidcProvider` dependency (`kix.contracts.oidcProvider`, such as a keycloak
# instance wired with `deps.oidcProvider = ref.<ns>.<name>`) in the realm
# `oidc.realm`, with `oidc.scopes` and `oidc.autoLogin` (`oauth.autoLaunch`).
# `oidcClient` is a secret with keys `clientId` and `clientSecret`. Register a confidential client with the redirect URIs
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
# Known limits: the server runs one pod and rolls out with Recreate, so
# every rollout stops it briefly. The world:443 intent does not open SMTP
# (465 or 587) for email notifications. A database or valkey password, or
# an oidcClient secret, from a secret-ref has no identity hash, so rotating
# it restarts the server only with reloader.

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
    valkey = "out.fqdn and out.port";
    machineLearning = "out.fqdn and out.port";
  };
  depOut =
    depName: dep: field:
    dep.out.${field}
      or (throw "${who}: deps.${depName} publishes no out.${field}. An import standing in for it sets ${importFields.${depName}}.");

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
    oidcProvider.assertions = dep: kix.contracts.oidcProvider.assertions who dep;

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
        `oidc.enabled` the package sets `oauth.enabled`, `oauth.issuerUrl`,
        `oauth.clientId`, `oauth.clientSecret`, `oauth.scope`, and
        `oauth.autoLaunch`, and refuses them here.
      '';
    };
    oidc = kix.options.oidc {
      scopes = [
        "openid"
        "email"
        "profile"
      ];
      autoLogin = "`oauth.autoLaunch`";
    };
    metrics = kix.options.monitor;
    ingress = kix.options.ingress;
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
        valkey,
        database,
        storage,
        machineLearning ? null,
        prometheus ? null,
        oidcProvider ? null,
        oidcClient ? null,
        ...
      }:
      let
        hasMetrics = config.metrics.enabled && prometheus != null;

        oidcOn = config.oidc.enabled;
        oidcProviderInfo = kix.contracts.oidcProvider.requireClient {
          inherit who;
          inherit (config) oidc;
          provider = oidcProvider;
          client = oidcClient;
        };
        # Forcing oidcProviderInfo first reports a missing dependency by
        # name rather than as a missing attribute of null.
        oidcCredentials = builtins.seq oidcProviderInfo (
          kix.checkSecretKeys {
            inherit who;
            arg = "oidcClient";
            dep = oidcClient;
            keys = kix.contracts.oidcProvider.clientKeys;
          }
        );
        oauthSettings = lib.optionalAttrs oidcOn {
          oauth = {
            enabled = true;
            issuerUrl = oidcProviderInfo.issuerUrl;
            scope = lib.concatStringsSep " " config.oidc.scopes;
            autoLaunch = config.oidc.autoLogin;
          };
        };
        effectiveSettings = lib.recursiveUpdate config.settings oauthSettings;

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
        serverVersion = release.of config.image.tag;
        mlUrl =
          if mlVersion != null && serverVersion != null && mlVersion != serverVersion then
            throw "${who}: immich-server runs release ${serverVersion} (image.tag ${config.image.tag}) but its machineLearning dependency runs ${mlVersion}. Immich publishes both images under one tag; set image.tag to the same release on both instances."
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
        useSentinel = valkey.out ? sentinelPort;
        sentinelStart = ''
          REDIS_URL="ioredis://$(node -e 'const o = JSON.parse(process.env.REDIS_SENTINEL_OPTIONS); if (process.env.REDIS_PASSWORD) o.password = process.env.REDIS_PASSWORD; process.stdout.write(Buffer.from(JSON.stringify(o)).toString("base64"))')"
          export REDIS_URL
        '';

        # The config file Immich reads while OIDC is on: the ConfigMap's
        # copy with the client credentials added, written at start by the
        # image's node to a memory-backed volume.
        oauthConfigFile = "${self.oauthMount.mountPath}/immich-config.json";
        oauthStart = ''
          node -e 'const fs = require("fs"); const c = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); c.oauth.clientId = process.env.OAUTH_CLIENT_ID; c.oauth.clientSecret = process.env.OAUTH_CLIENT_SECRET; fs.writeFileSync(process.argv[2], JSON.stringify(c), { mode: 0o600 })' ${self.configMount.mountPath}/immich-config.json ${oauthConfigFile}
        '';
        startSteps = lib.optional useSentinel sentinelStart ++ lib.optional oidcOn oauthStart;
        startScript = "set -e\n${lib.concatStrings startSteps}exec start.sh\n";
        valkeyPassword = lib.optionalAttrs (valkey.out ? authSecret) {
          REDIS_PASSWORD = valkey.out.authSecret.out.keyRef valkey.out.authPasswordKey;
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
        # With oidc.enabled the package owns these oauth keys; clientId and
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
        settingsCheck =
          let
            hits = builtins.filter (p: lib.hasAttrByPath p config.settings) ownedSettings;
            oidcHits = builtins.filter (p: lib.hasAttrByPath p config.settings) oidcOwnedSettings;
          in
          if lib.hasAttrByPath [ "oauth" "clientSecret" ] config.settings then
            throw "${who}: settings sets oauth.clientSecret, which the config ConfigMap would hold. Set oidc.enabled and wire the client id and secret through deps.oidcClient instead."
          else if oidcHits != [ ] then
            throw "${who}: settings sets ${
              lib.concatMapStringsSep ", " (lib.concatStringsSep ".") oidcHits
            }, which oidc.enabled sets. Use the oidc option and the oidcProvider and oidcClient dependencies instead."
          else if hits == [ ] then
            null
          else
            throw (
              lib.concatMapStringsSep "\n" (
                p:
                "${who}: settings sets ${lib.concatStringsSep "." p}, which follows the optional machineLearning dependency. Remove it from settings. ${mlFix}"
              ) hits
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
                          host = valkey.out.fqdn;
                          port = valkey.out.sentinelPort;
                        }
                      ];
                      name = valkey.out.primarySet;
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
                  from = "the valkey dependency, which runs Sentinel";
                  fix = "The container builds REDIS_URL from the Sentinel options at start, and Immich then ignores the other REDIS_* variables. Wire a different instance through deps.valkey.";
                }
              else
                {
                  vars = {
                    REDIS_HOSTNAME = depOut "valkey" valkey "fqdn";
                    REDIS_PORT = toString (depOut "valkey" valkey "port");
                  }
                  // valkeyPassword;
                  names = [
                    "REDIS_URL"
                    "REDIS_SOCKET"
                    "REDIS_SENTINEL_OPTIONS"
                  ];
                  from = "the valkey dependency";
                  fix = "Wire a different instance through deps.valkey.";
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
                if oidcOn then
                  { vars.IMMICH_CONFIG_FILE = oauthConfigFile; }
                else if self.configMount != null then
                  { vars.IMMICH_CONFIG_FILE = "${self.configMount.mountPath}/immich-config.json"; }
                else
                  { names = [ "IMMICH_CONFIG_FILE" ]; }
              )
            )
            (
              {
                from = "the oidcClient dependency";
                fix = "Wire another secret through deps.oidcClient.";
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
          if effectiveSettings == { } then
            null
          else
            scope.mkResource {
              apiVersion = "v1";
              kind = "ConfigMap";
              name = "${name}-config";
              data."immich-config.json" = builtins.toJSON effectiveSettings;
            }
        );

        libraryMount = kix.mount.pvc storage { mountPath = "/usr/src/app/upload"; };
        configMount = kix.mount.configMap self.configMap { mountPath = "/config"; };
        tmpMount = kix.mount.emptyDir {
          name = "tmp";
          mountPath = "/tmp";
          sizeLimit = "1Gi";
        };
        oauthMount =
          if oidcOn then
            kix.mount.emptyDir {
              name = "oauth-config";
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
                  if valkey.out ? authSecret then valkey.out.authSecret.out.identityHash or null else null;
                "checksum/oidc-client" = if oidcOn then oidcCredentials.out.identityHash or null else null;
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
                    throw "${who}: ${chownHint}"
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
                      volumeMounts = [ { inherit (self.libraryMount) name mountPath; } ];
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
          |> kix.withMounts [
            self.libraryMount
            self.configMount
            self.tmpMount
            self.oauthMount
          ]
          |> scope.mkDeployment;

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

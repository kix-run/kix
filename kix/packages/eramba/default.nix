# Eramba Community Edition — GRC (governance, risk & compliance) platform.
#
# Upstream ships only a docker-compose stack (github.com/eramba/docker,
# branch `1.x`). This package reproduces that stack's *supported* shape on
# Kubernetes, with two deliberate divergences called out below.
#
# Dependencies:
#   mysql   — required. Eramba is MySQL-only: upstream pins mysql:8.4.3-oracle
#             and has refused PostgreSQL ("not on the roadmap at all"). The
#             only MariaDB statement upstream is a 2021 forum post (10.2.20+),
#             unverified against 3.x — so the dep is named `mysql`, not
#             `database`, per PRINCIPLES §10 (be explicit about what you need).
#             Expects the `sql-database` contract: out.{host,port,database,
#             username,credentials}.
#   storage — required. Attachments + logs. RWO is fine (single replica).
#
# Exposure handled by kix.expose (ingress via DI). Apache listens plain HTTP
# on :80 and TLS is terminated at the ingress, so `trustProxy` is on by
# default.
#
# root = Service (port 80).
#
# ── Divergence 1: no `app` volume ────────────────────────────────────────
# Compose mounts a named volume over /var/www/eramba (the whole webroot).
# Docker seeds a named volume from the image; a k8s PVC does NOT — mounting
# a PVC there yields an empty webroot. That volume is also how Eramba
# self-updates from its web UI, which would silently drift the running code
# away from the pinned digest.
#
# Instead an initContainer seeds an emptyDir from the image on every start:
# the webroot is always exactly the pinned digest, and upgrades happen by
# bumping `image.tag` (which re-runs migrations via the entrypoint). The
# cost is that the in-app updater must not be used — see `meta.warnings`.
#
# ── Divergence 2: SECURITY_SALT is mandatory ─────────────────────────────
# Upstream generates the salt into app/upgrade/config/app_local.php on first
# boot and persists it via the `app` volume. With that volume gone the file
# is regenerated every start, so the salt MUST be injected. The generated
# file writes the salt as `env('SECURITY_SALT', '<generated>')` (see the
# rendered app_local.php, and config/app.php), so the env var wins over the
# generated value — supplying it here is both supported and stable. A changed
# salt makes already-encrypted DB columns unreadable, so this is a build-time
# error rather than a runtime surprise (PRINCIPLES §6).
#
# ── A note on reading upstream ───────────────────────────────────────────
# github.com/eramba/docker is NOT a reliable reference for this package.
# Compose bind-mounts that repo's docker-entrypoint.sh, docker-cron-entrypoint.sh
# and crontab over the copies baked into the image; without those mounts the
# image runs its own, materially different, versions. Verify behaviour against
# the image, not the repo.
#
# Not carried over from compose (deliberate): the `triggers_caddy` service and
# TRIGGER_RUNNER_SHARED_SECRET, so the 3.x automation-trigger feature does not
# work here — it needs a second image and NET_ADMIN. Also LDAPTLS_REQCERT,
# which only matters for LDAP over TLS with self-signed certs.

{
  scope,
  lib,
  kix,
}:

let
  name = scope.instanceName;

  # Compose runs eramba + cron as separate services sharing the `app`
  # volume, because the app container's entrypoint generates app_local.php
  # and cron reads it. lab1 has no RWX storage, so two pods cannot share
  # that volume — they must be one pod. This also keeps cron pinned to the
  # exact code the app is running.
  appMountPath = "/var/www/eramba";
  cakeRoot = "${appMountPath}/app/upgrade";

  # Upstream's crontab, minus the dead `@daily` entry, with logs sent to the
  # container's stdout instead of /var/log/cron.log (invisible to k8s), and
  # in /etc/cron.d format so `cron` reads it directly.
  #
  # `@daily` is dead code upstream: CronJobCommand refuses a direct `daily`
  # run ("Directly running daily type of CRON Job has been disabled") and
  # then returns success, so it fails silently. The hourly job self-triggers
  # the daily work at the tenant's local midnight.
  #
  # Every line is shaped by three constraints that interlock — change one and
  # you break another:
  #
  #   1. The `root` field. Files under /etc/cron.d are system crontabs and
  #      need a user field; without one cron rejects every line as a bad
  #      username and silently runs nothing.
  #   2. `su … www-data` INSIDE. Jobs must not run as root: they parse
  #      user-controlled data (imports, templates, PDF generation). The
  #      image's own baked crontab does exactly this.
  #   3. The redirect OUTSIDE the `su`. /proc/1/fd/1 is owned by root, so
  #      www-data cannot open it — redirecting inside the `su` makes every
  #      job die at the redirect and produce no output at all. Root's shell
  #      opens the fd; only the payload drops privileges.
  #
  # cron does not inherit the container environment, so each entry sources a
  # file the container writes at startup. Upstream uses `export $(cat ...)`,
  # which word-splits and breaks on any value containing whitespace; sourcing
  # `export -p` output quotes correctly regardless of the password's contents.
  cronJob =
    schedule: cmd:
    "${schedule} root su -s /bin/bash -c '. /var/www/docker.env && ${cmd}' www-data >> /proc/1/fd/1 2>&1";

  crontab = ''
    ${cronJob "@hourly" "/bin/sh ${cakeRoot}/bin/cake cron job hourly"}
    ${cronJob "@yearly" "/bin/sh ${cakeRoot}/bin/cake cron job yearly"}
    ${cronJob "* * * * *" "/bin/sh ${cakeRoot}/bin/cake queue run -v"}
  '';

  # Upstream's apache/vhost.conf verbatim (the plain-HTTP variant). Compose
  # mounts the *-ssl* variant and terminates TLS in-container with a bundled
  # self-signed dev cert; behind an ingress we want the plain one.
  #
  # This is currently byte-identical to the image's baked 000-default.conf, so
  # mounting it is a no-op today. It is kept deliberately: the baked config is
  # exactly the kind of thing that changes under us on an image bump (the
  # baked entrypoints already differ from upstream's repo), and Apache's
  # DocumentRoot + AllowOverride are load-bearing — .htaccess is what routes
  # / to app/upgrade/webroot. Pinning it makes the served config explicit,
  # diffable, and immune to that drift.
  vhostConf = ''
    <VirtualHost *:80 *:8080>
    	DocumentRoot "${appMountPath}"
        <Directory "${appMountPath}">
            AllowOverride all
            Require all granted
        </Directory>
        ErrorLog ''${APACHE_LOG_DIR}/error.log
        CustomLog ''${APACHE_LOG_DIR}/access.log combined

        LimitRequestLine 20000
    </VirtualHost>
  '';
in
{
  meta = {
    version = "3.30.1-6";
    description = "Eramba Community Edition — GRC platform";
    lifecycle = "stateful";
    scope = "namespace";
    provides = [ "grc" ];
    defaultAliases = [ "eramba" ];
  };

  options = {
    # `latest` resolved to 3.30.1-6 at time of writing; 3.31.0-7 existed but
    # had not been promoted to `latest`. Upstream's own upgrade docs retag to
    # `latest`, so treat their promotion as the signal and pin explicitly.
    image = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "ghcr.io/eramba/eramba";
        tag = "3.30.1-6";
        pullPolicy = "IfNotPresent";
      };
    };

    ingress = kix.options.ingress;

    publicAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://grc.example.com";
      description = ''
        Value for PUBLIC_ADDRESS. Defaults to https://<ingress.host>.

        Must match the URL the browser actually uses. A mismatch does not
        fail loudly — saving settings greys out the screen and the logo
        fails to load.

        Eramba must also be able to reach this address *itself*: PDF
        rendering (wkhtmltopdf) fetches assets from PUBLIC_ADDRESS, so the
        pod needs a hairpin/split-DNS path back to its own ingress.
      '';
    };

    securitySalt = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Value for SECURITY_SALT. Mutually exclusive with securitySaltSource.

        The plaintext lands in the Nix store and the rendered Secret
        manifest, so use securitySaltSource for anything real.
      '';
    };

    securitySaltSource = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a SOPS-encrypted file containing a `security-salt` key,
        hydrated by the deploy CLI at apply time.
      '';
    };

    existingSaltSecret = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = ''kix.untrackedRef "eramba-salt"'';
      description = ''
        Name of an existing Secret holding the salt, used instead of this
        package creating one. Mutually exclusive with securitySalt /
        securitySaltSource.

        Pass `kix.untrackedRef "..."` when the Secret is created outside kix
        (e.g. materialised by a secrets-manager controller): a raw string
        literal is rejected, since nothing in the graph would then guarantee
        the Secret exists.
      '';
    };

    existingSaltSecretKey = lib.mkOption {
      type = lib.types.str;
      default = "security-salt";
      description = "Key within `existingSaltSecret` holding the salt.";
    };

    trustProxy = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Sets TRUST_PROXY — honour X-Forwarded-* from the ingress. Note this
        is unrelated to USE_PROXY/PROXY_HOST, which configure an *outbound*
        proxy for reaching Eramba's own servers.
      '';
    };

    # Eramba cannot run offline: it requires egress to support-v3.eramba.org
    # (hardcoded, not overridable) and CE additionally requires an activation
    # token emailed to the admin address on first login.
    outboundProxy = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = false;
        host = null;
        port = null;
        auth = {
          enabled = false;
          user = null;
          password = null;
        };
      };
      description = "Outbound HTTP proxy used to reach Eramba's licensing/update servers.";
    };

    cacheUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "Redis://?server=redis&port=6379&password=&timeout=3";
      description = ''
        CACHE_URL DSN. Null uses CakePHP's FileEngine under the app
        emptyDir — fine at one replica, which is all Eramba supports.
      '';
    };

    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra environment variables (SCREAMING_SNAKE_CASE).";
    };

    appSizeLimit = lib.mkOption {
      type = lib.types.str;
      default = "3Gi";
      description = ''
        sizeLimit for the emptyDir holding the seeded application directory.

        The seeded webroot measures 765Mi (558M app + 203M laravel), not the
        ~500Mi the compressed image size suggests. The remainder is headroom
        for CakePHP's file cache and tmp/sessions, which are only used when
        `cacheUrl` is null. Exceeding sizeLimit gets the pod EVICTED, so this
        wants slack rather than precision.
      '';
    };

    # Upstream asks for 4Gi minimum / 8Gi recommended *plus 10Gi of swap*.
    # k8s nodes have swap off by default, and php.ini sets memory_limit=4096M,
    # so a single request can legitimately claim 4Gi and will OOMKill where
    # Docker would have swapped. Limits are sized for that, not for the
    # steady-state footprint.
    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
        requests = {
          cpu = "500m";
          memory = "2Gi";
        };
        limits = {
          cpu = "2";
          memory = "6Gi";
        };
      };
    };

    # The limit must exceed php.ini's `memory_limit = 4096M` (= 4Gi), not
    # equal it: a single queue job — PDF render, report, import — may legally
    # allocate the full 4096M, and PHP's own limit is per-request on top of
    # interpreter overhead. A 4Gi container limit means the job that PHP
    # considers legal is the job the kernel OOMKills, which restarts cron in
    # a loop against a live, serving webroot. 5Gi leaves headroom; requests
    # stay low so this is burstable, not reserved.
    cronResources = lib.mkOption {
      type = lib.types.anything;
      default = {
        requests = {
          cpu = "100m";
          memory = "512Mi";
        };
        limits = {
          cpu = "1";
          memory = "5Gi";
        };
      };
    };
  };

  build = [
    (
      {
        self,
        config,
        scope,
        lib,
        kix,
        mysql,
        storage,
        ...
      }:
      let
        effectiveHost = config.ingress.host or null;

        publicAddress =
          if config.publicAddress != null then
            config.publicAddress
          else if effectiveHost != null then
            "https://${effectiveHost}"
          else
            null;

        saltSources = lib.count (x: x != null) [
          config.securitySalt
          config.securitySaltSource
          config.existingSaltSecret
        ];

        # Losing the salt silently corrupts every encrypted column, and the
        # app emptyDir cannot carry it across restarts — so refuse to build
        # rather than let it be discovered after the first pod recycle.
        _saltCheck =
          if saltSources == 0 then
            throw (
              "eramba '${name}': set exactly one of `securitySalt`, `securitySaltSource` or "
              + "`existingSaltSecret`. The app directory is an emptyDir seeded from the image, so a "
              + "generated salt would change on every restart and make already-encrypted database "
              + "columns unreadable."
            )
          else if saltSources > 1 then
            throw "eramba '${name}': set exactly one of `securitySalt`, `securitySaltSource` or `existingSaltSecret`."
          else if publicAddress == null then
            throw (
              "eramba '${name}': set `ingress.host` or `publicAddress`. Eramba requires an "
              + "absolute PUBLIC_ADDRESS matching the browser URL."
            )
          else
            null;

        saltKey =
          if config.existingSaltSecret != null then config.existingSaltSecretKey else "security-salt";

        saltSecret =
          if config.existingSaltSecret != null then
            scope.mkSecretRef {
              name = config.existingSaltSecret;
              keys = [ saltKey ];
            }
          else
            scope.mkSecret {
              name = "${name}-salt";
              keys = [ "security-salt" ];
              stringData = lib.optionalAttrs (config.securitySalt != null) {
                security-salt = config.securitySalt;
              };
              source = config.securitySaltSource;
              labels = scope.selectorLabels;
              meta = {
                classification = "credential";
                rotationPolicy = "manual";
              };
            };

        # Eramba wants DB_HOST/DB_DATABASE; the sql-database contract's
        # `connectionEnv` helper emits DB_HOSTNAME/DB_DATABASENAME, so the
        # connection is wired by hand from the same `out` fields.
        dbEnv = kix.mkEnvVars {
          DB_HOST = mysql.out.host;
          DB_PORT = mysql.out.port;
          DB_DATABASE = mysql.out.database;
        };

        # Secret refs first: k8s only substitutes $(VAR) from vars defined
        # earlier in the list.
        credentialEnv =
          (mysql.out.credentials.out.mkEnv {
            DB_USERNAME = "username";
            DB_PASSWORD = "password";
          })
          ++ (saltSecret.out.mkEnv {
            SECURITY_SALT = saltKey;
          });

        appEnv =
          credentialEnv
          ++ dbEnv
          ++ kix.mkEnvVars (
            {
              PUBLIC_ADDRESS = publicAddress;
              # Signals to the app that it is running under the vendor's
              # container layout (paths, permissions).
              DOCKER_DEPLOYMENT = "1";
              TRUST_PROXY = if config.trustProxy then "1" else "0";
              CACHE_URL = config.cacheUrl;
              USE_PROXY = if config.outboundProxy.enabled then "1" else "0";
              PROXY_HOST = config.outboundProxy.host;
              PROXY_PORT = if config.outboundProxy.port != null then toString config.outboundProxy.port else null;
              USE_PROXY_AUTH = if config.outboundProxy.auth.enabled then "1" else "0";
              PROXY_AUTH_USER = config.outboundProxy.auth.user;
              PROXY_AUTH_PASS = config.outboundProxy.auth.password;
            }
            // config.env
          );

        image = "${config.image.repository}:${config.image.tag}";

        # `kix.mount.*` + withMountsOn cannot express this pod: the helpers
        # append a volume per call and reject duplicate volume names, but
        # `app`, `data` and `logs` must appear in *both* containers. So the
        # volumes are declared directly. `.out.name` keeps the Nix string
        # context, so the DI edges (and derived netpol/wave ordering) still
        # fall out of the graph. This is not a hand-rolled PVC — the claim
        # is still owned by the `storage` instance — so
        # scorecard:architecture.capabilityOwnership stays satisfied.
        volumes = [
          {
            name = "app";
            # sizeLimit works around adamcharnock/kixpkgs#9: kix's removeNulls
            # strips empty attrsets, so a bare `emptyDir = { }` is deleted
            # outright and leaves a sourceless Volume the API server rejects.
            # Any non-null field keeps it alive. The seeded webroot is ~500Mi;
            # the headroom covers the file cache when `cacheUrl` is null.
            emptyDir.sizeLimit = config.appSizeLimit;
          }
          {
            name = "data";
            persistentVolumeClaim.claimName = storage.out.name;
          }
          {
            name = "vhost";
            configMap.name = self.vhost.out.name;
          }
          {
            name = "crontab";
            configMap.name = self.crontab.out.name;
          }
        ];

        # Nested paths are fine: kubelet orders mounts by path depth, so
        # data/ and logs/ land on top of the seeded app emptyDir.
        sharedMounts = [
          {
            name = "app";
            mountPath = appMountPath;
          }
          {
            name = "data";
            mountPath = "${cakeRoot}/data";
            subPath = "data";
          }
          {
            name = "data";
            mountPath = "${cakeRoot}/logs";
            subPath = "logs";
          }
        ];

        # Seeds the shared emptyDir with the image's webroot. `cp -a` keeps
        # the www-data (uid 33) ownership the entrypoint expects.
        seedContainer = {
          name = "seed-app";
          inherit image;
          imagePullPolicy = config.image.pullPolicy;
          command = [
            "/bin/sh"
            "-c"
            "cp -a ${appMountPath}/. /seed/"
          ];
          resources = config.cronResources;
          volumeMounts = [
            {
              name = "app";
              mountPath = "/seed";
            }
          ];
        };

        # Keeps the image's baked entrypoint (unlike the cron container): it
        # runs composer post-install (generating app_local.php), rsyncs
        # data_template/ into data/, and then runs `database initialize` —
        # CakePHP migrations — aborting the container on a broken migration
        # history. Migrations therefore run on every app start; at one replica
        # that is safe, and it is what makes an image bump a real upgrade.
        # This container is the ONLY writer of app_local.php — see the cron
        # container for why that matters.
        erambaContainer = {
          name = "eramba";
          inherit image;
          imagePullPolicy = config.image.pullPolicy;
          ports = [ (kix.port "http" 80) ];
          env = appEnv;
          resources = config.resources;
          # Migrations gate Apache's start, so first boot (and any upgrade)
          # can take minutes. Liveness must not fire during that window.
          startupProbe = {
            httpGet = {
              path = "/settings/test-public-address";
              port = "http";
            };
            periodSeconds = 10;
            timeoutSeconds = 5;
            failureThreshold = 60;
          };
          readinessProbe = {
            httpGet = {
              path = "/settings/test-public-address";
              port = "http";
            };
            periodSeconds = 10;
            timeoutSeconds = 5;
            failureThreshold = 3;
          };
          livenessProbe = {
            tcpSocket.port = "http";
            periodSeconds = 20;
            timeoutSeconds = 5;
            failureThreshold = 5;
          };
          volumeMounts = sharedMounts ++ [
            {
              name = "vhost";
              mountPath = "/etc/apache2/sites-available/000-default.conf";
              subPath = "000-default.conf";
            }
          ];
        };

        # Deliberately does NOT use the image's /docker-cron-entrypoint.sh.
        #
        # The scripts baked into the image are not the ones in upstream's git
        # repo — compose bind-mounts the repo copies over them, so the repo
        # is a misleading reference for what a plain `docker run` executes.
        # The baked cron entrypoint does three things we must avoid:
        #
        #   - `crontab -u root <file>`, which would run every job as root
        #     (its own baked crontab compensates with an inner `su`; ours
        #     does that itself — see `cronJob`).
        #   - `composer run-script post-install-cmd`, which regenerates
        #     config/app_local.php. The app container's entrypoint does the
        #     same, into the SAME shared emptyDir, at the same moment — and
        #     the writes are plain copy()/file_put_contents(), not atomic. A
        #     torn read takes the pod down. Upstream has no such race because
        #     its cron container never runs composer. Only the app container
        #     writes app_local.php here.
        #   - `env >> /etc/environment`, unquoted, appended again on EVERY
        #     restart — an unbounded file that also mangles any value
        #     containing whitespace.
        #
        # All we actually need is the crontab installed and cron running.
        # /etc/cron.d is read natively, so nothing needs installing: dump the
        # environment for the jobs to source, then exec cron as PID 1 (which
        # is what makes the /proc/1/fd/1 redirect resolve to container
        # stdout).
        cronContainer = {
          name = "cron";
          inherit image;
          imagePullPolicy = config.image.pullPolicy;
          command = [
            "/bin/sh"
            "-c"
            "export -p > /var/www/docker.env && exec cron -f"
          ];
          env = appEnv;
          resources = config.cronResources;
          volumeMounts = sharedMounts ++ [
            {
              name = "crontab";
              mountPath = "/etc/cron.d/eramba-crontab";
              subPath = "eramba-crontab";
            }
          ];
        };
      in
      builtins.seq _saltCheck {
        salt = saltSecret;

        vhost = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-vhost";
          labels = scope.selectorLabels;
          data."000-default.conf" = vhostConf;
        };

        crontab = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-crontab";
          labels = scope.selectorLabels;
          data."eramba-crontab" = crontab;
        };

        deployment =
          {
            inherit name;
            spec = {
              replicas = 1;
              # Eramba keeps sessions and its fallback cache on local disk
              # and has no documented multi-replica story; the data PVC is
              # RWO regardless.
              strategy.type = "Recreate";
              selector.matchLabels = scope.selectorLabels;
              template.spec = {
                initContainers = [ seedContainer ];
                containers = [
                  erambaContainer
                  cronContainer
                ];
                # The image starts as root and its entrypoint drops to
                # www-data (uid 33) itself, so the pod cannot runAsNonRoot.
                securityContext.fsGroup = 33;
                inherit volumes;
              };
            };
          }
          |> scope.mkDeployment;

        service = self.deployment |> kix.service.fromWorkload { inherit name; } |> scope.mkResource;

        root = self.service;
      }
    )
    (kix.expose { service = "service"; })
  ];
}

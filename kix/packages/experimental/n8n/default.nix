# n8n: workflow automation in queue mode. The main Deployment serves the
# editor, the API, and webhooks and runs triggers; the worker Deployment
# runs executions it takes from a Valkey queue. Both use one PostgreSQL
# database.
#
# Code nodes run in an `n8nio/runners` sidecar on each worker pod (n8n's
# external task-runner mode), outside the n8n process. The main instance
# hands manual executions to the workers as well, so it runs no code and
# has no sidecar. An init container writes a random token per pod that the
# worker and its sidecar share; the worker's task broker listens on
# 127.0.0.1 only.
#
# Dependencies:
#   database (required)       a PostgreSQL database honouring the Postgres
#                             database contract
#                             (kix.contracts.postgresDatabase), such as a
#                             `stackgres-database` instance; n8n reads its
#                             host, port, database name, and credentials.
#   redis (required)          a Redis server honouring kix.contracts.redis:
#                             a `valkey` in this namespace, or a
#                             `kix.mkImport` in this namespace whose
#                             `out.credentials` names the password secret
#                             (`credentials = ref.<ns>.<secret>`). n8n has
#                             no Sentinel client, so the package turns
#                             Sentinel off on a managed valkey and refuses
#                             a server that publishes `out.sentinel`.
#                             n8n connects over TLS when `out.tls` is true.
#                             valkey itself needs a `valkeyPassword` secret
#                             (key `password`).
#   encryptionKey (required)  a `secret` or `secret-ref` with key `key`.
#                             n8n encrypts saved credentials with it, so
#                             the main instance and the workers must share
#                             it and it must outlive every pod. Generate it
#                             once with `openssl rand -hex 32`.
#   prometheus (optional)     a ServiceMonitor for the main instance when
#                             `metrics.enabled` is true.
#   ingressNginx or gateway, clusterIssuer (optional)
#                             the route from `kix.expose`. N8N_HOST,
#                             N8N_PROTOCOL, N8N_EDITOR_BASE_URL,
#                             N8N_WEBHOOK_URL, and N8N_PROXY_HOPS = "1"
#                             follow it; set them in `env` when TLS
#                             terminates outside Kix or another proxy sits
#                             in front.
#
# Each instance needs its own database, encryption key, and valkey. A second
# n8n in the same namespace resolves the same `database`, `encryptionKey`,
# and `valkey` as the first unless its `deps` name other instances, and two
# main instances on one database run every trigger twice.
#
# On ingress-nginx the package sets three `ingress.annotations` defaults;
# setting the same key replaces each one:
#   proxy-body-size                  the larger of `env.N8N_PAYLOAD_SIZE_MAX`
#                                    (default 16) and
#                                    `env.N8N_FORMDATA_FILE_SIZE_MAX`
#                                    (default 200), in MiB.
#   proxy-read-timeout, proxy-send-timeout
#                                    3600 seconds, for the editor's push
#                                    websocket.
#
# Minimal instances, with SOPS files that hold the secret values:
#
#   instances.n8n = {
#     n8n = {
#       package = packages.experimental.n8n;
#       config.ingress.host = "n8n.example.com";
#     };
#     n8n-db = {
#       package = packages.experimental.stackgres-database;
#       config.passwordSource = ./secrets/n8n-db.yaml;
#       config.passwordHash = "...";
#     };
#     n8n-encryption-key = {
#       package = packages.secret;
#       aliases = [ "encryptionKey" ];
#       config = {
#         source = ./secrets/n8n-encryption-key.yaml;
#         keys = [ "key" ];
#       };
#     };
#     valkey-password = {
#       package = packages.secret;
#       aliases = [ "valkeyPassword" ];
#       config = {
#         source = ./secrets/valkey-password.yaml;
#         keys = [ "password" ];
#       };
#     };
#   };
#
# With `availablePackages` set, valkey, the stackgres-cluster, and the
# stackgres-operator are instantiated automatically. valkey must run in
# n8n's namespace, because the pods read its password Secret.
#
# Workflows reach `world` on any port (`meta.network.intents`). Under an
# enforcer's default deny, a workflow that calls a Service inside the
# cluster is blocked until that Service admits n8n's pods: add a
# CiliumNetworkPolicy pair through `partsOverlays`, or open the namespaces
# with `namespaces.<ns>.networkPolicies.directions` plus an ingress intent
# on the target.
#
# `out`: `out.name`, `out.fqdn`, `out.port` (the main instance's Service).
# root = that Service; it requires the worker Deployment.
#
# Escape hatches: `env` (both n8n containers), `runners.env` (the sidecar),
# `worker.extraArgs` (for example `--concurrency=20`), and `partsOverlays`.
# Module allowlists for Code nodes are in the runners image's
# `/etc/n8n-task-runners.json`. To change them, replace the `worker` part
# through `partsOverlays` so that it mounts a file of your own at that path
# in the `task-runners` container.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  release = "2.41.5";

  name = scope.instanceName;
  who = "n8n ${scope.namespaceName}/${name}";

  httpPort = 5678;
  # n8n's default broker port on a worker in external task-runner mode.
  brokerPort = 5679;
  launcherHealthPort = 5680;

  tokenDir = "/run/n8n-runners";
  tokenFile = "${tokenDir}/auth-token";

  # Settings a worker and its runners must agree on. `env` sets them on
  # both, and `runners.env` overrides them on the sidecar. The launcher
  # passes them on to the runners it starts (its `allowed-env`).
  runnerSharedVars = [
    "GENERIC_TIMEZONE"
    "N8N_RUNNERS_TASK_TIMEOUT"
    "N8N_RUNNERS_MAX_CONCURRENCY"
  ];

  # n8n and the task-runner launcher also read a setting from the file
  # named by `<VAR>_FILE`. n8n prefers `<VAR>` and the launcher prefers
  # `<VAR>_FILE`, so the package refuses the `_FILE` twin of each variable
  # it sets.
  twins = vars: map (n: "${n}_FILE") (lib.filter (n: !lib.hasSuffix "_FILE" n) (lib.attrNames vars));

  # The ingress-nginx body limit: the larger of n8n's two request limits
  # (`N8N_PAYLOAD_SIZE_MAX`, default 16, and `N8N_FORMDATA_FILE_SIZE_MAX`,
  # default 200, both in MiB), so the proxy never rejects a request n8n
  # would accept. A variable from `valueFrom` or null counts as n8n's
  # default.
  bodyMaxMiB =
    env:
    let
      sizeMiB =
        var: default:
        let
          v = env.${var} or null;
        in
        if !builtins.isString v then
          default
        else if builtins.match "[0-9]+" v != null then
          lib.toIntBase10 v
        else
          throw "${who}: env.${var} is \"${v}\"; n8n reads it as a whole number of MiB (for example \"64\").";
    in
    lib.max (sizeMiB "N8N_PAYLOAD_SIZE_MAX" 16) (sizeMiB "N8N_FORMDATA_FILE_SIZE_MAX" 200);

  hardening = {
    allowPrivilegeEscalation = false;
    readOnlyRootFilesystem = true;
    capabilities.drop = [ "ALL" ];
  };

  httpProbe = port: path: {
    httpGet = { inherit path port; };
    periodSeconds = 10;
    timeoutSeconds = 1;
    failureThreshold = 3;
  };
in
{
  meta = {
    version = release;
    description = "n8n workflow automation: a main instance and queue workers with Code-node task-runner sidecars, on PostgreSQL and Valkey";
    owner = "app-team";
    # Workflows call services the workflow author chooses, on any port.
    # `world` does not include endpoints inside the cluster.
    network.intents.workflows.egress = [ { to = "world"; } ];
  };

  deps.database.assertions = dep: kix.contracts.postgresDatabase.assertions who dep;

  # n8n has no Sentinel client, and with Sentinel the valkey Service also
  # routes to read-only replicas, so n8n asks its valkey for a standalone
  # pod.
  deps.redis = {
    renamedFrom = kix.contracts.redis.helpers.renamedFrom;
    config.sentinel.enabled = false;
    # An import is not reached by the injection above.
    assertions =
      dep:
      kix.contracts.redis.assertions who dep
      ++ lib.optional (kix.contracts.redis.helpers.usesSentinel dep) {
        assertion = false;
        message = "n8n needs a standalone valkey with one pod: it has no Sentinel client, so its queue writes would reach read-only replicas through the valkey Service. Wire a valkey with sentinel.enabled = false.";
      };
  };

  options = {
    image = kix.options.image {
      repository = "docker.io/n8nio/n8n";
      tag = release;
      digest = "sha256:6f532d3b819cfe66c6a13c5375228f312c53df1abaa11a377eb8c3d3f105c363";
      description = "The n8n image, for the main instance, the workers, and the init container that writes the task-runner token.";
    };

    resources = kix.options.resources {
      requests = {
        cpu = "100m";
        memory = "256Mi";
      };
      limits = {
        cpu = "1";
        memory = "1Gi";
      };
      description = "Requests and limits of the main instance's n8n container. Each field keeps its default until set, and null removes a default.";
    };

    env = kix.options.env // {
      description = "Extra environment variables for the n8n container of the main instance and of every worker. A value is a string, a `fieldRef` source such as `{ valueFrom.fieldRef.fieldPath = \"metadata.name\"; }`, or a `secretKeyRef` source naming a Secret managed outside Kix with `kix.untrackedRef`. Credentials from the dependencies are wired by the package. Null removes a variable the package sets by default. ${lib.concatStringsSep ", " runnerSharedVars} also reach the task-runner sidecar; set other runner settings in `runners.env`.";
    };

    worker = {
      replicas = lib.mkOption {
        type = lib.types.ints.positive;
        default = kix.availability.pick availability {
          none = 1;
          pod = 2;
          node = 2;
          zone = 2;
        };
        defaultText = lib.literalMD "1 at availability `none`, 2 above";
        description = "Number of worker pods. Each takes executions from the queue.";
      };

      resources = kix.options.resources {
        requests = {
          cpu = "100m";
          memory = "256Mi";
        };
        limits = {
          cpu = "1";
          memory = "1Gi";
        };
        description = "Requests and limits of each worker's n8n container. Each field keeps its default until set, and null removes a default.";
      };

      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "--concurrency=20" ];
        description = "Arguments appended to `n8n worker`.";
      };
    };

    runners = {
      image = kix.options.image {
        repository = "docker.io/n8nio/runners";
        tag = release;
        digest = "sha256:32619142405e7f4a02eedffe8584214c7e0b9b09d3753094e4212aee5f4d0045";
        tagText = "config.image.tag";
        description = "The task-runner sidecar image. Its version must match the n8n image's, so its tag follows `image.tag`.";
      };

      resources = kix.options.resources {
        requests = {
          cpu = "50m";
          memory = "128Mi";
        };
        limits = {
          cpu = "1";
          memory = "512Mi";
        };
        description = "Requests and limits of each worker's task-runner sidecar, shared by the JavaScript and Python runners it starts. Each field keeps its default until set, and null removes a default.";
      };

      env = kix.options.env // {
        description = "Extra environment variables for the task-runner sidecar. The launcher passes the names in its `allowed-env` list on to the runners. A value is a string, a `fieldRef` source, or a `secretKeyRef` source naming a Secret managed outside Kix with `kix.untrackedRef`. A value here wins over the same name in `env`.";
      };
    };

    ingress = kix.options.ingress;

    metrics = kix.options.monitor // {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Turn on n8n's /metrics endpoint, with queue metrics, and a ServiceMonitor when a prometheus dependency is present. The endpoint is served on the editor's port, so a route publishes it too.";
      };
    };
  };

  config =
    { config, ... }:
    {
      runners.image.tag = lib.mkDefault config.image.tag;
      # The editor's push channel is a websocket that n8n pings every 60
      # seconds, which equals ingress-nginx's default read timeout.
      ingress.annotations = lib.mapAttrs (_: lib.mkDefault) {
        "nginx.ingress.kubernetes.io/proxy-body-size" = "${toString (bodyMaxMiB config.env)}m";
        "nginx.ingress.kubernetes.io/proxy-read-timeout" = "3600";
        "nginx.ingress.kubernetes.io/proxy-send-timeout" = "3600";
      };
    };

  build = [
    (
      {
        self,
        config,
        scope,
        kix,
        database,
        redis,
        encryptionKey,
        ...
      }:
      let
        exposure = self.exposure;

        ek = kix.checkSecretKeys {
          inherit who;
          arg = "encryptionKey";
          dep = encryptionKey;
          keys = [ "key" ];
        };

        valkeyAuth = redis.out ? credentials;

        # A `kix.mergeEnv` owned group that also refuses the `_FILE` twins.
        group = vars: extra: { inherit vars; } // extra // { names = twins vars ++ extra.names or [ ]; };

        databaseGroup =
          group
            {
              DB_TYPE = "postgresdb";
              DB_POSTGRESDB_HOST = database.out.host;
              DB_POSTGRESDB_PORT = database.out.port;
              DB_POSTGRESDB_DATABASE = database.out.database;
              DB_POSTGRESDB_USER = database.out.credentials.out.keyRef "username";
              DB_POSTGRESDB_PASSWORD = database.out.credentials.out.keyRef "password";
            }
            {
              from = "the database dependency";
              fix = "Wire a different database instance through deps.database instead.";
            };

        valkeyGroup =
          group
            (
              {
                QUEUE_BULL_REDIS_HOST = redis.out.host;
                QUEUE_BULL_REDIS_PORT = redis.out.port;
              }
              // lib.optionalAttrs (redis.out.tls or false) { QUEUE_BULL_REDIS_TLS = "true"; }
              // lib.optionalAttrs valkeyAuth {
                QUEUE_BULL_REDIS_PASSWORD = redis.out.credentials.out.keyRef "password";
              }
            )
            {
              from = "the redis dependency";
              fix = "Wire a different valkey through deps.redis instead.";
            };

        encryptionKeyGroup = group { N8N_ENCRYPTION_KEY = ek.out.keyRef "key"; } {
          from = "the encryptionKey dependency";
          fix = "Wire a different secret through deps.encryptionKey instead.";
        };

        sharedStructure = {
          EXECUTIONS_MODE = "queue";
          N8N_PORT = toString httpPort;
        };
        # The worker's health server answers the probes on the Service's
        # port, and its broker serves the sidecar on 127.0.0.1.
        workerStructure = {
          N8N_RUNNERS_MODE = "external";
          N8N_RUNNERS_AUTH_TOKEN_FILE = tokenFile;
          N8N_RUNNERS_BROKER_PORT = toString brokerPort;
          QUEUE_HEALTH_CHECK_ACTIVE = "true";
          QUEUE_HEALTH_CHECK_PORT = toString httpPort;
        };
        # `env` reaches both roles, so each role refuses the other role's
        # names as well as its own.
        structureGroup =
          role:
          let
            vars = sharedStructure // lib.optionalAttrs (role == "worker") workerStructure;
            all = sharedStructure // workerStructure;
          in
          {
            inherit vars;
            # A token set by hand would win over the `_FILE` value and no
            # longer match the sidecar's.
            names =
              lib.subtractLists (lib.attrNames vars) (lib.attrNames all)
              ++ twins all
              ++ [ "N8N_RUNNERS_AUTH_TOKEN" ];
            from = "the package's queue-mode and task-runner wiring";
            fix = "Remove it: the package sets it so queue mode, the task-runner sidecar, the Service, and the probes agree.";
          };

        # n8n 2.35 deprecated WEBHOOK_URL in favour of N8N_WEBHOOK_URL and
        # ignores the old name while the new one is set, which the package
        # does when the instance has a route.
        legacyWebhookGroup = {
          names = [ "WEBHOOK_URL" ];
          from = "n8n releases before 2.35 (2.35 deprecated it in favour of N8N_WEBHOOK_URL)";
          fix = "Set N8N_WEBHOOK_URL instead. The package sets it from the instance's route when there is one, and env overrides that.";
        };

        # Workers need the public URL too: a Wait node's resume URL is built
        # where the execution runs. Without a URL Kix can derive, the package
        # sets none of these and `env` can.
        exposureDefaults = lib.optionalAttrs (exposure.urlOrNull != null) {
          N8N_HOST = exposure.host;
          N8N_PROTOCOL = exposure.scheme;
          N8N_EDITOR_BASE_URL = "${exposure.url}/";
          N8N_WEBHOOK_URL = "${exposure.url}/";
          N8N_PROXY_HOPS = "1";
        };

        defaultsFor =
          role:
          exposureDefaults
          // lib.optionalAttrs (role == "main") (
            {
              # Main then runs no executions and starts no task broker.
              OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS = "true";
            }
            // lib.optionalAttrs config.metrics.enabled {
              N8N_METRICS = "true";
              N8N_METRICS_INCLUDE_QUEUE_METRICS = "true";
            }
          );

        n8nEnv =
          role:
          kix.mkEnvVars (
            kix.mergeEnv {
              inherit who;
              defaults = defaultsFor role;
              owned = [
                databaseGroup
                valkeyGroup
                encryptionKeyGroup
                (structureGroup role)
                legacyWebhookGroup
              ];
            } config.env
          );

        runnerEnv = kix.mkEnvVars (
          kix.mergeEnv {
            who = "${who} runners.env";
            defaults = lib.getAttrs (lib.intersectLists runnerSharedVars (lib.attrNames config.env)) config.env;
            owned = [
              (group
                {
                  N8N_RUNNERS_TASK_BROKER_URI = "http://127.0.0.1:${toString brokerPort}";
                  N8N_RUNNERS_AUTH_TOKEN_FILE = tokenFile;
                  N8N_RUNNERS_LAUNCHER_HEALTH_CHECK_PORT = toString launcherHealthPort;
                }
                {
                  names = [ "N8N_RUNNERS_AUTH_TOKEN" ];
                  from = "the task-runner wiring";
                  fix = "Remove it: the package connects the sidecar to its worker's broker and probes.";
                }
              )
            ];
          } config.runners.env
        );

        # The containers read these Secrets as env, which a running pod never
        # re-reads. A `secret-ref` has no hash, because its data lives
        # outside Kix; it rolls through reloader's `withReloadOn`.
        depHash =
          n: d:
          lib.optionalAttrs (d.out ? identityHash) {
            "checksum/${n}" = d.out.identityHash;
          };
        podAnnotations =
          depHash "database" database.out.credentials
          // depHash "encryption-key" ek
          // lib.optionalAttrs valkeyAuth (depHash "valkey-password" redis.out.credentials);

        # The broker accepts connections from 127.0.0.1 only, so a random
        # token per pod authenticates the sidecar without a Secret. The init
        # container writes it; the other containers read it.
        tokenMount =
          readOnly:
          kix.mount.emptyDir {
            name = "runners-token";
            mountPath = tokenDir;
            medium = "Memory";
            sizeLimit = "1Mi";
            inherit readOnly;
          };

        imagePull =
          image: lib.optionalAttrs (image.pullPolicy != null) { imagePullPolicy = image.pullPolicy; };

        n8nContainer =
          role:
          {
            name = "n8n";
            image = kix.image.ref config.image;
            ports = [ (kix.port "http" httpPort) ];
            env = n8nEnv role;
            # n8n listens only after the main instance has run the database
            # migrations, so startup allows five minutes. The readiness
            # endpoint checks the database connection; a worker's also
            # checks Valkey.
            startupProbe = httpProbe "http" "/healthz" // {
              failureThreshold = 30;
            };
            livenessProbe = httpProbe "http" "/healthz";
            readinessProbe = httpProbe "http" "/healthz/readiness";
            resources = if role == "main" then config.resources else config.worker.resources;
            securityContext = hardening;
          }
          // lib.optionalAttrs (role == "worker") {
            args = [ "worker" ] ++ config.worker.extraArgs;
          }
          // imagePull config.image;

        tokenInit = {
          name = "runners-token";
          image = kix.image.ref config.image;
          command = [
            "node"
            "-e"
            "require('fs').writeFileSync('${tokenFile}', require('crypto').randomBytes(32).toString('hex'), { mode: 0o600 })"
          ];
          resources = {
            requests = {
              cpu = "10m";
              memory = "32Mi";
            };
            limits = {
              cpu = "100m";
              memory = "128Mi";
            };
          };
          securityContext = hardening;
        }
        // imagePull config.image;

        # The image's entrypoint starts the launcher for the JavaScript and
        # Python runners.
        runnersContainer = {
          name = "task-runners";
          image = kix.image.ref config.runners.image;
          ports = [ (kix.port "health" launcherHealthPort) ];
          env = runnerEnv;
          livenessProbe = httpProbe "health" "/healthz";
          readinessProbe = httpProbe "health" "/healthz";
          resources = config.runners.resources;
          securityContext = hardening;
        }
        // imagePull config.runners.image;

        selectorFor = role: scope.selectorLabels // { "app.kubernetes.io/component" = role; };

        # n8n writes its instance settings, files that file nodes may touch
        # (`~/.n8n-files`, n8n's default limit), compiled assets, and
        # temporary files. With the encryption key supplied and queue mode
        # keeping binary data in the database, none of them must survive a
        # restart; durable files belong in object storage. The size limits
        # evict a pod whose workflow fills them.
        n8nMounts = kix.withMountsOn "n8n" [
          (kix.mount.emptyDir {
            name = "data";
            mountPath = "/home/node/.n8n";
            sizeLimit = "1Gi";
          })
          (kix.mount.emptyDir {
            name = "files";
            mountPath = "/home/node/.n8n-files";
            sizeLimit = "1Gi";
          })
          (kix.mount.emptyDir {
            name = "cache";
            mountPath = "/home/node/.cache";
            sizeLimit = "256Mi";
          })
          (kix.mount.emptyDir {
            name = "tmp";
            mountPath = "/tmp";
            sizeLimit = "1Gi";
          })
        ];

        # `/home/runner` is the runners' working directory.
        runnerMounts = kix.withMountsOn "task-runners" [
          (kix.mount.emptyDir {
            name = "runner-tmp";
            mountPath = "/tmp";
            sizeLimit = "512Mi";
          })
          (kix.mount.emptyDir {
            name = "runner-home";
            mountPath = "/home/runner";
            sizeLimit = "256Mi";
          })
        ];

        podSpec = {
          automountServiceAccountToken = false;
          # The instance's Service, named `n8n` by default, would otherwise
          # inject N8N_PORT=tcp://... and other variables with n8n's N8N_
          # prefix into every container.
          enableServiceLinks = false;
          # n8n waits up to 30 s for running executions, and the launcher up
          # to 50 s for its runners.
          terminationGracePeriodSeconds = 60;
          securityContext = {
            runAsNonRoot = true;
            runAsUser = 1000;
            runAsGroup = 1000;
            fsGroup = 1000;
            seccompProfile.type = "RuntimeDefault";
          };
        };
      in
      builtins.seq (bodyMaxMiB config.env) {
        # The main instance owns triggers and schedules, and multi-main is an
        # n8n Enterprise feature, so a second main pod, even during a
        # rolling update, runs every trigger twice.
        deployment =
          {
            inherit name;
            availability.max = "none";
            spec = {
              replicas = 1;
              strategy.type = "Recreate";
              selector.matchLabels = selectorFor "main";
              template = {
                metadata.annotations = podAnnotations;
                spec = podSpec // {
                  containers = [ (n8nContainer "main") ];
                };
              };
            };
          }
          |> n8nMounts
          |> scope.mkDeployment;

        worker =
          {
            name = "${name}-worker";
            spec = {
              replicas = config.worker.replicas;
              selector.matchLabels = selectorFor "worker";
              template = {
                metadata.annotations = podAnnotations;
                spec = podSpec // {
                  initContainers = [ tokenInit ];
                  containers = [
                    (n8nContainer "worker")
                    runnersContainer
                  ];
                };
              };
            };
          }
          |> kix.withMountsOn "runners-token" [ (tokenMount false) ]
          |> kix.withMountsOn [ "n8n" "task-runners" ] [ (tokenMount true) ]
          |> n8nMounts
          |> runnerMounts
          |> scope.mkDeployment;

        service =
          self.deployment
          |> kix.service.fromWorkload {
            inherit name;
            ports = [
              {
                name = "http";
                port = httpPort;
                targetPort = "http";
                protocol = "TCP";
              }
            ];
          }
          |> scope.mkResource;

        # Nothing else references the workers.
        root = {
          resource = self.service;
          requires = [ self.worker ];
        };
      }
    )

    # Envoy's default 15 s route timeout, which applies on an Envoy-based
    # gateway when the HTTPRoute sets none, would cut the editor's push
    # websocket.
    (kix.expose {
      service = "service";
      timeouts.request = "0s";
    })

    (kix.monitor {
      service = "service";
      port = "http";
    })
  ];
}

# tempo: Grafana Tempo as one single-binary pod on one volume.
#
# One StatefulSet pod runs every Tempo component (`-target=all`) in one
# process: the distributor with OTLP receivers, the live store, the query
# frontend and querier, the backend scheduler and worker, and, when
# `metricsGenerator.enabled` is true, the metrics generator. Write-ahead logs
# live on the `storage` claim, along with trace blocks unless `objectStorage`
# sends them to an S3 bucket.
#
# The `<name>` Service serves the query API and metrics on 3200, and the
# `<name>-otlp` Service serves the OTLP receivers on 4317 (gRPC) and 4318
# (HTTP). `root` is the `<name>` Service.
#
#   instances.tracing = {
#     storage = { package = packages.persistent-volume-claim; config.size = "20Gi"; };
#     tempo.package = packages.experimental.tempo;
#   };
#
# Dependencies:
#   storage (required)           Persistent-volume-claim mounted at /var/tempo.
#   prometheus (optional)        ServiceMonitor and PrometheusRule alerts.
#   storageCredentials           Secret or secret-ref with S3 keys
#                                (`accessKeyId` and `secretAccessKey`, or as
#                                mapped in `objectStorage.credentialKeys`).
#                                Required when `objectStorage` is set.
#   endpointService (optional)   In-cluster S3 Service when `objectStorage` is
#                                set; derives `storage.trace.s3.endpoint` and
#                                network policy.
#   prometheusServer (optional)  Remote-write target (`out.remoteWriteUrl`);
#                                required when `metricsGenerator.enabled` is
#                                true.
#
# Exposes (`root.out`, checked by `kix.contracts.experimental.otlpEndpoint`):
#   out.otlpGrpcUrl, out.otlpHttpUrl, out.tls (false), out.queryUrl.
#   out.version, the Tempo version `image.tag` names.
#
# Limits: single replica (`meta.availability.max = "none"`) and single tenant.
#
# Upgrades: upstream's upgrade guide has a section for each minor release and
# none for patch releases, so 3.1.0 to 3.1.1 is one step. The 3.1.1 image is
# built with a newer Go toolchain, and Tempo's own code is unchanged. In a
# test on kind, 3.1.1 served the traces that 3.1.0 wrote, and 3.1.0 read the
# traces that 3.1.1 wrote after the going-back deploy. Upstream documents no
# way back to an older 3.1 release. To go back to 3.1.0, deploy the previous
# package version.

{
  scope,
  lib,
  kix,
}:
let
  name = scope.instanceName;
  who = "tempo ${scope.namespaceName}/${name}";
  release = "3.1.1";

  httpPort = 3200;
  otlpGrpcPort = 4317;
  otlpHttpPort = 4318;
  dataPath = "/var/tempo";
  configDir = "/etc/tempo";

  # Return dotted paths of any strings containing `\` because Tempo's
  # `-config.expand-env=true` treats `\\` in rendered JSON as an escape.
  backslashPaths =
    path: v:
    if builtins.isString v then
      lib.optional (lib.hasInfix "\\" v) (lib.concatStringsSep "." path)
    else if builtins.isAttrs v then
      lib.concatLists (lib.mapAttrsToList (k: backslashPaths (path ++ [ k ])) v)
    else if builtins.isList v then
      lib.concatLists (lib.imap0 (i: backslashPaths (path ++ [ "[${toString i}]" ])) v)
    else
      [ ];

  builtinConfig =
    {
      retention,
      store,
      remoteWriteUrl,
    }:
    {
      target = "all";
      multitenancy_enabled = false;
      auth_enabled = false;
      http_api_prefix = "";
      memory.automemlimit_enabled = true;
      server = {
        http_listen_port = httpPort;
        log_level = "info";
      };
      distributor.receivers.otlp.protocols = {
        grpc.endpoint = "0.0.0.0:${toString otlpGrpcPort}";
        http.endpoint = "0.0.0.0:${toString otlpHttpPort}";
      };
      live_store = {
        wal.path = "${dataPath}/live-store/traces";
        shutdown_marker_dir = "${dataPath}/live-store/shutdown-marker";
      };
      backend_scheduler.local_work_path = "${dataPath}/backend-scheduler";
      storage.trace =
        if store == null then
          {
            backend = "local";
            local.path = "${dataPath}/blocks";
          }
        else
          {
            backend = "s3";
            s3 = store // {
              prefix = "${scope.namespaceName}/${name}";
            };
          };
      overrides.defaults = {
        compaction.block_retention = retention;
      }
      // lib.optionalAttrs (remoteWriteUrl != null) {
        metrics_generator.processors = [
          "service-graphs"
          "span-metrics"
        ];
      };
      usage_report.reporting_enabled = false;
    }
    // lib.optionalAttrs (remoteWriteUrl != null) {
      metrics_generator.storage = {
        path = "${dataPath}/generator/wal";
        remote_write = [ { url = remoteWriteUrl; } ];
      };
    };

  generatorPaths = [
    [
      "metrics_generator"
      "storage"
      "path"
    ]
    [
      "metrics_generator"
      "storage"
      "remote_write"
    ]
  ];

  lockedPaths =
    {
      objectStorage,
      inClusterStore,
      metricsGenerator,
    }:
    [
      [ "target" ]
      [ "multitenancy_enabled" ]
      [ "auth_enabled" ]
      [ "http_api_prefix" ]
      [
        "server"
        "http_listen_port"
      ]
      [
        "distributor"
        "receivers"
        "otlp"
        "protocols"
        "grpc"
        "endpoint"
      ]
      [
        "distributor"
        "receivers"
        "otlp"
        "protocols"
        "http"
        "endpoint"
      ]
      [
        "live_store"
        "wal"
        "path"
      ]
      [
        "live_store"
        "shutdown_marker_dir"
      ]
      [
        "backend_scheduler"
        "local_work_path"
      ]
      [
        "storage"
        "trace"
        "backend"
      ]
      [
        "storage"
        "trace"
        "local"
        "path"
      ]
      [
        "overrides"
        "defaults"
        "compaction"
        "block_retention"
      ]
    ]
    ++ lib.optionals metricsGenerator generatorPaths
    ++ lib.optional objectStorage [
      "storage"
      "trace"
      "s3"
      "bucket"
    ]
    ++ lib.optionals inClusterStore [
      [
        "storage"
        "trace"
        "s3"
        "endpoint"
      ]
      [
        "storage"
        "trace"
        "s3"
        "insecure"
      ]
    ];

  s3CredentialPaths = [
    [ "access_key" ]
    [ "secret_key" ]
    [ "session_token" ]
    [
      "sse"
      "encryption_key"
    ]
  ];

  credentialSelectors = [
    "accessKeyId"
    "secretAccessKey"
  ];

  matchEndpoint = builtins.match "(\\[[^]]*]|[^]/:?#[]+)(:([0-9]+))?";

  ownedFlags =
    let
      locks = path: "it sets ${path}, which the package locks; remove it.";
      secret =
        path:
        "it puts ${path}, a credential, on the command line; put the keys in the storageCredentials Secret and remove the flag.";
      flags = {
        "-config.file" = "the package renders the file from settings; change settings instead.";
        "-config.expand-env" = "settings and env rely on variable expansion; remove it.";
        "-target" = "the package runs every Tempo component in its one pod; remove it.";
        "-auth.enabled" = locks "auth_enabled";
        "-multitenancy.enabled" = locks "multitenancy_enabled";
        "-http-api-prefix" = locks "http_api_prefix";
        "-server.http-listen-port" = locks "server.http_listen_port";
        "-storage.trace.backend" = locks "storage.trace.backend";
        "-storage.trace.local.path" = locks "storage.trace.local.path";
        "-live-store.wal.path" = locks "live_store.wal.path";
        "-live-store.shutdown_marker_dir" = locks "live_store.shutdown_marker_dir";
        "-backend-schedulerbackend-scheduler.local-work-path" = locks "backend_scheduler.local_work_path";
        "-storage.trace.s3.bucket" =
          "it sets storage.trace.s3.bucket, which objectStorage.bucket owns; remove it.";
        "-storage.trace.s3.endpoint" =
          "it sets storage.trace.s3.endpoint, from which the package derives the store's network policy; set the endpoint in settings or wire endpointService, and remove the flag.";
        "-storage.trace.s3.access_key" = secret "storage.trace.s3.access_key";
        "-storage.trace.s3.secret_key" = secret "storage.trace.s3.secret_key";
        "-storage.trace.s3.session_token" = secret "storage.trace.s3.session_token";
        "-storage.trace.s3.sse.encryption-key" =
          "it puts storage.trace.s3.sse.encryption_key, a credential, on the command line, and the package has no way to pass an SSE-C key from a Secret; remove the flag.";
      };
    in
    flags // lib.mapAttrs' (flag: lib.nameValuePair "-${flag}") flags;
in
{
  meta = {
    version = release;
    description = "Grafana Tempo trace store, single binary on one volume";
    owner = "platform";
    defaultAliases = [ "tempo" ];
    availability.max = "none";
    # Tempo's documentation requires Kubernetes 1.25 or later for Tempo 3
    # (the Software requirements of the tempo-distributed get-started page),
    # and states no upper bound. Move the lower bound with `release`.
    k8s = {
      minVersion = "1.25";
      reason = "[K2763] Tempo ${release} requires Kubernetes 1.25 or later. Deploy a Kix release with an older tempo package, or move the cluster to Kubernetes 1.25 or later first";
    };
  };

  options = import ./options.nix {
    inherit
      lib
      kix
      release
      credentialSelectors
      ;
  };

  build = [
    (
      {
        self,
        config,
        clusterConfig,
        scope,
        kix,
        storage,
        storageCredentials ? null,
        endpointService ? null,
        prometheusServer ? null,
        ...
      }:
      let
        backslashes = backslashPaths [ "settings" ] config.settings;
        s3Settings = config.settings.storage.trace.s3 or { };
        inlineCredentials = builtins.filter (path: lib.hasAttrByPath path s3Settings) s3CredentialPaths;
        generatorSettings = lib.optionals (!config.metricsGenerator.enabled) (
          builtins.filter (path: lib.hasAttrByPath path config.settings) (
            generatorPaths
            ++ [
              [
                "overrides"
                "defaults"
                "metrics_generator"
                "processors"
              ]
            ]
          )
        );
        settings =
          if backslashes != [ ] then
            scope.fail {
              package = "tempo";
              option = "settings";
              message = "${lib.concatStringsSep ", " backslashes} holds a backslash. Tempo expands environment variables in its config file and reads a backslash as an escape, which breaks the file.";
              fix = "Remove the backslash from the value.";
            }
          else if generatorSettings != [ ] then
            scope.fail {
              package = "tempo";
              option = "settings";
              message = "settings sets ${
                lib.concatMapStringsSep ", " (lib.concatStringsSep ".") generatorSettings
              }, which configures the metrics generator while metricsGenerator.enabled is false.";
              fix = "Remove it, or set metricsGenerator.enabled = true, which runs the generator and writes to the prometheusServer dependency.";
            }
          else if inlineCredentials != [ ] then
            scope.fail {
              package = "tempo";
              option = "settings";
              message = "settings sets ${
                lib.concatMapStringsSep ", " (
                  path: lib.concatStringsSep "." ([ "storage.trace.s3" ] ++ path)
                ) inlineCredentials
              }, a credential that would land in the ConfigMap.";
              fix = "Remove it. The package reads the S3 access keys from the storageCredentials dependency (a secret or secret-ref instance); it has no way to pass an SSE-C key from a Secret.";
            }
          else
            config.settings;

        os = config.objectStorage;
        objectStorageOn = os != null;
        inClusterStore = objectStorageOn && endpointService != null;

        credentialKeys = lib.genAttrs credentialSelectors (
          s: if os.credentialKeys.${s} != null then os.credentialKeys.${s} else s
        );
        credentials = kix.contracts.secret.helpers.use {
          inherit who;
          arg = "storageCredentials";
          dep =
            if storageCredentials == null then
              scope.fail {
                package = "tempo";
                option = "objectStorage";
                message = "objectStorage is set and no storageCredentials dependency resolved in namespace ${scope.namespaceName}.";
                fix = "Add a secret or secret-ref instance there with the keys ${lib.concatStringsSep " and " (builtins.attrValues credentialKeys)} and the alias storageCredentials, or set objectStorage = null.";
              }
            else
              storageCredentials;
          keys = builtins.attrValues credentialKeys;
        };

        endpointScheme = if os.endpointScheme != null then os.endpointScheme else "http";
        store =
          if !objectStorageOn then
            if endpointService != null then
              scope.fail {
                package = "tempo";
                message = "deps.endpointService is wired and objectStorage is null, so Tempo keeps its blocks on the claim and never reads the store.";
                fix = "Set objectStorage.bucket, or remove deps.endpointService.";
              }
            else
              null
          else if inClusterStore then
            {
              inherit (os) bucket;
              endpoint = lib.removePrefix "${endpointScheme}://" (
                (endpointService.out.url or (scope.fail {
                  package = "tempo";
                  message = "deps.endpointService has no out.url.";
                  fix = "Wire an instance whose root is its S3 Service.";
                })
                )
                  { scheme = endpointScheme; }
              );
              insecure = endpointScheme == "http";
            }
          else if os.endpointScheme != null then
            scope.fail {
              package = "tempo";
              option = "objectStorage.endpointScheme";
              message = "objectStorage.endpointScheme is set and no endpointService dependency resolved, so nothing reads it.";
              fix = "Wire the in-cluster store with deps.endpointService = ref.<namespace>.<instance>, or remove objectStorage.endpointScheme and set settings.storage.trace.s3.insecure for a store outside the cluster.";
            }
          else
            { inherit (os) bucket; };

        remoteWriteUrl =
          if !config.metricsGenerator.enabled then
            null
          else if prometheusServer == null then
            scope.fail {
              package = "tempo";
              option = "metricsGenerator.enabled";
              message = "metricsGenerator.enabled is true and no prometheusServer dependency resolved.";
              fix = "Wire an instance that takes Prometheus remote write, such as a victoria-metrics-cluster, with deps.prometheusServer = ref.<namespace>.<instance>, or set metricsGenerator.enabled = false.";
            }
          else
            prometheusServer.out.remoteWriteUrl or (scope.fail {
              package = "tempo";
              dependency = "prometheusServer";
              message = "deps.prometheusServer resolved to an instance without out.remoteWriteUrl, so the metrics generator has nowhere to write. The prometheus package does not take remote write.";
              fix = "Wire a victoria-metrics-cluster instance with deps.prometheusServer = ref.<namespace>.<instance>, or set out.remoteWriteUrl in the kix.mkImport that answers prometheusServer.";
            });

        mergedConfig = lib.filterAttrsRecursive (_: v: v != null) (
          kix.mergeGuarded
            {
              inherit scope;
              option = "settings";
              locked = lockedPaths {
                objectStorage = objectStorageOn;
                inherit inClusterStore;
                metricsGenerator = config.metricsGenerator.enabled;
              };
            }
            (builtinConfig {
              inherit (config) retention;
              inherit store remoteWriteUrl;
            })
            settings
        );

        storeWorldPort =
          if !objectStorageOn || inClusterStore then
            null
          else
            let
              s3 = mergedConfig.storage.trace.s3;
              endpoint =
                s3.endpoint or (scope.fail {
                  package = "tempo";
                  option = "settings.storage.trace.s3.endpoint";
                  message = "objectStorage is set with no endpointService dependency and no settings.storage.trace.s3.endpoint, and Tempo's S3 client has no default endpoint.";
                  fix = "Set settings.storage.trace.s3.endpoint to the store's host[:port] (s3.<region>.amazonaws.com for AWS S3), or wire a store in the cluster with deps.endpointService = ref.<namespace>.<instance>.";
                });
              m = if builtins.isString endpoint then matchEndpoint endpoint else null;
              insecure = s3.insecure or false;
              host = lib.toLower (lib.removeSuffix "." (builtins.elemAt m 0));
              domain = lib.toLower clusterConfig.clusterDomain;
            in
            if m == null then
              scope.fail {
                package = "tempo";
                option = "settings.storage.trace.s3.endpoint";
                message = "settings.storage.trace.s3.endpoint ${builtins.toJSON endpoint} is not host[:port].";
                fix = "Tempo's S3 client reads the address without a scheme and takes TLS from storage.trace.s3.insecure; write it as s3.example.com or s3.example.com:9000.";
              }
            else if !builtins.isBool insecure then
              scope.fail {
                package = "tempo";
                option = "settings.storage.trace.s3.insecure";
                message = "settings.storage.trace.s3.insecure is ${builtins.toJSON insecure}, and Tempo reads a boolean.";
                fix = "Set it to true for a store that serves plain HTTP, or remove it.";
              }
            else if
              lib.hasSuffix ".svc" host
              || lib.hasSuffix ".svc.${domain}" host
              || (!lib.hasInfix "." host && !lib.hasPrefix "[" host)
            then
              scope.fail {
                package = "tempo";
                option = "settings.storage.trace.s3.endpoint";
                message = "settings.storage.trace.s3.endpoint \"${endpoint}\" names a Service in the cluster, and the pod gets network policy only to stores outside it.";
                fix = "Wire the store with deps.endpointService = ref.<namespace>.<instance> and remove the endpoint; set objectStorage.endpointScheme = \"https\" if it serves TLS.";
              }
            else if builtins.elemAt m 2 != null then
              lib.toInt (builtins.elemAt m 2)
            else if insecure then
              80
            else
              443;

        args = [
          "-config.file=${configDir}/tempo.yaml"
          "-config.expand-env=true"
        ]
        ++ kix.guardArgs {
          inherit scope;
          owned = ownedFlags;
        } config.extraArgs;

        env = kix.mergeEnv {
          inherit scope;
          owned = lib.optional objectStorageOn {
            vars = {
              AWS_ACCESS_KEY_ID = credentials.out.keyRef credentialKeys.accessKeyId;
              AWS_SECRET_ACCESS_KEY = credentials.out.keyRef credentialKeys.secretAccessKey;
            };
            from = "the storageCredentials dependency";
            fix = "Remove those variables from env; the storageCredentials Secret supplies the keys.";
          };
        } config.env;
      in
      {
        configMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-config";
          data."tempo.yaml" = builtins.toJSON mergedConfig;
        };

        dataMount = kix.mount.pvc storage {
          name = "data";
          mountPath = dataPath;
        };
        configMount = kix.mount.configMap self.configMap {
          name = "config";
          mountPath = configDir;
          readOnly = true;
        };
        tmpMount = kix.mount.emptyDir {
          name = "tmp";
          mountPath = "/tmp";
          sizeLimit = "256Mi";
        };

        serviceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          inherit name;
          extra.automountServiceAccountToken = false;
        };

        statefulSet =
          {
            inherit name;
            labels."app.kubernetes.io/name" = "tempo";
            spec = {
              headlessService = self.headlessService;
              replicas = 1;
              selector.matchLabels = scope.selectorLabels;
              template = {
                metadata.annotations = {
                  "checksum/config" = self.configMap.out.contentHash;
                }
                // lib.optionalAttrs (objectStorageOn && credentials.out ? contentHash) {
                  "checksum/storage-credentials" = credentials.out.contentHash;
                };
                spec = {
                  serviceAccount = self.serviceAccount;
                  automountServiceAccountToken = false;
                  terminationGracePeriodSeconds = 30;
                  securityContext = {
                    runAsNonRoot = true;
                    runAsUser = 10001;
                    runAsGroup = 10001;
                    fsGroup = 10001;
                    fsGroupChangePolicy = "OnRootMismatch";
                    seccompProfile.type = "RuntimeDefault";
                  };
                  containers = [
                    {
                      name = "tempo";
                      image = kix.image.ref config.image;
                      imagePullPolicy = config.image.pullPolicy;
                      inherit args;
                      env = kix.mkEnvVars env;
                      ports = [
                        (kix.port "http" httpPort)
                        (kix.port "otlp-grpc" otlpGrpcPort)
                        (kix.port "otlp-http" otlpHttpPort)
                      ];
                      readinessProbe = {
                        httpGet = {
                          path = "/ready";
                          port = "http";
                        };
                        initialDelaySeconds = 15;
                        periodSeconds = 10;
                      };
                      livenessProbe = {
                        tcpSocket.port = "http";
                        periodSeconds = 20;
                        failureThreshold = 6;
                      };
                      inherit (config) resources;
                      securityContext = {
                        allowPrivilegeEscalation = false;
                        readOnlyRootFilesystem = true;
                        capabilities.drop = [ "ALL" ];
                      };
                    }
                  ];
                };
              };
            };
          }
          |> kix.withMounts [
            self.dataMount
            self.configMount
            self.tmpMount
          ]
          |> scope.mkStatefulSet;

        headlessService =
          self.statefulSet
          |> kix.service.fromWorkload {
            name = "${name}-headless";
            labels."app.kubernetes.io/component" = "headless";
            spec.clusterIP = "None";
          }
          |> scope.mkResource;

        service =
          self.statefulSet
          |> kix.service.fromWorkload {
            inherit name;
            labels."app.kubernetes.io/component" = "query";
            ports = [
              {
                name = "http";
                port = httpPort;
                targetPort = "http";
              }
            ];
          }
          |> scope.mkResource;

        otlpService =
          self.statefulSet
          |> kix.service.fromWorkload {
            name = "${name}-otlp";
            labels."app.kubernetes.io/component" = "otlp";
            ports = [
              {
                name = "otlp-grpc";
                port = otlpGrpcPort;
                targetPort = "otlp-grpc";
                appProtocol = "grpc";
              }
              {
                name = "otlp-http";
                port = otlpHttpPort;
                targetPort = "otlp-http";
              }
            ];
          }
          |> scope.mkResource;

        storeEgress =
          if storeWorldPort == null then
            null
          else
            kix.operandPolicy {
              inherit scope;
              name = "${name}-object-storage";
              spec = scope.networkPolicyEnforcer.netpol.mkEndpointSelector scope.selectorLabels // {
                egress =
                  (scope.networkPolicyEnforcer.netpol.translateIntentRules {
                    intents.store.egress = [
                      {
                        to = "world";
                        ports = [
                          {
                            port = storeWorldPort;
                            protocol = "TCP";
                          }
                        ];
                      }
                    ];
                  }).egressRules;
              };
            };

        root = {
          resource = self.service;
          requires = builtins.filter (part: part != null) [
            self.storeEgress
          ];
          out = kix.contracts.experimental.otlpEndpoint.check who {
            otlpGrpcUrl = self.otlpService.out.url { port = otlpGrpcPort; };
            otlpHttpUrl = self.otlpService.out.url { port = otlpHttpPort; };
            tls = false;
            queryUrl = self.service.out.url { port = httpPort; };
            version = kix.image.version config.image;
          };
        };
      }
    )

    (import ./monitoring.nix { inherit release; })
  ];
}

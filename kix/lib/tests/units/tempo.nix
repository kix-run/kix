# Tests for kix/packages/tempo: its root.out honours the OTLP endpoint
# contract, `retention` reaches the rendered config, and the settings
# locks, owned flags, backslashes in settings, and retentions outside
# Tempo's duration grammar are refused. `objectStorage` renders an S3
# backend with the keys in env and refuses the shapes Tempo or the network
# policy cannot serve; `metricsGenerator` remote-writes to the
# prometheusServer dependency. Tempo runs in namespace `tracing` on a
# persistent-volume-claim.

{
  lib,
  eval,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  storageClassImport,
  containerBase,
  baseInstances,
  ...
}:

let
  tempoPackage = import ../../../packages/tempo;
  pvcPackage = import ../../../packages/persistent-volume-claim;

  secretPackage = import ../../../packages/secret;
  ciliumPackage = import ../../../packages/cilium;

  tempoCluster = config: tempoClusterWith { inherit config; };

  # `credentials` is the stringData of the storageCredentials Secret (none
  # when null). `inClusterStore` wires the base instances' db Service as
  # endpointService. `remoteWrite` adds a prometheusServer provider in
  # `metrics` whose out.remoteWriteUrl is that value (none when null).
  tempoClusterWith =
    {
      config ? { },
      credentials ? null,
      inClusterStore ? false,
      remoteWrite ? null,
      modules ? [ ],
    }:
    mkCluster (
      [
        baseInstances
        (
          { ref, ... }:
          {
            instances.tracing = {
              storage = {
                package = pvcPackage;
                config = {
                  size = "1Gi";
                  storageClassName = "standard";
                };
              };
              standard-class = storageClassImport "standard";
              tempo = {
                package = tempoPackage;
                inherit config;
              }
              // lib.optionalAttrs inClusterStore { deps.endpointService = ref.dbns.db; };
            }
            // lib.optionalAttrs (credentials != null) {
              s3-credentials = {
                package = secretPackage;
                aliases = [ "storageCredentials" ];
                config.stringData = credentials;
              };
            };
          }
        )
      ]
      ++ lib.optional (remoteWrite != null) {
        instances.metrics.vm.package = remoteWriteProvider remoteWrite;
      }
      ++ modules
    );

  # A Deployment and Service answering prometheusServer, with
  # out.remoteWriteUrl on the Service's address when `path` is a string and
  # no remoteWriteUrl when it is false.
  remoteWriteProvider = path: {
    meta = {
      version = "test";
      defaultAliases = [ "prometheusServer" ];
    };
    build =
      {
        self,
        scope,
        kix,
        ...
      }:
      {
        deployment = scope.mkDeployment {
          name = "vminsert";
          spec = {
            selector.matchLabels = scope.selectorLabels;
            template = {
              metadata.labels = scope.selectorLabels;
              spec.containers = [
                (
                  {
                    name = "vminsert";
                    image = "example/vminsert:1";
                    ports = [ (kix.port "http" 8480) ];
                  }
                  // containerBase
                )
              ];
            };
          };
        };
        service =
          self.deployment
          |> kix.service.fromWorkload {
            name = "vminsert";
            ports = [
              {
                name = "http";
                port = 8480;
                targetPort = "http";
              }
            ];
          }
          |> scope.mkResource;
        root = {
          resource = self.service;
          out = {
            serviceUrl = self.service.out.url { };
          }
          // lib.optionalAttrs (path != false) { remoteWriteUrl = "${self.service.out.url { }}${path}"; };
        };
      };
  };

  # The real Cilium enforcer, whose rules show ports; the test stub's
  # translateIntentRules returns none.
  cilium = [
    {
      cluster.roles.cni = {
        binding = "shadowable";
        provider = "cilium (environment)";
      };
      networkPolicy.enable = true;
      instances.net.cilium.package = ciliumPackage;
      instances.net.platform-cilium.package = eval.mkImport {
        roles = [ "cni" ];
        out.helmChartConfig = null;
      };
    }
  ];

  keys = {
    accessKeyId = "id";
    secretAccessKey = "key";
  };

  tempoConfigOf =
    cluster:
    builtins.fromJSON
      (byName "tempo-config" (ofKind "ConfigMap" (manifests cluster))).data."tempo.yaml";

  statefulSetOf = cluster: byName "tempo" (ofKind "StatefulSet" (manifests cluster));

  plain = builtins.unsafeDiscardStringContext;
in
{
  # The Service URLs reach root.out on the OTLP and query ports.
  tempo-out-honours-otlp-contract =
    let
      out = (tempoCluster { }).instances.tracing.tempo.raw.root.out;
    in
    builtins.match "http://tempo-otlp\\.tracing\\.svc\\..*:4317" (plain out.otlpGrpcUrl) != null
    && builtins.match "http://tempo-otlp\\.tracing\\.svc\\..*:4318" (plain out.otlpHttpUrl) != null
    && builtins.match "http://tempo\\.tracing\\.svc\\..*:3200" (plain out.queryUrl) != null
    && out.tls == false;

  # `retention` renders as the per-tenant default, and an unlocked
  # `settings` key merges beside the package's own.
  tempo-retention-and-settings-render =
    let
      cfg = tempoConfigOf (tempoCluster {
        retention = "72h";
        settings.query_frontend.search.max_duration = "336h";
      });
    in
    cfg.overrides.defaults.compaction.block_retention == "72h"
    && cfg.query_frontend.search.max_duration == "336h"
    && cfg.storage.trace.backend == "local"
    && cfg.live_store.wal.path == "/var/tempo/live-store/traces";

  # `retention` follows Prometheus `model.ParseDuration`, which Tempo uses
  # for `block_retention`: day and week units are accepted; a fraction, a
  # unit it does not know, and units out of order are refused, as is zero,
  # which Tempo reads as its 14-day default.
  tempo-retention-follows-tempo-grammar =
    !evalFails (tempoCluster {
      retention = "7d";
    })
    && !evalFails (tempoCluster {
      retention = "4w2d12h";
    })
    && evalFails (tempoCluster {
      retention = "1.5h";
    })
    && evalFails (tempoCluster {
      retention = "100us";
    })
    && evalFails (tempoCluster {
      retention = "30m1h";
    })
    && evalFails (tempoCluster {
      retention = "0s";
    });

  # Tempo's env expansion reads a backslash as an escape, so a settings
  # string holding one is refused, in an attrset or in a list.
  tempo-refuses-backslash-in-settings =
    !evalFails (tempoCluster {
      settings.server.http_path_prefix = "/a/b";
    })
    && evalFails (tempoCluster {
      settings.server.http_path_prefix = "/a\\d";
    })
    && evalFails (tempoCluster {
      settings.distributor.extra = [ "x\\y" ];
    });

  # Each refusal beside the positive control above: a locked settings path,
  # an ancestor of one, and an owned flag in both spellings.
  tempo-refuses-owned-paths =
    !evalFails (tempoCluster { })
    && evalFails (tempoCluster {
      settings.overrides.defaults.compaction.block_retention = "1h";
    })
    && evalFails (tempoCluster {
      settings.storage.trace = null;
    })
    && evalFails (tempoCluster {
      settings.multitenancy_enabled = true;
    })
    && evalFails (tempoCluster {
      settings.live_store.wal.path = "/tmp/wal";
    })
    && evalFails (tempoCluster {
      settings.backend_scheduler.local_work_path = "/tmp";
    })
    && evalFails (tempoCluster {
      extraArgs = [ "-live-store.shutdown_marker_dir=/tmp" ];
    })
    && evalFails (tempoCluster {
      extraArgs = [ "-target=distributor" ];
    })
    && evalFails (tempoCluster {
      extraArgs = [ "--storage.trace.backend=s3" ];
    })
    && !evalFails (tempoCluster {
      extraArgs = [ "-log.level=debug" ];
    });

  # With an in-cluster store, blocks go to the bucket under the instance's
  # prefix on the store Service's address over http, the keys reach the pod
  # as AWS_* variables from the Secret, and a Secret change rolls the pod.
  tempo-object-storage-in-cluster =
    let
      cluster = tempoClusterWith {
        config.objectStorage.bucket = "traces";
        credentials = keys;
        inClusterStore = true;
      };
      trace = (tempoConfigOf cluster).storage.trace;
      template = (statefulSetOf cluster).spec.template;
      env = (builtins.head template.spec.containers).env;
      envFrom = name: (lib.findFirst (e: e.name == name) null env).valueFrom.secretKeyRef;
    in
    (
      trace.backend == "s3"
      && !(trace ? local)
      && trace.s3.bucket == "traces"
      && trace.s3.prefix == "tracing/tempo"
      && builtins.match "db\\.dbns\\.svc\\..*:5432" trace.s3.endpoint != null
      && trace.s3.insecure == true
      && !(trace.s3 ? access_key)
      &&
        envFrom "AWS_ACCESS_KEY_ID" == {
          name = "s3-credentials";
          key = "accessKeyId";
        }
      &&
        envFrom "AWS_SECRET_ACCESS_KEY" == {
          name = "s3-credentials";
          key = "secretAccessKey";
        }
      && template.metadata.annotations ? "checksum/storage-credentials"
    )
    || throw "tempo in-cluster store: ${builtins.toJSON { inherit trace env; }}";

  # endpointScheme = "https" turns TLS on for the in-cluster store, and
  # credentialKeys renames the Secret keys read.
  tempo-object-storage-https-and-keys =
    let
      cluster = tempoClusterWith {
        config.objectStorage = {
          bucket = "traces";
          endpointScheme = "https";
          credentialKeys.accessKeyId = "id";
        };
        credentials = {
          id = "id";
          secretAccessKey = "key";
        };
        inClusterStore = true;
      };
      s3 = (tempoConfigOf cluster).storage.trace.s3;
      env = (builtins.head (statefulSetOf cluster).spec.template.spec.containers).env;
    in
    (
      s3.insecure == false
      && builtins.match "db\\.dbns\\.svc\\..*:5432" s3.endpoint != null
      && builtins.any (e: e.name == "AWS_ACCESS_KEY_ID" && e.valueFrom.secretKeyRef.key == "id") env
    )
    || throw "tempo https store: ${builtins.toJSON { inherit s3 env; }}";

  # Under Cilium, a store outside the cluster gets the tempo-object-storage
  # policy on the endpoint's port, or 443 (80 with insecure) when it names
  # none. An in-cluster store gets no such policy.
  tempo-object-storage-world-egress-port =
    let
      policyOf =
        args:
        byName "tempo-object-storage" (
          ofKind "CiliumNetworkPolicy" (
            manifests (
              tempoClusterWith (
                {
                  credentials = keys;
                  modules = cilium;
                }
                // args
              )
            )
          )
        );
      egressOf =
        s3:
        (policyOf {
          config = {
            objectStorage.bucket = "traces";
            settings.storage.trace.s3 = s3;
          };
        }).spec.egress;
      explicit = egressOf { endpoint = "s3.example.com:9000"; };
      insecure = egressOf {
        endpoint = "s3.example.com";
        insecure = true;
      };
      aws = egressOf { endpoint = "s3.eu-west-1.amazonaws.com"; };
      inCluster = policyOf {
        config.objectStorage.bucket = "traces";
        inClusterStore = true;
      };
      rule = port: [
        {
          toEntities = [ "world" ];
          toPorts = [
            {
              ports = [
                {
                  inherit port;
                  protocol = "TCP";
                }
              ];
            }
          ];
        }
      ];
    in
    (explicit == rule "9000" && insecure == rule "80" && aws == rule "443" && inCluster == null)
    || throw "tempo store world egress: ${
      builtins.toJSON {
        inherit
          explicit
          insecure
          aws
          inCluster
          ;
      }
    }";

  # Each refusal beside a control that differs by the one setting: no
  # storageCredentials, a Secret without a key read, no endpoint, an
  # endpoint with a scheme, ending in `.svc`, or a single label, `insecure`
  # that is not a boolean (with and without a port), endpointScheme without
  # endpointService, endpointService without objectStorage, the locked
  # bucket and in-cluster endpoint, inline credentials and the SSE-C key in
  # settings or flags (refused also without objectStorage), and an owned AWS
  # variable in env.
  tempo-object-storage-refusals =
    let
      external = settings: {
        objectStorage.bucket = "traces";
        settings.storage.trace.s3 = {
          endpoint = "s3.example.com";
        }
        // settings;
      };
      build = args: tempoClusterWith ({ credentials = keys; } // args);
      cases = {
        control =
          !evalFails (build {
            config = external { };
          });
        control-in-cluster =
          !evalFails (build {
            config.objectStorage.bucket = "traces";
            inClusterStore = true;
          });
        control-aws-env-without-object-storage =
          !evalFails (build {
            config.env.AWS_ACCESS_KEY_ID = "x";
          });
        no-credentials = evalFails (tempoClusterWith {
          config = external { };
        });
        missing-key = evalFails (build {
          config = external { };
          credentials.accessKeyId = "id";
        });
        no-endpoint = evalFails (build {
          config.objectStorage.bucket = "traces";
        });
        endpoint-with-scheme = evalFails (build {
          config = external { endpoint = "https://s3.example.com"; };
        });
        endpoint-in-cluster = evalFails (build {
          config = external { endpoint = "minio.store.svc:9000"; };
        });
        insecure-not-bool = evalFails (build {
          config = external { insecure = "true"; };
        });
        insecure-not-bool-with-port = evalFails (build {
          config = external {
            endpoint = "s3.example.com:9000";
            insecure = "true";
          };
        });
        endpoint-short-name = evalFails (build {
          config = external { endpoint = "minio:9000"; };
        });
        endpoint-service-without-object-storage = evalFails (build {
          inClusterStore = true;
        });
        endpoint-in-cluster-domain = evalFails (build {
          config = external { endpoint = "minio.store.svc.cluster.local"; };
        });
        scheme-without-service = evalFails (build {
          config = external { } // {
            objectStorage = {
              bucket = "traces";
              endpointScheme = "https";
            };
          };
        });
        locked-bucket = evalFails (build {
          config = external { bucket = "other"; };
        });
        locked-in-cluster-endpoint = evalFails (build {
          config = {
            objectStorage.bucket = "traces";
            settings.storage.trace.s3.endpoint = "s3.example.com";
          };
          inClusterStore = true;
        });
        inline-secret = evalFails (build {
          config = external { secret_key = "k"; };
        });
        inline-secret-without-object-storage = evalFails (build {
          config.settings.storage.trace.s3.access_key = "id";
        });
        inline-sse-key = evalFails (build {
          config = external { sse.encryption_key = "k"; };
        });
        sse-key-flag = evalFails (build {
          config.extraArgs = [ "-storage.trace.s3.sse.encryption-key=k" ];
        });
        secret-flag = evalFails (build {
          config = external { } // {
            extraArgs = [ "--storage.trace.s3.secret_key=k" ];
          };
        });
        owned-env = evalFails (build {
          config = external { } // {
            env.AWS_ACCESS_KEY_ID = "x";
          };
        });
      };
      wrong = lib.attrNames (lib.filterAttrs (_: ok: !ok) cases);
    in
    wrong == [ ]
    || throw "tempo object storage refusals: these cases did not behave: ${toString wrong}";

  # With the generator on, Tempo keeps its write-ahead log on the claim,
  # remote-writes to the prometheusServer's out.remoteWriteUrl, and runs
  # both processors; settings may replace the processor list.
  tempo-metrics-generator-renders =
    let
      cfg = tempoConfigOf (tempoClusterWith {
        config.metricsGenerator.enabled = true;
        remoteWrite = "/api/v1/write";
      });
      replaced = tempoConfigOf (tempoClusterWith {
        config = {
          metricsGenerator.enabled = true;
          settings.overrides.defaults.metrics_generator.processors = [ "span-metrics" ];
        };
        remoteWrite = "/api/v1/write";
      });
      off = tempoConfigOf (tempoClusterWith {
        remoteWrite = "/api/v1/write";
      });
    in
    (
      cfg.metrics_generator.storage.path == "/var/tempo/generator/wal"
      &&
        builtins.match "http://vminsert\\.metrics\\.svc\\..*:8480/api/v1/write" (builtins.head cfg.metrics_generator.storage.remote_write)
        .url != null
      &&
        cfg.overrides.defaults.metrics_generator.processors == [
          "service-graphs"
          "span-metrics"
        ]
      && replaced.overrides.defaults.metrics_generator.processors == [ "span-metrics" ]
      && !(off ? metrics_generator)
      && !(off.overrides.defaults ? metrics_generator)
    )
    || throw "tempo metrics generator: ${builtins.toJSON { inherit cfg off; }}";

  # The generator needs a prometheusServer with out.remoteWriteUrl. Its
  # storage paths are refused whether it is on or off, and its processors
  # while it is off.
  tempo-metrics-generator-refusals =
    let
      cases = {
        control =
          !evalFails (tempoClusterWith {
            config.metricsGenerator.enabled = true;
            remoteWrite = "/api/v1/write";
          });
        no-dependency = evalFails (tempoCluster {
          metricsGenerator.enabled = true;
        });
        no-remote-write-url = evalFails (tempoClusterWith {
          config.metricsGenerator.enabled = true;
          remoteWrite = false;
        });
        locked-remote-write = evalFails (tempoClusterWith {
          config = {
            metricsGenerator.enabled = true;
            settings.metrics_generator.storage.remote_write = [ { url = "http://other:9090/api/v1/write"; } ];
          };
          remoteWrite = "/api/v1/write";
        });
        locked-path-while-off = evalFails (tempoCluster {
          settings.metrics_generator.storage.path = "/var/tempo/gen";
        });
        processors-while-off = evalFails (tempoCluster {
          settings.overrides.defaults.metrics_generator.processors = [ "span-metrics" ];
        });
      };
      wrong = lib.attrNames (lib.filterAttrs (_: ok: !ok) cases);
    in
    wrong == [ ]
    || throw "tempo metrics generator refusals: these cases did not behave: ${toString wrong}";

  # Under Cilium, the generator's remote-write URL gives Tempo egress to the
  # prometheusServer's Service port.
  tempo-metrics-generator-egress =
    let
      egress =
        (byName "tempo-statefulset-tempo-egress" (
          ofKind "CiliumNetworkPolicy" (
            manifests (tempoClusterWith {
              config.metricsGenerator.enabled = true;
              remoteWrite = "/api/v1/write";
              modules = cilium;
            })
          )
        )).spec.egress;
      toPort =
        port:
        builtins.any (
          r: builtins.any (tp: builtins.any (p: p.port == port) tp.ports) (r.toPorts or [ ])
        ) egress;
    in
    toPort "8480" || throw "tempo generator egress: ${builtins.toJSON egress}";
}

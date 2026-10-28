# Unit tests for namespace ResourceQuota usage calculation (`vocab/quota-use.nix`),
# `buildCluster` quota assertions, and the `runsAtLeast` declarations on
# operator packages (`quota-use-<package>`).

{
  lib,
  mkCluster,
  evalFails,
  manifests,
  ...
}:

let
  q = import ../../vocab/quota-use.nix { inherit lib; };

  operatorPackage = import ../../../packages/cnpg-operator;
  clusterPackage = import ../../../packages/cnpg-cluster;

  container = resources: {
    name = "c";
    image = "example/c:1";
    inherit resources;
  };

  small = container {
    requests = {
      cpu = "250m";
      memory = "64Mi";
    };
    limits.memory = "128Mi";
  };

  podSpec = {
    containers = [ small ];
  };

  workload = kind: spec: {
    inherit kind;
    apiVersion = "apps/v1";
    metadata.name = "w";
    inherit spec;
  };

  deployment =
    replicas:
    workload "Deployment" {
      inherit replicas;
      template.spec = podSpec;
    };

  refusalsFor =
    hard: resources:
    q.refusals {
      namespace = "app";
      quotas = [
        {
          name = "app-quota";
          inherit hard;
        }
      ];
      inherit resources;
    };

  mi = 1024 * 1024;
  gi = 1024 * mi;

  # Evaluate the `runsAtLeast` declaration on the CRD at `path` in `package`
  # against `manifest`.
  declaredUse =
    {
      package,
      path,
      modules ? [ ],
    }:
    manifest:
    let
      cluster = mkCluster ([ { instances.ops.operator.package = package; } ] ++ modules);
      handle = lib.getAttrFromPath path cluster.instances.ops.operator.raw;
    in
    q.useOf {
      inherit manifest;
      declared = (handle.out.cr { }).runsAtLeast;
    };

  cr = spec: {
    metadata.name = "x";
    inherit spec;
  };

  named = name: resources: [ { inherit name resources; } ];

  appPackage = replicas: {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        deployment = scope.mkDeployment {
          name = "web";
          spec = {
            inherit replicas;
            selector.matchLabels = scope.selectorLabels;
            template = {
              metadata.labels = scope.selectorLabels;
              spec = podSpec;
            };
          };
        };
        root = self.deployment;
      };
  };
in
{
  # Sum regular container resources, defaulting omitted requests to limits
  # and ignoring init containers.
  quota-use-pod-spec =
    let
      use = q.ofPodSpec {
        containers = [
          small
          (container { limits.cpu = "1"; })
        ];
        initContainers = [ (container { requests.memory = "1Gi"; }) ];
      };
    in
    use == {
      pods = 1;
      "requests.cpu" = 1250;
      "limits.cpu" = 1000;
      "requests.memory" = 64 * 1024 * 1024;
      "limits.memory" = 128 * 1024 * 1024;
    }
    || throw "unexpected pod use: ${builtins.toJSON use}";

  quota-use-built-in-kinds =
    let
      useOf = manifest: q.useOf { inherit manifest; };
      job = spec: workload "Job" (spec // { template.spec = podSpec; });
    in
    (
      (useOf (deployment 3)).pods == 3
      && (useOf (deployment 3))."requests.cpu" == 750
      && (useOf (deployment null)).pods == 1
      &&
        (q.useOf {
          manifest = deployment 3;
          minReplicas = 2;
        }).pods == 2
      && (useOf (job { })).pods == 1
      &&
        (useOf (job {
          parallelism = 4;
        })).pods == 4
      &&
        (useOf (job {
          parallelism = 4;
          completions = 2;
        })).pods == 2
      &&
        (useOf (job {
          parallelism = 4;
          suspend = true;
        })).pods == 0
      && useOf (workload "CronJob" { jobTemplate.spec.template.spec = podSpec; }) == null
      && useOf (workload "DaemonSet" { template.spec = podSpec; }) == null
    )
    || throw "a built-in kind was counted wrongly";

  # Map `cpu` and `memory` shorthand keys to `requests.*`, and ignore storage
  # and object-count keys.
  quota-use-compare-keys =
    let
      use = {
        pods = 2;
        "requests.cpu" = 500;
        "requests.memory" = 1024;
      };
    in
    (
      q.compare use "cpu" "1" == {
        used = 500;
        limit = 1000;
      }
      &&
        q.compare use "memory" "1Ki" == {
          used = 1024;
          limit = 1024;
        }
      &&
        q.compare use "limits.cpu" "2" == {
          used = 0;
          limit = 2000;
        }
      && q.compare use "requests.storage" "10Gi" == null
      && q.compare use "count/deployments.apps" "3" == null
      && q.format "requests.cpu" 1500 == "1500m"
      && q.format "requests.cpu" 2000 == "2"
      && q.format "requests.memory" (3 * 1024 * 1024 * 1024) == "3Gi"
      && q.format "requests.memory" (1536 * 1024 * 1024) == "1536Mi"
    )
    || throw "quota keys were compared or formatted wrongly";

  quota-use-refuses-over-quota =
    let
      over = refusalsFor {
        pods = "2";
        "requests.memory" = "100Mi";
        "count/deployments.apps" = "5";
      } [ (deployment 3) ];
      message = builtins.head over;
    in
    (
      builtins.length over == 1
      && lib.hasInfix "namespace app" message
      && lib.hasInfix "pods: at least 3, quota 2" message
      && lib.hasInfix "requests.memory: at least 192Mi, quota 100Mi" message
      && lib.hasInfix "ResourceQuota app-quota" message
      && lib.hasInfix "Counted: Deployment/w." message
      && !(lib.hasInfix "count/" message)
      &&
        refusalsFor {
          pods = "3";
          cpu = "1";
        } [ (deployment 3) ] == [ ]
    )
    || throw "unexpected refusals: ${builtins.toJSON over}";

  # When a HorizontalPodAutoscaler targets a workload, use its `minReplicas`
  # (default 1) instead of the workload's static `replicas`.
  quota-use-reads-hpa-minimum =
    let
      hpa = spec: {
        apiVersion = "autoscaling/v2";
        kind = "HorizontalPodAutoscaler";
        metadata.name = "w";
        spec = {
          scaleTargetRef = {
            kind = "Deployment";
            name = "w";
          };
          maxReplicas = 10;
        }
        // spec;
      };
    in
    (
      refusalsFor { pods = "2"; } [
        (deployment 5)
        (hpa { })
      ] == [ ]
      &&
        refusalsFor { pods = "2"; } [
          (deployment 1)
          (hpa { minReplicas = 3; })
        ] != [ ]
    )
    || throw "the HPA's minReplicas was not counted";

  # List uncounted resources in the refusal message without failing the check
  # on their own.
  quota-use-names-what-it-cannot-count =
    let
      daemonSet = workload "DaemonSet" { template.spec = podSpec; };
      widget = {
        apiVersion = "example.com/v1";
        kind = "Widget";
        metadata.name = "w1";
      };
      refused = q.refusals {
        namespace = "app";
        quotas = [
          {
            name = "app-quota";
            hard.pods = "1";
          }
        ];
        resources = [
          (deployment 2)
          daemonSet
        ];
        customResources = [
          {
            manifest = widget;
            runsAtLeast = null;
          }
        ];
      };
    in
    (
      lib.hasInfix "Not counted: DaemonSet/w, Widget/w1." (builtins.head refused)
      && refusalsFor { pods = "0"; } [ daemonSet ] == [ ]
    )
    || throw "uncounted objects were not named, or caused a refusal: ${builtins.toJSON refused}";

  # Check both `namespaces.<ns>.resourceQuota` and unscoped ResourceQuotas
  # rendered by instances, while skipping scoped quotas.
  quota-use-cluster-refuses =
    let
      withQuota =
        modules:
        mkCluster (
          [
            { instances.app.web.package = appPackage 3; }
          ]
          ++ modules
        );
      rendered = spec: {
        meta.version = "test";
        build =
          { self, scope, ... }:
          {
            quota = scope.mkResource {
              apiVersion = "v1";
              kind = "ResourceQuota";
              name = "own";
              inherit spec;
            };
            root = self.quota;
          };
      };
      builds = cluster: builtins.deepSeq (manifests cluster) true;
    in
    (
      evalFails (withQuota [ { namespaces.app.resourceQuota.pods = "2"; } ])
      && builds (withQuota [ { namespaces.app.resourceQuota.pods = "3"; } ])
      && evalFails (withQuota [ { instances.app.quota.package = rendered { hard.pods = "2"; }; } ])
      && builds (withQuota [
        {
          instances.app.quota.package = rendered {
            hard.pods = "2";
            scopes = [ "BestEffort" ];
          };
        }
      ])
    )
    || throw "a build over its namespace's quota was not refused, or one within it was";

  # Count custom resources via the CRD's `runsAtLeast` declaration
  # (`cnpg-operator` Cluster: `spec.instances` * `spec.resources`).
  quota-use-package-declares-custom-kind =
    let
      cnpg =
        quota:
        mkCluster [
          {
            namespaces.data.resourceQuota."requests.memory" = quota;
            instances.cnpg-system.cnpg-operator.package = operatorPackage;
            instances.data.postgres = {
              package = clusterPackage;
              config = {
                instances = 3;
                resources.requests.memory = "2Gi";
              };
            };
          }
        ];
    in
    (evalFails (cnpg "4Gi") && builtins.deepSeq (manifests (cnpg "6Gi")) true)
    || throw "the Cluster's runsAtLeast was not counted";
  # Verify `runsAtLeast` for `ClickHouseInstallation` and
  # `ClickHouseKeeperInstallation`: shards * replicas per cluster, sized by the
  # `clickhouse` / `clickhouse-keeper` container in the cluster's pod template,
  # or pods-only when shards override the template.
  quota-use-clickhouse-operator =
    let
      use =
        part:
        declaredUse {
          package = import ../../../packages/clickhouse-operator;
          path = [
            "crds"
            part
          ];
          modules = [
            {
              instances.ops.credentials = {
                package = import ../../../packages/secret;
                config.stringData = {
                  username = "operator";
                  password = "test";
                };
              };
            }
          ];
        };
      chi = use "clickHouseInstallations";
      chk = use "clickHouseKeeperInstallations";
      templates.podTemplates = [
        {
          name = "server";
          spec.containers = named "clickhouse" { limits.memory = "1Gi"; };
        }
      ];
      installation = chi (cr {
        defaults.templates.podTemplate = "server";
        inherit templates;
        configuration.clusters = [
          {
            name = "a";
            layout = {
              shardsCount = 2;
              replicasCount = 3;
            };
          }
          {
            name = "b";
            layout.shards = [
              { }
              { templates.podTemplate = "other"; }
            ];
          }
        ];
      });
      keeper = chk (cr {
        defaults.templates.podTemplate = "keeper";
        templates.podTemplates = [
          {
            name = "keeper";
            spec.containers = named "clickhouse-keeper" { requests.cpu = "250m"; };
          }
        ];
        configuration.clusters = [
          {
            name = "k";
            layout.replicasCount = 3;
          }
        ];
      });
    in
    (
      installation == {
        pods = 8;
        "requests.memory" = 6 * gi;
        "limits.memory" = 6 * gi;
      }
      &&
        keeper == {
          pods = 3;
          "requests.cpu" = 750;
        }
      && chi (cr { }) == { pods = 1; }
      &&
        chi (cr {
          stop = "yes";
        }) == { }
      && chk (cr { }) == { pods = 1; }
    )
    || throw "unexpected ClickHouse use: ${builtins.toJSON { inherit installation keeper; }}";

  # Verify `runsAtLeast` for `SGCluster` (`spec.instances`, lowered by
  # horizontal autoscaling `minInstances` or backup initialization) and
  # `SGDistributedLogs` (1 pod).
  quota-use-stackgres-operator =
    let
      use =
        part:
        declaredUse {
          package = import ../../../packages/stackgres-operator;
          path = [
            "crds"
            part
          ];
        };
      sg = use "sgClusters";
    in
    (
      sg (cr {
        instances = 3;
      }) == {
        pods = 3;
      }
      &&
        sg (cr {
          instances = 3;
          autoscaling.minInstances = 2;
        }) == {
          pods = 2;
        }
      &&
        sg (cr {
          instances = 3;
          autoscaling = {
            mode = "vertical";
            minInstances = 1;
          };
        }) == {
          pods = 3;
        }
      &&
        sg (cr {
          instances = 3;
          replication.initialization.mode = "FromNewlyCreatedBackup";
        }) == {
          pods = 1;
        }
      && use "sgDistributedLogs" (cr { }) == { pods = 1; }
    )
    || throw "unexpected SGCluster use";

  # Verify `runsAtLeast` for `Prometheus`, `PrometheusAgent`, `Alertmanager`,
  # and `ThanosRuler`, including the 200Mi default memory request on
  # Alertmanager and ThanosRuler and DaemonSet-mode skipping on PrometheusAgent.
  quota-use-prometheus-operator =
    let
      use =
        part:
        declaredUse {
          package = import ../../../packages/prometheus-operator;
          path = [
            "crds"
            part
          ];
        };
      prometheus = use "prometheuses";
      sharded = prometheus (cr {
        replicas = 2;
        shards = 2;
        resources.requests.memory = "1Gi";
        containers = named "prometheus" { limits.cpu = "1"; };
      });
    in
    (
      sharded == {
        pods = 4;
        "requests.memory" = 4 * gi;
        "requests.cpu" = 4000;
        "limits.cpu" = 4000;
      }
      && prometheus (cr { }) == { pods = 1; }
      &&
        prometheus (cr {
          paused = true;
        }) == { }
      &&
        use "alertmanagers" (cr { }) == {
          pods = 1;
          "requests.memory" = 200 * mi;
        }
      &&
        use "thanosRulers" (cr {
          replicas = 2;
          resources.requests.memory = "1Gi";
        }) == {
          pods = 2;
          "requests.memory" = 2 * gi;
        }
      &&
        use "prometheusAgents" (cr {
          mode = "DaemonSet";
        }) == { }
    )
    || throw "unexpected Prometheus use: ${builtins.toJSON sharded}";

  # Verify `runsAtLeast` for `VMCluster`, `VMAgent`, and single-component
  # VictoriaMetrics CRDs, including HPA `minReplicas`, VPA pods-only fallback,
  # and `daemonSetMode` skipping.
  quota-use-victoria-metrics-operator =
    let
      use =
        part:
        declaredUse {
          package = import ../../../packages/victoria-metrics-operator;
          path = [
            "crds"
            part
          ];
        };
      cluster = use "vmClusters" (cr {
        vmstorage = {
          replicaCount = 2;
          resources.requests.memory = "1Gi";
        };
        vmselect = {
          replicaCount = 5;
          hpa = {
            minReplicas = 2;
            maxReplicas = 5;
          };
          resources.requests.cpu = "500m";
        };
        vminsert = {
          vpa.updatePolicy.updateMode = "Auto";
          resources.requests.cpu = "1";
        };
      });
      agent = use "vmAgents";
    in
    (
      cluster == {
        pods = 5;
        "requests.memory" = 2 * gi;
        "requests.cpu" = 1000;
      }
      &&
        agent (cr {
          replicaCount = 2;
          shardCount = 3;
        }) == {
          pods = 6;
        }
      && agent (cr { }) == { pods = 1; }
      &&
        agent (cr {
          daemonSetMode = true;
        }) == { }
      && use "vmClusters" (cr { }) == { }
      &&
        use "vmAlertmanagers" (cr {
          replicaCount = 3;
        }) == {
          pods = 3;
        }
    )
    || throw "unexpected VictoriaMetrics use: ${builtins.toJSON cluster}";

  # Verify `runsAtLeast` for `AutoscalingRunnerSet` (`minRunners` capped by
  # `maxRunners`, sized by the `runner` container).
  quota-use-arc =
    let
      use = declaredUse {
        package = import ../../../packages/arc;
        path = [
          "crds"
          "autoscalingRunnerSets"
        ];
      };
      runners = use (cr {
        minRunners = 3;
        maxRunners = 2;
        template.spec.containers = named "runner" { requests.cpu = "1"; };
      });
    in
    (
      runners == {
        pods = 2;
        "requests.cpu" = 2000;
      }
      && use (cr { }) == { pods = 0; }
    )
    || throw "unexpected runner set use: ${builtins.toJSON runners}";

  # Verify `runsAtLeast` for `RabbitmqCluster`, including StatefulSet overrides,
  # CRD schema default resources, and `rabbitmq.com/pauseReconciliation`.
  quota-use-rabbitmq-operator =
    let
      use = declaredUse {
        package = import ../../../packages/rabbitmq-operator;
        path = [
          "crds"
          "rabbitmqClusters"
        ];
        modules = [
          { instances.cert-manager.cert-manager.package = import ../../../packages/cert-manager; }
        ];
      };
    in
    (
      use (cr {
        replicas = 3;
        resources.requests.memory = "1Gi";
        override.statefulSet.spec = {
          replicas = 2;
          template.spec.containers = named "rabbitmq" { requests.cpu = "500m"; };
        };
      }) == {
        pods = 2;
        "requests.memory" = 2 * gi;
        "requests.cpu" = 1000;
      }
      &&
        use (cr { }) == {
          pods = 1;
          "requests.cpu" = 1000;
          "requests.memory" = 2 * gi;
          "limits.cpu" = 2000;
          "limits.memory" = 2 * gi;
        }
      &&
        use {
          metadata.labels."rabbitmq.com/pauseReconciliation" = "true";
          spec = { };
        } == { }
    )
    || throw "unexpected RabbitmqCluster use";

  # Verify `runsAtLeast` for KubeVirt `VirtualMachine` across `runStrategy` and
  # `running` states.
  quota-use-kubevirt =
    let
      use = declaredUse {
        package = import ../../../packages/kubevirt;
        path = [
          "crds"
          "virtualMachines"
        ];
      };
    in
    (
      use (cr {
        runStrategy = "Always";
      }) == {
        pods = 1;
      }
      &&
        use (cr {
          running = true;
        }) == {
          pods = 1;
        }
      &&
        use (cr {
          runStrategy = "Halted";
        }) == {
          pods = 0;
        }
      && use (cr { }) == { pods = 0; }
    )
    || throw "unexpected VirtualMachine use";

  # Verify `runsAtLeast` for CloudNativePG `Pooler` (`spec.instances`, sized by
  # the `pgbouncer` container in `spec.template`).
  quota-use-cnpg-operator-pooler =
    let
      use = declaredUse {
        package = operatorPackage;
        path = [
          "crds"
          "poolers"
        ];
      };
    in
    (
      use (cr {
        instances = 2;
        template.spec.containers = named "pgbouncer" { requests.cpu = "100m"; };
      }) == {
        pods = 2;
        "requests.cpu" = 200;
      }
      && use (cr { }) == { pods = 1; }
    )
    || throw "unexpected Pooler use";
}

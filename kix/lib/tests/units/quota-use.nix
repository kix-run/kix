# Unit tests for namespace ResourceQuota usage calculation (`vocab/quota-use.nix`),
# the `kix.usage` helpers, `buildCluster` quota assertions, and the
# `usesAtLeast` declarations on operator packages (`quota-use-<package>`).

{
  lib,
  mkCluster,
  evalFails,
  manifests,
  ...
}:

let
  q = import ../../vocab/quota-use.nix { inherit lib; };

  operatorPackage = import ../../../packages/stable/cnpg-operator;
  clusterPackage = import ../../../packages/stable/cnpg-cluster;

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

  # Evaluate the `usesAtLeast` declaration on the CRD at `path` in `package`
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
      declared = (handle.out.cr { }).usesAtLeast;
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

  # Map `cpu` and `memory` shorthand keys to `requests.*`, and compare every
  # other key as it is, counting a key nothing reports as 0.
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
      &&
        q.compare use "requests.storage" "10Gi" == {
          used = 0;
          limit = 10 * gi;
        }
      &&
        q.compare use "count/deployments.apps" "3" == {
          used = 0;
          limit = 3;
        }
      && q.format "services" 2048 == "2048"
      && q.format "count/deployments.apps" 1024 == "1024"
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
      message = builtins.concatStringsSep "\n---\n" over;
    in
    (
      builtins.length over == 2
      && lib.hasInfix "namespace \"app\" exceeds ResourceQuota \"app-quota\" for pods (uses at least 3, limit is 2)" message
      && lib.hasInfix "for requests.memory (uses at least 192Mi, limit is 100Mi)" message
      && lib.hasInfix "  Counted (3 pods):\n    Deployment/w: 3 pods" message
      && lib.hasInfix "  Counted (192Mi requests.memory):\n    Deployment/w: 192Mi requests.memory" message
      && !(lib.hasInfix "count/" message)
      && !(lib.hasInfix "Not counted" message)
      &&
        refusalsFor {
          pods = "3";
          cpu = "1";
        } [ (deployment 3) ] == [ ]
    )
    || throw "unexpected refusals: ${builtins.toJSON over}";

  # `kix.usage` builds a pod's usage from its containers, multiplies it, and
  # adds usages whose values are quantity strings.
  quota-use-helpers =
    let
      inherit (q.helpers) ofPod times add;
      pod = ofPod [
        small
        (container { limits.cpu = "1"; })
      ];
      total = add [
        (times 2 pod)
        {
          services = 1;
          "requests.storage" = "10Gi";
          "limits.cpu" = null;
        }
      ];
    in
    (
      ofPod podSpec == q.ofPodSpec podSpec
      && pod."requests.cpu" == 1250
      &&
        total == {
          pods = 2;
          services = 1;
          "requests.cpu" = 2500;
          "limits.cpu" = 2000;
          "requests.memory" = 128 * mi;
          "limits.memory" = 256 * mi;
          "requests.storage" = 10 * gi;
        }
      && !(builtins.tryEval (builtins.deepSeq (add [ { "requests.storage" = "lots"; } ]) true)).success
    )
    || throw "unexpected usage: ${builtins.toJSON total}";

  # A custom resource's declared usage counts against storage and object
  # quotas, which built-in workloads never report.
  quota-use-refuses-declared-storage-and-services =
    let
      database = {
        apiVersion = "example.com/v1";
        kind = "Database";
        metadata.name = "db";
        spec.instances = 3;
      };
      declared = m: {
        pods = m.spec.instances;
        persistentvolumeclaims = m.spec.instances;
        "requests.storage" = "${toString (m.spec.instances * 10)}Gi";
        services = 2;
      };
      refused =
        hard:
        q.refusals {
          namespace = "app";
          quotas = [
            {
              name = "app-quota";
              inherit hard;
            }
          ];
          resources = [ (deployment 1) ];
          customResources = [
            {
              manifest = database;
              usesAtLeast = declared;
            }
          ];
        };
      storage = refused {
        "requests.storage" = "20Gi";
        persistentvolumeclaims = "5";
      };
      services = refused { services = "1"; };
    in
    (
      builtins.length storage == 1
      && lib.hasInfix "for requests.storage (uses at least 30Gi, limit is 20Gi)" (builtins.head storage)
      && !(lib.hasInfix "persistentvolumeclaims" (builtins.head storage))
      && lib.hasInfix "  Counted (30Gi requests.storage):\n    Database/db: 30Gi requests.storage\n" (
        builtins.head storage
      )
      && !(lib.hasInfix "Deployment/w" (builtins.head storage))
      && lib.hasInfix "for services (uses at least 2, limit is 1)" (builtins.head services)
      &&
        refused {
          "requests.storage" = "30Gi";
          services = "2";
          pods = "4";
        } == [ ]
    )
    || throw "unexpected refusals: ${builtins.toJSON { inherit storage services; }}";

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
  # on their own: built-in kinds by name, custom kinds grouped with counts,
  # largest group first. A kind whose `usesAtLeast` returns `{ }` runs
  # nothing and appears nowhere.
  quota-use-names-what-it-cannot-count =
    let
      daemonSet = workload "DaemonSet" { template.spec = podSpec; };
      custom = kind: name: usesAtLeast: {
        manifest = {
          apiVersion = "example.com/v1";
          inherit kind;
          metadata.name = name;
        };
        inherit usesAtLeast;
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
          (custom "Widget" "w1" null)
          (custom "PrometheusRule" "r1" null)
          (custom "PrometheusRule" "r2" null)
          (custom "Gadget" "g1" (_: { }))
        ];
      };
      expected = ''
        namespace "app" exceeds ResourceQuota "app-quota" for pods (uses at least 2, limit is 1)
          Kubernetes will reject pods over this limit at deploy time.

          Counted (2 pods):
            Deployment/w: 2 pods

          Not counted (actual usage may be higher):
            DaemonSet/w: 1 pod per matching node (Kix does not know how many nodes the cluster has)
            2 PrometheusRule, 1 Widget: pod usage is not declared by their packages (most custom resources create no pods, but Kix cannot verify this)

          To fix this, raise the pods limit in "app-quota" or run fewer pods in namespace "app".'';
    in
    (refused == [ expected ] && refusalsFor { pods = "0"; } [ daemonSet ] == [ ])
    || throw "uncounted objects were not named as expected, or caused a refusal: ${builtins.toJSON refused}";

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

  # A plain custom resource (no CRD declaration) in a namespace over its
  # quota reaches the check without breaking it and adds nothing to the
  # total, and a kind in a `*.k8s.io` group is counted when it declares
  # `usesAtLeast`. A failed cluster assertion throws, so the message text
  # is checked in `quota-use-names-what-it-cannot-count` instead.
  quota-use-cluster-passes-custom-resources =
    let
      withWidget = {
        meta.version = "test";
        build =
          { self, scope, ... }:
          {
            deployment = scope.mkDeployment {
              name = "web";
              spec = {
                replicas = 3;
                selector.matchLabels = scope.selectorLabels;
                template = {
                  metadata.labels = scope.selectorLabels;
                  spec = podSpec;
                };
              };
            };
            crd = scope.mkCRDRef {
              group = "example.com";
              kind = "Widget";
              plural = "widgets";
              version = "v1";
            };
            widget = scope.mkCR self.crd {
              name = "w1";
              spec = { };
            };
            root = {
              resource = self.deployment;
              requires = [ self.widget ];
            };
          };
      };
      withSnapshot = {
        meta.version = "test";
        build =
          { self, scope, ... }:
          {
            crd = scope.mkCRDRef {
              group = "snapshot.storage.k8s.io";
              kind = "VolumeSnapshot";
              plural = "volumesnapshots";
              version = "v1";
              usesAtLeast = _: { pods = 5; };
            };
            snapshot = scope.mkCR self.crd {
              name = "s1";
              spec = { };
            };
            root = self.snapshot;
          };
      };
      cluster =
        package: pods:
        mkCluster [
          {
            instances.app.web.package = package;
            namespaces.app.resourceQuota.pods = pods;
          }
        ];
      builds = cluster: builtins.deepSeq (manifests cluster) true;
    in
    (
      builds (cluster withWidget "3")
      && evalFails (cluster withWidget "2")
      && evalFails (cluster withSnapshot "4")
      && builds (cluster withSnapshot "5")
    )
    || throw "a plain custom resource changed the quota outcome, or a *.k8s.io kind with usesAtLeast was not counted";

  # Count custom resources via the CRD's `usesAtLeast` declaration
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
    || throw "the Cluster's usesAtLeast was not counted";
  # Verify `usesAtLeast` for `ClickHouseInstallation` and
  # `ClickHouseKeeperInstallation`: shards * replicas hosts per cluster, each
  # a pod with every container in the cluster's pod template, a Service, and
  # a claim per named volume claim template; pods and Services only when
  # shards override the templates.
  quota-use-clickhouse-operator =
    let
      use =
        part:
        declaredUse {
          package = import ../../../packages/stable/clickhouse-operator;
          path = [
            "crds"
            part
          ];
          modules = [
            {
              instances.ops.credentials = {
                package = import ../../../packages/stable/secret;
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
      templates = {
        podTemplates = [
          {
            name = "server";
            spec.containers =
              named "clickhouse" { limits.memory = "1Gi"; } ++ named "sidecar" { requests.cpu = "100m"; };
          }
        ];
        volumeClaimTemplates = [
          {
            name = "data";
            spec.resources.requests.storage = "10Gi";
          }
        ];
      };
      installation = chi (cr {
        defaults.templates = {
          podTemplate = "server";
          dataVolumeClaimTemplate = "data";
          logVolumeClaimTemplate = "data";
        };
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
        services = 8;
        "requests.memory" = 6 * gi;
        "limits.memory" = 6 * gi;
        "requests.cpu" = 600;
        persistentvolumeclaims = 6;
        "requests.storage" = 60 * gi;
      }
      &&
        keeper == {
          pods = 3;
          services = 3;
          "requests.cpu" = 750;
        }
      &&
        chi (cr { }) == {
          pods = 1;
          services = 1;
        }
      &&
        chi (cr {
          stop = "yes";
        }) == { }
      &&
        chk (cr { }) == {
          pods = 1;
          services = 1;
        }
    )
    || throw "unexpected ClickHouse use: ${builtins.toJSON { inherit installation keeper; }}";

  # Verify `usesAtLeast` for `SGCluster` (`spec.instances`, lowered by
  # horizontal autoscaling `minInstances` or backup initialization), with one
  # claim per pod, and `SGDistributedLogs` (1 pod and its claim).
  quota-use-stackgres-operator =
    let
      use =
        part:
        declaredUse {
          package = import ../../../packages/stable/stackgres-operator;
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
        pods.persistentVolume.size = "10Gi";
      }) == {
        pods = 3;
        persistentvolumeclaims = 3;
        "requests.storage" = 30 * gi;
      }
      &&
        sg (cr {
          instances = 3;
          autoscaling.minInstances = 2;
        }) == {
          pods = 2;
          persistentvolumeclaims = 2;
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
          persistentvolumeclaims = 3;
        }
      &&
        sg (cr {
          instances = 3;
          replication.initialization.mode = "FromNewlyCreatedBackup";
        }) == {
          pods = 1;
          persistentvolumeclaims = 1;
        }
      &&
        use "sgDistributedLogs" (cr {
          persistentVolume.size = "5Gi";
        }) == {
          pods = 1;
          persistentvolumeclaims = 1;
          "requests.storage" = 5 * gi;
        }
    )
    || throw "unexpected SGCluster use";

  # Verify `usesAtLeast` for `Prometheus`, `PrometheusAgent`, `Alertmanager`,
  # and `ThanosRuler`, including the Thanos sidecar, extra containers, claims,
  # the 200Mi default memory request on Alertmanager and ThanosRuler, and
  # DaemonSet-mode skipping on PrometheusAgent.
  quota-use-prometheus-operator =
    let
      use =
        part:
        declaredUse {
          package = import ../../../packages/stable/prometheus-operator;
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
        thanos.resources.requests.cpu = "100m";
        storage.volumeClaimTemplate.spec.resources.requests.storage = "20Gi";
        containers =
          named "prometheus" { limits.cpu = "1"; }
          ++ named "config-reloader" { requests.cpu = "1"; }
          ++ named "proxy" { requests.memory = "64Mi"; };
      });
    in
    (
      sharded == {
        pods = 4;
        "requests.memory" = 4 * gi + 256 * mi;
        "requests.cpu" = 4400;
        "limits.cpu" = 4000;
        persistentvolumeclaims = 4;
        "requests.storage" = 80 * gi;
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

  # Verify `usesAtLeast` for `VMCluster`, `VMAgent`, and single-component
  # VictoriaMetrics CRDs, including HPA `minReplicas`, VPA pods-only fallback,
  # extra containers, claims, one Service per app, and `daemonSetMode`
  # skipping.
  quota-use-victoria-metrics-operator =
    let
      use =
        part:
        declaredUse {
          package = import ../../../packages/stable/victoria-metrics-operator;
          path = [
            "crds"
            part
          ];
        };
      cluster = use "vmClusters" (cr {
        vmstorage = {
          replicaCount = 2;
          resources.requests.memory = "1Gi";
          containers = named "sidecar" { requests.cpu = "100m"; };
          storage.volumeClaimTemplate.spec.resources.requests.storage = "10Gi";
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
        services = 3;
        "requests.memory" = 2 * gi;
        "requests.cpu" = 1200;
        persistentvolumeclaims = 2;
        "requests.storage" = 20 * gi;
      }
      &&
        agent (cr {
          replicaCount = 2;
          shardCount = 3;
        }) == {
          pods = 6;
          services = 1;
        }
      &&
        agent (cr { }) == {
          pods = 1;
          services = 1;
        }
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
          services = 1;
        }
      &&
        use "vmSingles" (cr {
          storage.resources.requests.storage = "5Gi";
        }) == {
          pods = 1;
          services = 1;
          persistentvolumeclaims = 1;
          "requests.storage" = 5 * gi;
        }
    )
    || throw "unexpected VictoriaMetrics use: ${builtins.toJSON cluster}";

  # Verify `usesAtLeast` for `AutoscalingRunnerSet` (`minRunners` capped by
  # `maxRunners`, each with every container in the template).
  quota-use-arc =
    let
      use = declaredUse {
        package = import ../../../packages/stable/arc;
        path = [
          "crds"
          "autoscalingRunnerSets"
        ];
      };
      runners = use (cr {
        minRunners = 3;
        maxRunners = 2;
        template.spec.containers =
          named "runner" { requests.cpu = "1"; } ++ named "dind" { requests.memory = "512Mi"; };
      });
    in
    (
      runners == {
        pods = 2;
        "requests.cpu" = 2000;
        "requests.memory" = gi;
      }
      && use (cr { }) == { pods = 0; }
    )
    || throw "unexpected runner set use: ${builtins.toJSON runners}";

  # Verify `usesAtLeast` for `RabbitmqCluster`, including StatefulSet overrides,
  # CRD schema default resources and storage, the two Services, and
  # `rabbitmq.com/pauseReconciliation`.
  quota-use-rabbitmq-operator =
    let
      use = declaredUse {
        package = import ../../../packages/stable/rabbitmq-operator;
        path = [
          "crds"
          "rabbitmqClusters"
        ];
        modules = [
          { instances.cert-manager.cert-manager.package = import ../../../packages/stable/cert-manager; }
        ];
      };
    in
    (
      use (cr {
        replicas = 3;
        resources.requests.memory = "1Gi";
        override.statefulSet.spec = {
          replicas = 2;
          template.spec.containers =
            named "rabbitmq" { requests.cpu = "500m"; } ++ named "proxy" { requests.cpu = "100m"; };
        };
      }) == {
        pods = 2;
        services = 2;
        "requests.memory" = 2 * gi;
        "requests.cpu" = 1200;
        persistentvolumeclaims = 2;
        "requests.storage" = 20 * gi;
      }
      &&
        use (cr { }) == {
          pods = 1;
          services = 2;
          "requests.cpu" = 1000;
          "requests.memory" = 2 * gi;
          "limits.cpu" = 2000;
          "limits.memory" = 2 * gi;
          persistentvolumeclaims = 1;
          "requests.storage" = 10 * gi;
        }
      &&
        (use (cr {
          persistence.storage = "0";
        })) ? persistentvolumeclaims == false
      &&
        (use (cr {
          override.statefulSet.spec.volumeClaimTemplates = [ ];
        })) ? persistentvolumeclaims == false
      &&
        use {
          metadata.labels."rabbitmq.com/pauseReconciliation" = "true";
          spec = { };
        } == { }
    )
    || throw "unexpected RabbitmqCluster use";

  # Verify `usesAtLeast` for KubeVirt `VirtualMachine` across `runStrategy` and
  # `running` states.
  quota-use-kubevirt =
    let
      use = declaredUse {
        package = import ../../../packages/stable/kubevirt;
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

  # Verify `usesAtLeast` for CloudNativePG `Pooler` (`spec.instances`, each
  # with every container in `spec.template`, and its Service) and `Cluster`
  # (instances, claims, and the managed Services).
  quota-use-cnpg-operator =
    let
      use = declaredUse {
        package = operatorPackage;
        path = [
          "crds"
          "poolers"
        ];
      };
      cluster = declaredUse {
        package = operatorPackage;
        path = [
          "crds"
          "clusters"
        ];
      };
    in
    (
      use (cr {
        instances = 2;
        template.spec.containers =
          named "pgbouncer" { requests.cpu = "100m"; } ++ named "exporter" { requests.cpu = "50m"; };
      }) == {
        pods = 2;
        services = 1;
        "requests.cpu" = 300;
      }
      &&
        use (cr { }) == {
          pods = 1;
          services = 1;
        }
      &&
        cluster (cr {
          instances = 3;
          resources.requests.memory = "2Gi";
          storage.size = "10Gi";
          walStorage.pvcTemplate.resources.requests.storage = "5Gi";
          managed.services.disabledDefaultServices = [
            "ro"
            "r"
          ];
        }) == {
          pods = 3;
          services = 1;
          "requests.memory" = 6 * gi;
          persistentvolumeclaims = 6;
          "requests.storage" = 45 * gi;
        }
      &&
        cluster (cr { }) == {
          pods = 1;
          services = 3;
        }
    )
    || throw "unexpected CloudNativePG use";
}

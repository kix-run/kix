# CoreDNS package — fixpoint pattern.
#
# Migrated from pkgs/coredns/ (module-system version).
# Source Helm chart: coredns/coredns (v1.45.0, appVersion 1.13.1)
#
# This package defines CoreDNS as a self-referential set of K8s resources
# using the inner fixpoint (lib.fix). Resources reference each other via
# `self.*` and the tree walker tracks dependencies automatically.
#
# The `main` resource is the DNS Service — consumers connect to kube-dns:53.
# Deploying `main.closure` includes the Deployment, RBAC, ConfigMap, and
# everything else needed to make that Service work.
#
# Domain-specific helpers (Corefile builder, port derivation) are imported
# from helpers.nix, unchanged from the module-system version.

{ k8s, lib }:

let
  # Reuse existing helpers — pure functions, no dependency on composition mechanism.
  # These are imported from the original pkgs/coredns/helpers.nix but adapted
  # to work without the module system (no cfg/config/labels arguments).
  helpers = import ./helpers.nix { inherit lib; };
  inherit (helpers) plugin withParams withBlock;
in

k8s.mkPackage
  (
    {
      # Package arguments with defaults (replaces options.nix).
      # These are the user-facing configuration surface.
      namespace ? "kube-system",
      image ? {
        repository = "coredns/coredns";
        tag = "1.13.1";
        pullPolicy = "IfNotPresent";
      },
      replicaCount ? 1,
      isClusterService ? true,
      serviceType ? "ClusterIP",
      serviceAccount ? {
        create = false;
      },

      # Server configuration — the core of CoreDNS config.
      # Matches Helm values.servers structure.
      servers ? [
        {
          zones = [
            {
              zone = ".";
              scheme = null;
              use_tcp = true;
            }
          ];
          port = 53;
          plugins = [
            (plugin "errors")
            (plugin "health" |> withBlock "lameduck 10s")
            (plugin "ready")
            (
              plugin "kubernetes"
              |> withParams "cluster.local in-addr.arpa ip6.arpa"
              |> withBlock "pods insecure\nfallthrough in-addr.arpa ip6.arpa\nttl 30"
            )
            (plugin "prometheus" |> withParams "0.0.0.0:9153")
            (plugin "forward" |> withParams ". /etc/resolv.conf")
            (plugin "cache" |> withParams "30")
            (plugin "loop")
            (plugin "reload")
            (plugin "loadbalance")
          ];
        }
      ],
      zoneFiles ? [ ],

      # Resource limits
      resources ? {
        limits = {
          cpu = "100m";
          memory = "128Mi";
        };
        requests = {
          cpu = "100m";
          memory = "128Mi";
        };
      },

      # Security context
      securityContext ? {
        allowPrivilegeEscalation = false;
        capabilities = {
          add = [ "NET_BIND_SERVICE" ];
          drop = [ "ALL" ];
        };
        readOnlyRootFilesystem = true;
      },

      # Probes
      livenessProbe ? {
        enabled = true;
        initialDelaySeconds = 60;
        periodSeconds = 10;
        timeoutSeconds = 5;
        failureThreshold = 5;
        successThreshold = 1;
      },
      readinessProbe ? {
        enabled = true;
        initialDelaySeconds = 30;
        periodSeconds = 5;
        timeoutSeconds = 5;
        failureThreshold = 1;
        successThreshold = 1;
      },

      # Optional features
      hpa ? {
        enabled = false;
        minReplicas = 1;
        maxReplicas = 5;
        metrics = [ ];
      },
      podDisruptionBudget ? {
        minAvailable = null;
        maxUnavailable = null;
      },
      prometheus ? {
        service = {
          enabled = false;
          annotations = {
            "prometheus.io/scrape" = "true";
            "prometheus.io/port" = "9153";
          };
        };
        monitor = {
          enabled = false;
          interval = null;
        };
      },

      # Cluster-proportional autoscaler
      autoscaler ? {
        enabled = false;
        image = {
          repository = "registry.k8s.io/cpa/cluster-proportional-autoscaler";
          tag = "v1.9.0";
          pullPolicy = "IfNotPresent";
        };
        resources = {
          limits = {
            cpu = "20m";
            memory = "10Mi";
          };
          requests = {
            cpu = "20m";
            memory = "10Mi";
          };
        };
        coresPerReplica = 256;
        nodesPerReplica = 16;
        preventSinglePointFailure = true;
        min = 0;
        max = 0;
        includeUnschedulableNodes = false;
      },

      # Labels
      clusterLabels ? { },
      instance ? "release-name",
    }:
    self:
    let
      # --- Derived values ---
      imageRef = "${image.repository}:${image.tag}";
      hasPrometheus = builtins.any (s: builtins.any (p: p.name == "prometheus") s.plugins) servers;
      corefile = helpers.buildCorefile servers;
      ports = helpers.derivePorts servers;

      pdbEnabled = podDisruptionBudget.minAvailable != null || podDisruptionBudget.maxUnavailable != null;

      # --- Labels ---
      baseSelectorLabels = {
        "app.kubernetes.io/instance" = instance;
        "app.kubernetes.io/name" = "coredns";
      };

      selectorLabels =
        baseSelectorLabels // lib.optionalAttrs isClusterService { "k8s-app" = "coredns"; };

      allLabels =
        clusterLabels
        // selectorLabels
        // {
          "app.kubernetes.io/managed-by" = "kix";
        }
        // lib.optionalAttrs isClusterService {
          "kubernetes.io/cluster-service" = "true";
          "kubernetes.io/name" = "CoreDNS";
        };

      # --- Container spec ---
      corednsContainer = {
        name = "coredns";
        image = imageRef;
        imagePullPolicy = image.pullPolicy;
        args = [
          "-conf"
          "/etc/coredns/Corefile"
        ];
        inherit resources securityContext;
        ports = ports.containerPorts;
        volumeMounts = [
          {
            name = "config-volume";
            mountPath = "/etc/coredns";
          }
        ];
      }
      // lib.optionalAttrs livenessProbe.enabled {
        livenessProbe = {
          httpGet = {
            path = "/health";
            port = 8080;
            scheme = "HTTP";
          };
          inherit (livenessProbe)
            initialDelaySeconds
            periodSeconds
            timeoutSeconds
            failureThreshold
            successThreshold
            ;
        };
      }
      // lib.optionalAttrs readinessProbe.enabled {
        readinessProbe = {
          httpGet = {
            path = "/ready";
            port = 8181;
            scheme = "HTTP";
          };
          inherit (readinessProbe)
            initialDelaySeconds
            periodSeconds
            timeoutSeconds
            failureThreshold
            successThreshold
            ;
        };
      };

      # ConfigMap volume spec
      configVolume = {
        name = "config-volume";
        configMap = {
          name = self.configmap.ref;
          items = [
            {
              key = "Corefile";
              path = "Corefile";
            }
          ]
          ++ map (zf: {
            key = zf.filename;
            path = zf.filename;
          }) zoneFiles;
        };
      };

      # ServiceAccount name: either the created SA or "default"
      saName = if serviceAccount.create then self.serviceAccount.ref else "default";

    in
    {

      # ── Configuration ──────────────────────────────────────────────

      configmap = k8s.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "coredns";
        inherit namespace;
        labels = allLabels;
        data = {
          Corefile = corefile;
        }
        // builtins.listToAttrs (
          map (zf: {
            name = zf.filename;
            value = zf.contents;
          }) zoneFiles
        );
      };

      # ── RBAC ───────────────────────────────────────────────────────
      #
      # YAML ref direction:   binding -> role, binding -> SA
      # Semantic dep direction: SA -> binding -> role
      #
      # The binding's refs to role and SA are tracked automatically by
      # the tree walker. The SA's requires on the binding is declared
      # manually (inverted relationship).

      clusterRole = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "coredns";
        namespace = null;
        labels = allLabels;
        rules = [
          {
            apiGroups = [ "" ];
            resources = [
              "endpoints"
              "services"
              "pods"
              "namespaces"
            ];
            verbs = [
              "list"
              "watch"
            ];
          }
          {
            apiGroups = [ "discovery.k8s.io" ];
            resources = [ "endpointslices" ];
            verbs = [
              "list"
              "watch"
            ];
          }
        ];
      };

      clusterRoleBinding = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        name = "coredns";
        namespace = null;
        labels = allLabels;
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "ClusterRole";
          name = self.clusterRole.ref;
        };
        subjects = [
          {
            kind = "ServiceAccount";
            name = saName;
            inherit namespace;
          }
        ];
      };

      serviceAccount = k8s.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "coredns";
        inherit namespace;
        labels = allLabels;
        # Inverted dep: the SA is useless without its binding
        requires = [ self.clusterRoleBinding ];
      };

      # ── Workload ───────────────────────────────────────────────────

      workload = k8s.mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "coredns";
        inherit namespace;
        labels = allLabels // {
          "app.kubernetes.io/version" = image.tag;
        };
        # The workload always needs RBAC permissions. When serviceAccount.create
        # is true, the SA is referenced via ref (auto-tracked) and the SA
        # requires the binding (inverted dep). When false, we use "default" as
        # a plain string, so we must explicitly require the binding to ensure
        # RBAC resources end up in the closure.
        requires = [
          self.clusterRoleBinding
        ]
        ++ lib.optional serviceAccount.create self.serviceAccount
        ++ lib.optional pdbEnabled self.pdb
        ++ lib.optional hpa.enabled self.hpa;
        spec = {
          replicas = if hpa.enabled || autoscaler.enabled then null else replicaCount;
          selector.matchLabels = selectorLabels;
          strategy = {
            type = "RollingUpdate";
            rollingUpdate = {
              maxUnavailable = 1;
              maxSurge = "25%";
            };
          };
          template = {
            metadata = {
              labels = selectorLabels;
              annotations = lib.optionalAttrs isClusterService {
                "scheduler.alpha.kubernetes.io/tolerations" =
                  ''[{"key":"CriticalAddonsOnly", "operator":"Exists"}]'';
              };
            };
            spec = {
              serviceAccountName = saName;
              terminationGracePeriodSeconds = 30;
              containers = [ corednsContainer ];
              volumes = [ configVolume ];
            }
            // lib.optionalAttrs isClusterService {
              dnsPolicy = "Default";
            };
          };
        };
      };

      # ── PDB (conditional) ──────────────────────────────────────────

      pdb = k8s.mkResource {
        apiVersion = "policy/v1";
        kind = "PodDisruptionBudget";
        name = "coredns";
        inherit namespace;
        labels = allLabels;
        spec = {
          selector.matchLabels = selectorLabels;
        }
        // lib.optionalAttrs (podDisruptionBudget.minAvailable != null) {
          minAvailable = podDisruptionBudget.minAvailable;
        }
        // lib.optionalAttrs (podDisruptionBudget.maxUnavailable != null) {
          maxUnavailable = podDisruptionBudget.maxUnavailable;
        };
      };

      # ── HPA (conditional) ──────────────────────────────────────────

      hpa = k8s.mkResource {
        apiVersion = "autoscaling/v2";
        kind = "HorizontalPodAutoscaler";
        name = "coredns";
        inherit namespace;
        labels = allLabels;
        spec = {
          scaleTargetRef = {
            apiVersion = "apps/v1";
            kind = "Deployment";
            name = self.workload.ref;
          };
          inherit (hpa) minReplicas maxReplicas metrics;
        };
      };

      # ── Metrics Service (conditional) ──────────────────────────────

      metricsService = k8s.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "coredns-metrics";
        inherit namespace;
        labels = allLabels // {
          "app.kubernetes.io/component" = "metrics";
        };
        annotations = prometheus.service.annotations;
        outputs = {
          port = 9153;
        };
        spec = {
          selector = selectorLabels;
          ports = [
            {
              name = "metrics";
              port = 9153;
              protocol = "TCP";
              targetPort = 9153;
            }
          ];
        };
      };

      # ── Autoscaler (conditional) ───────────────────────────────────
      #
      # The cluster-proportional autoscaler is a separate Deployment with
      # its own RBAC, ConfigMap, and labels. It's modeled as sub-resources
      # within the same package.

      autoscalerLabels =
        let
          selector = {
            "app.kubernetes.io/instance" = instance;
            "app.kubernetes.io/name" = "coredns-autoscaler";
            "k8s-app" = "coredns-autoscaler";
          };
        in
        clusterLabels
        // selector
        // {
          "app.kubernetes.io/managed-by" = "kix";
        }
        // lib.optionalAttrs isClusterService {
          "kubernetes.io/cluster-service" = "true";
          "kubernetes.io/name" = "CoreDNS";
        };

      autoscalerSelectorLabels = {
        "app.kubernetes.io/instance" = instance;
        "app.kubernetes.io/name" = "coredns-autoscaler";
        "k8s-app" = "coredns-autoscaler";
      };

      autoscalerConfigmap = k8s.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "coredns-autoscaler";
        inherit namespace;
        labels = self.autoscalerLabels;
        data = {
          linear = builtins.toJSON {
            inherit (autoscaler)
              coresPerReplica
              nodesPerReplica
              preventSinglePointFailure
              min
              max
              includeUnschedulableNodes
              ;
          };
        };
      };

      autoscalerSa = k8s.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "coredns-autoscaler";
        inherit namespace;
        labels = self.autoscalerLabels;
        requires = [ self.autoscalerBinding ];
      };

      autoscalerRole = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "coredns-autoscaler";
        namespace = null;
        labels = self.autoscalerLabels;
        rules = [
          {
            apiGroups = [ "" ];
            resources = [ "nodes" ];
            verbs = [
              "list"
              "watch"
            ];
          }
          {
            apiGroups = [ "" ];
            resources = [ "replicationcontrollers/scale" ];
            verbs = [
              "get"
              "update"
            ];
          }
          {
            apiGroups = [
              "extensions"
              "apps"
            ];
            resources = [
              "deployments/scale"
              "replicasets/scale"
            ];
            verbs = [
              "get"
              "update"
            ];
          }
          {
            apiGroups = [ "" ];
            resources = [ "configmaps" ];
            verbs = [
              "get"
              "create"
            ];
          }
        ];
      };

      autoscalerBinding = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        name = "coredns-autoscaler";
        namespace = null;
        labels = self.autoscalerLabels;
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "ClusterRole";
          name = self.autoscalerRole.ref;
        };
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.autoscalerSa.ref;
            inherit namespace;
          }
        ];
      };

      autoscalerWorkload = k8s.mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "coredns-autoscaler";
        inherit namespace;
        labels = self.autoscalerLabels;
        spec = {
          replicas = null;
          selector.matchLabels = self.autoscalerSelectorLabels;
          template = {
            metadata = {
              labels = self.autoscalerSelectorLabels;
              annotations = {
                "checksum/configmap" = builtins.hashString "sha256" (
                  builtins.toJSON {
                    inherit (autoscaler)
                      coresPerReplica
                      nodesPerReplica
                      preventSinglePointFailure
                      min
                      max
                      includeUnschedulableNodes
                      ;
                  }
                );
              }
              // lib.optionalAttrs isClusterService {
                "scheduler.alpha.kubernetes.io/tolerations" =
                  ''[{"key":"CriticalAddonsOnly", "operator":"Exists"}]'';
              };
            };
            spec = {
              serviceAccountName = self.autoscalerSa.ref;
              containers = [
                {
                  name = "autoscaler";
                  image = "${autoscaler.image.repository}:${autoscaler.image.tag}";
                  imagePullPolicy = autoscaler.image.pullPolicy;
                  resources = autoscaler.resources;
                  command = [
                    "/cluster-proportional-autoscaler"
                    "--namespace=${namespace}"
                    "--configmap=coredns-autoscaler"
                    "--target=Deployment/coredns"
                    "--logtostderr=true"
                    "--v=2"
                  ];
                  livenessProbe = {
                    httpGet = {
                      path = "/healthz";
                      port = 8080;
                      scheme = "HTTP";
                    };
                    initialDelaySeconds = 10;
                    periodSeconds = 5;
                    timeoutSeconds = 5;
                    successThreshold = 1;
                    failureThreshold = 3;
                  };
                }
              ];
            };
          };
        };
      };

      # ── DNS Service ────────────────────────────────────────────────

      service = k8s.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "coredns";
        inherit namespace;
        labels = allLabels;
        outputs = {
          dnsPort = 53;
        };
        spec = {
          type = serviceType;
          selector = selectorLabels;
          ports = ports.servicePorts;
        };
      };

      # ── Main: the public interface ─────────────────────────────────
      #
      # From outside, CoreDNS IS the DNS Service. But deploying it requires
      # the workload behind it, plus optionally the metrics service and
      # the cluster-proportional autoscaler.

      main = k8s.withRequires (
        [ self.workload ]
        ++ lib.optional (hasPrometheus && prometheus.service.enabled) self.metricsService
        ++ lib.optional autoscaler.enabled self.autoscalerWorkload
        ++ lib.optional autoscaler.enabled self.autoscalerConfigmap
      ) self.service;
    }
  )
  {
    # Default arguments
    namespace = "kube-system";
  }

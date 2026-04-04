# Prometheus Operator — deployment, service, RBAC.
#
# The operator watches monitoring.coreos.com CRDs (Prometheus, Alertmanager,
# ServiceMonitor, etc.) and reconciles them into running workloads.

{
  self,
  config,
  scope,
  lib,
  ...
}:
let
  name = scope.instanceName;
  ns = scope.namespaceName;

  labels = {
    "app.kubernetes.io/name" = "prometheus-operator";
    "app.kubernetes.io/instance" = name;
    "app.kubernetes.io/part-of" = "prometheus-operator";
    "app.kubernetes.io/version" = config.image.tag;
  };

  inherit (scope.rbac)
    group
    core
    grant
    watch
    reconcile
    finalize
    own
    readWrite
    full
    allow
    restrictTo
    mkClusterRoleSet
    mkRoleSet
    ;

  # API groups the operator manages
  mon = group "monitoring.coreos.com" [
    "alertmanagerconfigs"
    "alertmanagers"
    "alertmanagers/finalizers"
    "alertmanagers/status"
    "podmonitors"
    "probes"
    "prometheusagents"
    "prometheuses"
    "prometheuses/finalizers"
    "prometheuses/status"
    "prometheusrules"
    "scrapeconfigs"
    "servicemonitors"
    "thanosrulers"
    "thanosrulers/finalizers"
  ];
  apps = group "apps" [
    "statefulsets"
    "deployments"
    "daemonsets"
  ];
  net = group "networking.k8s.io" [ "ingresses" ];
  coord = group "coordination.k8s.io" [ "leases" ];
  authz = group "authorization.k8s.io" [ "subjectaccessreviews" ];

  mkSubject = sa: [
    {
      kind = "ServiceAccount";
      name = sa.out.name;
      namespace = ns;
    }
  ];

  # ── Cluster RBAC ─────────────────────────────────────────────────────

  operatorClusterRoles = mkClusterRoleSet scope {
    subjects = mkSubject self.operatorServiceAccount;
    labels = labels;
    roles = {
      "${name}" = grant [
        # Full access to all monitoring CRDs
        (mon.alertmanagerconfigs |> reconcile)
        (mon.alertmanagers |> reconcile)
        (mon "alertmanagers/finalizers" |> allow [ "update" ])
        (
          mon "alertmanagers/status"
          |> allow [
            "get"
            "update"
          ]
        )
        (mon.podmonitors |> watch)
        (mon.probes |> watch)
        (mon.prometheusagents |> reconcile)
        (mon.prometheuses |> reconcile)
        (mon "prometheuses/finalizers" |> allow [ "update" ])
        (
          mon "prometheuses/status"
          |> allow [
            "get"
            "update"
          ]
        )
        (mon.prometheusrules |> watch)
        (mon.scrapeconfigs |> watch)
        (mon.servicemonitors |> watch)
        (mon.thanosrulers |> reconcile)
        (mon "thanosrulers/finalizers" |> allow [ "update" ])

        # Core resources the operator manages (creates Services, Secrets,
        # ConfigMaps for Prometheus/Alertmanager instances)
        (core.configmaps |> full)
        (core.secrets |> full)
        (core.services |> full)
        (
          core "services/finalizers"
          |> allow [
            "get"
            "create"
            "update"
            "delete"
          ]
        )
        (core.endpoints |> full)
        (core.pods |> watch)
        (core.namespaces |> watch)
        (core.nodes |> watch)
        (
          core.events
          |> allow [
            "create"
            "patch"
          ]
        )

        # Apps — the operator creates StatefulSets for Prometheus/Alertmanager
        (apps.statefulsets |> full)
        (apps.deployments |> full)
        (apps.daemonsets |> full)

        # Networking
        (net.ingresses |> watch)

        # Webhook validation
        (authz.subjectaccessreviews |> allow [ "create" ])
      ];
    };
  };

  # ── Namespace-scoped RBAC (leader election) ──────────────────────────

  operatorLeaderElection = mkRoleSet scope {
    subjects = mkSubject self.operatorServiceAccount;
    labels = labels;
    roles = {
      "${name}:leader-election" = grant [
        (
          coord.leases
          |> restrictTo [ "prometheus-operator" ]
          |> allow [
            "get"
            "update"
            "patch"
          ]
        )
        (coord.leases |> allow [ "create" ])
        (
          core.configmaps
          |> allow [
            "get"
            "list"
            "watch"
            "create"
            "update"
            "patch"
            "delete"
          ]
        )
        (
          core.events
          |> allow [
            "create"
            "patch"
          ]
        )
      ];
    };
  };

in
{
  # ── ServiceAccount ───────────────────────────────────────────────────

  operatorServiceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = name;
    inherit labels;
    extra.automountServiceAccountToken = true;
  };

  # ── Service ──────────────────────────────────────────────────────────

  operatorService = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = name;
    inherit labels;
    spec = {
      type = "ClusterIP";
      selector = self.operatorDeployment.out.selector;
      ports = [
        {
          name = "https";
          port = 443;
          targetPort = "https";
        }
        {
          name = "http-metrics";
          port = 8080;
          targetPort = "http-metrics";
        }
      ];
    };
    outputs = {
      metricsPort = "8080";
    };
  };

  # ── Deployment ───────────────────────────────────────────────────────

  operatorDeployment =
    {
      name = name;
      inherit labels;
      spec = {
        replicas = config.replicas;
        selector.matchLabels = {
          "app.kubernetes.io/name" = "prometheus-operator";
          "app.kubernetes.io/instance" = name;
        };
        template = {
          metadata.labels = labels;
          spec = {
            serviceAccountName = self.operatorServiceAccount.out.name;
            automountServiceAccountToken = true;
            securityContext = {
              runAsNonRoot = true;
              runAsUser = 65534;
              runAsGroup = 65534;
              fsGroup = 65534;
            };
            containers = [
              {
                name = "prometheus-operator";
                image = "${config.image.repository}:${config.image.tag}";
                imagePullPolicy = config.image.pullPolicy;
                args = [
                  "--kubelet-service=kube-system/kubelet"
                  "--prometheus-config-reloader=${config.prometheusConfigReloader.image.repository}:${config.prometheusConfigReloader.image.tag}"
                ]
                ++ lib.optional config.enableAdmissionWebhook "--web.enable-tls=true"
                ++ lib.optional config.enableAdmissionWebhook "--web.cert-file=/etc/tls/private/tls.crt"
                ++ lib.optional config.enableAdmissionWebhook "--web.key-file=/etc/tls/private/tls.key"
                ++ lib.optional config.enableAdmissionWebhook "--web.listen-address=:10250";
                ports = [
                  {
                    name = "http-metrics";
                    containerPort = 8080;
                  }
                ]
                ++ lib.optional config.enableAdmissionWebhook {
                  name = "https";
                  containerPort = 10250;
                };
                securityContext = {
                  allowPrivilegeEscalation = false;
                  readOnlyRootFilesystem = true;
                  capabilities.drop = [ "ALL" ];
                };
                resources = config.resources;
                livenessProbe = {
                  httpGet = {
                    path = "/healthz";
                    port = "http-metrics";
                  };
                  initialDelaySeconds = 15;
                  periodSeconds = 10;
                  failureThreshold = 3;
                };
                readinessProbe = {
                  httpGet = {
                    path = "/healthz";
                    port = "http-metrics";
                  };
                  periodSeconds = 5;
                };
              }
            ];
            nodeSelector = {
              "kubernetes.io/os" = "linux";
            };
          };
        };
      };
    }
    |> scope.mkDeployment;
}
// operatorClusterRoles
// operatorLeaderElection

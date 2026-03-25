# cert-manager package — jetstack/cert-manager v1.17.1.
#
# X.509 certificate management for Kubernetes. Automates issuance and
# renewal of TLS certificates from various sources (Let's Encrypt, Vault,
# Venafi, self-signed, etc.).
#
# Three components:
#   controller  — main cert-manager, reconciles Certificate/Issuer CRDs
#   webhook     — validates and mutates cert-manager resources via admission webhooks
#   cainjector  — injects CA bundles into webhooks, API services, and CRDs
#
# Resources: 3 ServiceAccounts, 3 Deployments, 3 Services,
#   11 ClusterRoles, 9 ClusterRoleBindings, 4 Roles, 4 RoleBindings,
#   MutatingWebhookConfiguration, ValidatingWebhookConfiguration,
#   6 CRDs (certificates, certificaterequests, issuers, clusterissuers,
#   orders, challenges).

{
  scope,
  lib,
}:

{
  meta = {
    description = "cert-manager — X.509 certificate management for Kubernetes";
    provides = [
      "certificates"
      "tls"
    ];
    defaultAliases = [ "certManager" ];
    k8s.minVersion = "1.25";
  };

  options = {
    image = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "quay.io/jetstack/cert-manager-controller";
        tag = "v1.17.1";
        pullPolicy = "IfNotPresent";
      };
    };
    webhook = lib.mkOption {
      type = lib.types.anything;
      default = {
        image = {
          repository = "quay.io/jetstack/cert-manager-webhook";
          tag = "v1.17.1";
        };
        replicaCount = 1;
      };
    };
    cainjector = lib.mkOption {
      type = lib.types.anything;
      default = {
        image = {
          repository = "quay.io/jetstack/cert-manager-cainjector";
          tag = "v1.17.1";
        };
        replicaCount = 1;
      };
    };
    acmesolver = lib.mkOption {
      type = lib.types.anything;
      default = {
        image = {
          repository = "quay.io/jetstack/cert-manager-acmesolver";
          tag = "v1.17.1";
        };
      };
    };
    replicaCount = lib.mkOption {
      type = lib.types.int;
      default = 1;
    };
    installCRDs = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    resources = lib.mkOption {
      type = lib.types.nullOr lib.types.anything;
      default = null;
    };
    dns01RecursiveNameservers = lib.mkOption {
      type = lib.types.str;
      default = "";
    };
    dns01RecursiveNameserversOnly = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    prometheus = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = false;
      };
    };
  };

  build =
    {
      self,
      config,
      clusterConfig,
    }:
    let

      name = scope.instanceName;
      ns = scope.namespaceName;

      # --- Labels ---

      controllerLabels = {
        "app.kubernetes.io/name" = "cert-manager";
        "app.kubernetes.io/instance" = name;
        "app.kubernetes.io/component" = "controller";
      };

      webhookLabels = {
        "app.kubernetes.io/name" = "webhook";
        "app.kubernetes.io/instance" = name;
        "app.kubernetes.io/component" = "webhook";
      };

      cainjectorLabels = {
        "app.kubernetes.io/name" = "cainjector";
        "app.kubernetes.io/instance" = name;
        "app.kubernetes.io/component" = "cainjector";
      };

      controllerSelector = {
        "app.kubernetes.io/name" = "cert-manager";
        "app.kubernetes.io/instance" = name;
        "app.kubernetes.io/component" = "controller";
      };

      webhookSelector = {
        "app.kubernetes.io/name" = "webhook";
        "app.kubernetes.io/instance" = name;
        "app.kubernetes.io/component" = "webhook";
      };

      cainjectorSelector = {
        "app.kubernetes.io/name" = "cainjector";
        "app.kubernetes.io/instance" = name;
        "app.kubernetes.io/component" = "cainjector";
      };

      # --- Helpers ---

      mkControllerSubject = sa: [
        {
          kind = "ServiceAccount";
          name = sa.out.name;
          namespace = ns;
        }
      ];

      # --- RBAC DSL ---

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
        emit
        watchAndFinalize
        allow
        restrictTo
        mkClusterRoleSet
        mkRoleSet
        ;

      cm = group "cert-manager.io" [
        "issuers"
        "clusterissuers"
        "certificates"
        "certificaterequests"
        "signers"
      ];
      acme = group "acme.cert-manager.io" [
        "orders"
        "challenges"
      ];
      gw = group "gateway.networking.k8s.io" [
        "gateways"
        "httproutes"
      ];
      net = group "networking.k8s.io" [ "ingresses" ];
      certs = group "certificates.k8s.io" [
        "certificatesigningrequests"
        "signers"
      ];
      authz = group "authorization.k8s.io" [ "subjectaccessreviews" ];
      coord = group "coordination.k8s.io" [ "leases" ];
      admreg = group "admissionregistration.k8s.io" [
        "validatingwebhookconfigurations"
        "mutatingwebhookconfigurations"
      ];
      apireg = group "apiregistration.k8s.io" [ "apiservices" ];
      apiext = group "apiextensions.k8s.io" [ "customresourcedefinitions" ];
      ocp = group "route.openshift.io" [ ];

      # Pod security context shared by all three components.
      podSecurityContext = {
        runAsNonRoot = true;
        seccompProfile.type = "RuntimeDefault";
      };

      containerSecurityContext = {
        allowPrivilegeEscalation = false;
        capabilities.drop = [ "ALL" ];
        readOnlyRootFilesystem = true;
      };

      # CRD helper — delegates to scope.mkCRD which auto-attaches CR builders on .out.
      mkCRD =
        {
          categories ? [ "cert-manager" ],
          ...
        }@args:
        scope.mkCRD (
          removeAttrs args [ "categories" ]
          // {
            labels = controllerLabels;
            inherit categories;
          }
        );

    in
    let

      # ── Controller cluster-scoped RBAC ─────────────────────────────────

      controllerClusterRoles = mkClusterRoleSet scope {
        subjects = mkControllerSubject self.controllerServiceAccount;
        labels = controllerLabels;
        roles = {

          "${name}-controller-issuers" = grant [
            (cm.issuers |> reconcile)
            (core.secrets |> readWrite)
            (core.events |> emit)
          ];

          "${name}-controller-clusterissuers" = grant [
            (cm.clusterissuers |> reconcile)
            (core.secrets |> readWrite)
            (core.events |> emit)
          ];

          "${name}-controller-certificates" = grant [
            (cm.certificates |> reconcile)
            (cm.certificaterequests |> reconcile)
            (cm.certificates |> finalize)
            (cm.certificaterequests |> finalize)
            (cm.clusterissuers |> watch)
            (cm.issuers |> watch)
            (acme.orders |> own)
            (core.secrets |> full)
            (core.events |> emit)
          ];

          "${name}-controller-orders" = grant [
            (acme.orders |> reconcile)
            (acme.orders |> finalize)
            (acme.challenges |> own)
            (cm.clusterissuers |> watch)
            (cm.issuers |> watch)
            (core.secrets |> watch)
            (core.events |> emit)
          ];

          "${name}-controller-challenges" = grant [
            (acme.challenges |> reconcile)
            (acme.challenges |> finalize)
            (cm.issuers |> watch)
            (cm.clusterissuers |> watch)
            (core.secrets |> watch)
            (core.events |> emit)
            (core.pods |> own)
            (core.services |> own)
            (net.ingresses |> readWrite)
            (gw.httproutes |> readWrite)
            (ocp "routes/custom-host" |> allow [ "create" ])
          ];

          "${name}-controller-ingress-shim" = grant [
            (
              cm.certificates
              |> allow [
                "create"
                "update"
                "delete"
              ]
            )
            (
              cm.certificaterequests
              |> allow [
                "create"
                "update"
                "delete"
              ]
            )
            (cm.certificates |> watch)
            (cm.certificaterequests |> watch)
            (cm.issuers |> watch)
            (cm.clusterissuers |> watch)
            (net.ingresses |> watchAndFinalize)
            (gw.gateways |> watchAndFinalize)
            (gw.httproutes |> watchAndFinalize)
            (core.events |> emit)
          ];

          "${name}-controller-approve:cert-manager-io" = grant [
            (
              cm.signers
              |> restrictTo [
                "issuers.cert-manager.io/*"
                "clusterissuers.cert-manager.io/*"
              ]
              |> allow [ "approve" ]
            )
          ];

          "${name}-controller-certificatesigningrequests" = grant [
            (
              certs.certificatesigningrequests
              |> allow [
                "get"
                "list"
                "watch"
                "update"
              ]
            )
            (
              certs "certificatesigningrequests/status"
              |> allow [
                "update"
                "patch"
              ]
            )
            (
              certs.signers
              |> restrictTo [
                "issuers.cert-manager.io/*"
                "clusterissuers.cert-manager.io/*"
              ]
              |> allow [ "sign" ]
            )
            (authz.subjectaccessreviews |> allow [ "create" ])
          ];
        };
      };

      # ── Controller namespace-scoped RBAC ───────────────────────────────

      controllerLeaderElection = mkRoleSet scope {
        subjects = mkControllerSubject self.controllerServiceAccount;
        labels = controllerLabels;
        roles = {
          "${name}:leaderelection" = grant [
            (
              coord.leases
              |> restrictTo [ "cert-manager-controller" ]
              |> allow [
                "get"
                "update"
                "patch"
              ]
            )
            (coord.leases |> allow [ "create" ])
          ];
        };
      };

      controllerTokenRequest = mkRoleSet scope {
        subjects = mkControllerSubject self.controllerServiceAccount;
        labels = controllerLabels;
        roles = {
          "${name}-tokenrequest" = {
            bindingName = "cert-manager-${name}-tokenrequest";
            rules = grant [
              (
                core "serviceaccounts/token"
                |> restrictTo [ self.controllerServiceAccount.out.name ]
                |> allow [ "create" ]
              )
            ];
          };
        };
      };

      # ── Webhook RBAC ───────────────────────────────────────────────────

      mkWebhookSubject = [
        {
          kind = "ServiceAccount";
          name = self.webhookServiceAccount.out.name;
          namespace = ns;
        }
      ];

      webhookClusterRoles = mkClusterRoleSet scope {
        subjects = mkWebhookSubject;
        labels = webhookLabels;
        roles = {
          "${name}-webhook:subjectaccessreviews" = grant [
            (authz.subjectaccessreviews |> allow [ "create" ])
          ];
        };
      };

      webhookRoles = mkRoleSet scope {
        subjects = mkWebhookSubject;
        labels = webhookLabels;
        roles = {
          "${name}-webhook:dynamic-serving" = grant [
            (
              core.secrets
              |> restrictTo [ "${name}-webhook-ca" ]
              |> allow [
                "get"
                "list"
                "watch"
                "update"
              ]
            )
            (core.secrets |> allow [ "create" ])
          ];
        };
      };

      # ── CA Injector RBAC ───────────────────────────────────────────────

      mkCainjectorSubject = [
        {
          kind = "ServiceAccount";
          name = self.cainjectorServiceAccount.out.name;
          namespace = ns;
        }
      ];

      cainjectorClusterRoles = mkClusterRoleSet scope {
        subjects = mkCainjectorSubject;
        labels = cainjectorLabels;
        roles = {
          "${name}-cainjector" = grant [
            (cm.certificates |> watch)
            (core.secrets |> watch)
            (
              core.events
              |> allow [
                "get"
                "create"
                "update"
                "patch"
              ]
            )
            (
              admreg.validatingwebhookconfigurations
              |> allow [
                "get"
                "list"
                "watch"
                "update"
                "patch"
              ]
            )
            (
              admreg.mutatingwebhookconfigurations
              |> allow [
                "get"
                "list"
                "watch"
                "update"
                "patch"
              ]
            )
            (
              apireg.apiservices
              |> allow [
                "get"
                "list"
                "watch"
                "update"
                "patch"
              ]
            )
            (
              apiext.customresourcedefinitions
              |> allow [
                "get"
                "list"
                "watch"
                "update"
                "patch"
              ]
            )
          ];
        };
      };

      cainjectorLeaderElection = mkRoleSet scope {
        subjects = mkCainjectorSubject;
        labels = cainjectorLabels;
        roles = {
          "${name}-cainjector:leaderelection" = grant [
            (
              coord.leases
              |> restrictTo [
                "cert-manager-cainjector-leader-election"
                "cert-manager-cainjector-leader-election-core"
              ]
              |> allow [
                "get"
                "update"
                "patch"
              ]
            )
            (coord.leases |> allow [ "create" ])
          ];
        };
      };

    in
    {

      # ============================================================
      # CRDs — grouped in crds folder for auto-exposure to consumers
      # ============================================================

      crds = {
        certificates = mkCRD {
          group = "cert-manager.io";
          kind = "Certificate";
          listKind = "CertificateList";
          plural = "certificates";
          singular = "certificate";
          shortNames = [
            "cert"
            "certs"
          ];
          printerColumns = [
            {
              jsonPath = ".status.conditions[?(@.type==\"Ready\")].status";
              name = "Ready";
              type = "string";
            }
            {
              jsonPath = ".spec.secretName";
              name = "Secret";
              type = "string";
            }
            {
              jsonPath = ".spec.issuerRef.name";
              name = "Issuer";
              type = "string";
            }
            {
              jsonPath = ".status.conditions[?(@.type==\"Ready\")].message";
              name = "Status";
              priority = 1;
              type = "string";
            }
            {
              jsonPath = ".metadata.creationTimestamp";
              name = "Age";
              type = "date";
            }
          ];
        };

        certificateRequests = mkCRD {
          group = "cert-manager.io";
          kind = "CertificateRequest";
          listKind = "CertificateRequestList";
          plural = "certificaterequests";
          singular = "certificaterequest";
          shortNames = [
            "cr"
            "crs"
          ];
          printerColumns = [
            {
              jsonPath = ".status.conditions[?(@.type==\"Approved\")].status";
              name = "Approved";
              type = "string";
            }
            {
              jsonPath = ".status.conditions[?(@.type==\"Denied\")].status";
              name = "Denied";
              type = "string";
            }
            {
              jsonPath = ".status.conditions[?(@.type==\"Ready\")].status";
              name = "Ready";
              type = "string";
            }
            {
              jsonPath = ".spec.issuerRef.name";
              name = "Issuer";
              type = "string";
            }
            {
              jsonPath = ".spec.username";
              name = "Requester";
              type = "string";
            }
            {
              jsonPath = ".status.conditions[?(@.type==\"Ready\")].message";
              name = "Status";
              priority = 1;
              type = "string";
            }
            {
              jsonPath = ".metadata.creationTimestamp";
              name = "Age";
              type = "date";
            }
          ];
        };

        challenges = mkCRD {
          group = "acme.cert-manager.io";
          kind = "Challenge";
          listKind = "ChallengeList";
          plural = "challenges";
          singular = "challenge";
          categories = [
            "cert-manager"
            "cert-manager-acme"
          ];
          printerColumns = [
            {
              jsonPath = ".status.state";
              name = "State";
              type = "string";
            }
            {
              jsonPath = ".spec.dnsName";
              name = "Domain";
              type = "string";
            }
            {
              jsonPath = ".status.reason";
              name = "Reason";
              priority = 1;
              type = "string";
            }
            {
              jsonPath = ".metadata.creationTimestamp";
              name = "Age";
              type = "date";
            }
          ];
        };

        clusterIssuers = mkCRD {
          group = "cert-manager.io";
          kind = "ClusterIssuer";
          listKind = "ClusterIssuerList";
          plural = "clusterissuers";
          singular = "clusterissuer";
          crdScope = "Cluster";
          printerColumns = [
            {
              jsonPath = ".status.conditions[?(@.type==\"Ready\")].status";
              name = "Ready";
              type = "string";
            }
            {
              jsonPath = ".status.conditions[?(@.type==\"Ready\")].message";
              name = "Status";
              priority = 1;
              type = "string";
            }
            {
              jsonPath = ".metadata.creationTimestamp";
              name = "Age";
              type = "date";
            }
          ];
        };

        issuers = mkCRD {
          group = "cert-manager.io";
          kind = "Issuer";
          listKind = "IssuerList";
          plural = "issuers";
          singular = "issuer";
          printerColumns = [
            {
              jsonPath = ".status.conditions[?(@.type==\"Ready\")].status";
              name = "Ready";
              type = "string";
            }
            {
              jsonPath = ".status.conditions[?(@.type==\"Ready\")].message";
              name = "Status";
              priority = 1;
              type = "string";
            }
            {
              jsonPath = ".metadata.creationTimestamp";
              name = "Age";
              type = "date";
            }
          ];
        };

        orders = mkCRD {
          group = "acme.cert-manager.io";
          kind = "Order";
          listKind = "OrderList";
          plural = "orders";
          singular = "order";
          categories = [
            "cert-manager"
            "cert-manager-acme"
          ];
          printerColumns = [
            {
              jsonPath = ".status.state";
              name = "State";
              type = "string";
            }
            {
              jsonPath = ".spec.issuerRef.name";
              name = "Issuer";
              type = "string";
            }
            {
              jsonPath = ".status.reason";
              name = "Reason";
              priority = 1;
              type = "string";
            }
            {
              jsonPath = ".metadata.creationTimestamp";
              name = "Age";
              type = "date";
            }
          ];
        };
      };

      # ============================================================
      # Controller — ServiceAccount, RBAC, Service, Deployment
      # ============================================================

      controllerServiceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "${name}";
        labels = controllerLabels;
        extra.automountServiceAccountToken = true;
      };

      # -- Controller RBAC (aggregate roles — no bindings, RBAC aggregation labels) --

      clusterViewRole = scope.mkClusterResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "${name}-cluster-view";
        labels = controllerLabels // {
          "rbac.authorization.k8s.io/aggregate-to-cluster-reader" = "true";
        };
        extra.rules = grant [ (cm.clusterissuers |> watch) ];
      };

      viewRole = scope.mkClusterResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "${name}-view";
        labels = controllerLabels // {
          "rbac.authorization.k8s.io/aggregate-to-view" = "true";
          "rbac.authorization.k8s.io/aggregate-to-edit" = "true";
          "rbac.authorization.k8s.io/aggregate-to-admin" = "true";
          "rbac.authorization.k8s.io/aggregate-to-cluster-reader" = "true";
        };
        extra.rules = grant [
          (cm.certificates |> watch)
          (cm.certificaterequests |> watch)
          (cm.issuers |> watch)
          (acme.challenges |> watch)
          (acme.orders |> watch)
        ];
      };

      editRole = scope.mkClusterResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "${name}-edit";
        labels = controllerLabels // {
          "rbac.authorization.k8s.io/aggregate-to-edit" = "true";
          "rbac.authorization.k8s.io/aggregate-to-admin" = "true";
        };
        extra.rules = grant [
          (
            cm.certificates
            |> allow [
              "create"
              "delete"
              "deletecollection"
              "patch"
              "update"
            ]
          )
          (
            cm.certificaterequests
            |> allow [
              "create"
              "delete"
              "deletecollection"
              "patch"
              "update"
            ]
          )
          (
            cm.issuers
            |> allow [
              "create"
              "delete"
              "deletecollection"
              "patch"
              "update"
            ]
          )
          (cm "certificates/status" |> allow [ "update" ])
          (
            acme.challenges
            |> allow [
              "create"
              "delete"
              "deletecollection"
              "patch"
              "update"
            ]
          )
          (
            acme.orders
            |> allow [
              "create"
              "delete"
              "deletecollection"
              "patch"
              "update"
            ]
          )
        ];
      };

      # Controller ClusterRoles, ClusterRoleBindings, Roles, RoleBindings are now
      # generated by the RBAC DSL (controllerClusterRoles, controllerLeaderElection,
      # controllerTokenRequest) in the inner `let` block above.

      # -- Controller Service --

      controllerService = scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${name}";
        labels = controllerLabels;
        spec = {
          type = "ClusterIP";
          selector = controllerSelector;
          ports = [
            {
              name = "tcp-prometheus-servicemonitor";
              port = 9402;
              protocol = "TCP";
              targetPort = 9402;
            }
          ];
        };
        outputs = {
          metricsPort = "9402";
        };
      };

      # -- Controller Deployment --

      controllerDeployment = scope.mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "${name}";
        labels = controllerLabels;
        spec = {
          replicas = config.replicaCount;
          selector.matchLabels = controllerSelector;
          template = {
            metadata = {
              labels = controllerLabels;
              annotations = {
                "prometheus.io/path" = "/metrics";
                "prometheus.io/scrape" = "true";
                "prometheus.io/port" = "9402";
              };
            };
            spec = {
              serviceAccountName = self.controllerServiceAccount.out.name;
              enableServiceLinks = false;
              securityContext = podSecurityContext;
              containers = [
                (
                  {
                    name = "cert-manager-controller";
                    image = "${config.image.repository}:${config.image.tag}";
                    imagePullPolicy = config.image.pullPolicy;
                    args = [
                      "--v=2"
                      "--cluster-resource-namespace=$(POD_NAMESPACE)"
                      "--acme-http01-solver-image=${config.acmesolver.image.repository}:${config.acmesolver.image.tag}"
                      "--leader-election-namespace=${ns}"
                    ]
                    ++ lib.optional config.dns01RecursiveNameserversOnly "--dns01-recursive-nameservers-only"
                    ++ lib.optional (
                      config.dns01RecursiveNameservers != ""
                    ) "--dns01-recursive-nameservers=${config.dns01RecursiveNameservers}"
                    ++ [ "--max-concurrent-challenges=60" ];
                    ports = [
                      {
                        name = "http-metrics";
                        containerPort = 9402;
                        protocol = "TCP";
                      }
                      {
                        name = "http-healthz";
                        containerPort = 9403;
                        protocol = "TCP";
                      }
                    ];
                    securityContext = containerSecurityContext;
                    env = [
                      {
                        name = "POD_NAMESPACE";
                        valueFrom.fieldRef = {
                          apiVersion = "v1";
                          fieldPath = "metadata.namespace";
                        };
                      }
                    ];
                    livenessProbe = {
                      httpGet = {
                        port = "http-healthz";
                        path = "/livez";
                        scheme = "HTTP";
                      };
                      initialDelaySeconds = 10;
                      periodSeconds = 10;
                      timeoutSeconds = 15;
                      successThreshold = 1;
                      failureThreshold = 8;
                    };
                  }
                  // lib.optionalAttrs (config.resources != null) { resources = config.resources; }
                )
              ];
              nodeSelector = {
                "kubernetes.io/os" = "linux";
              };
            };
          };
        };
      };

      # ============================================================
      # Webhook — ServiceAccount, RBAC, Service, Deployment, Configs
      # ============================================================

      webhookServiceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "${name}-webhook";
        labels = webhookLabels;
        extra.automountServiceAccountToken = true;
      };

      # -- Webhook Service --

      webhookService = scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${name}-webhook";
        labels = webhookLabels;
        spec = {
          type = "ClusterIP";
          selector = webhookSelector;
          ports = [
            {
              name = "https";
              port = 443;
              protocol = "TCP";
              targetPort = "https";
            }
            {
              name = "metrics";
              port = 9402;
              protocol = "TCP";
              targetPort = "http-metrics";
            }
          ];
        };
      };

      # -- Webhook Deployment --

      webhookDeployment = scope.mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "${name}-webhook";
        labels = webhookLabels;
        spec = {
          replicas = config.webhook.replicaCount;
          selector.matchLabels = webhookSelector;
          template = {
            metadata = {
              labels = webhookLabels;
              annotations = {
                "prometheus.io/path" = "/metrics";
                "prometheus.io/scrape" = "true";
                "prometheus.io/port" = "9402";
              };
            };
            spec = {
              serviceAccountName = self.webhookServiceAccount.out.name;
              enableServiceLinks = false;
              securityContext = podSecurityContext;
              containers = [
                {
                  name = "cert-manager-webhook";
                  image = "${config.webhook.image.repository}:${config.webhook.image.tag}";
                  imagePullPolicy = config.image.pullPolicy;
                  args = [
                    "--v=2"
                    "--secure-port=10250"
                    "--dynamic-serving-ca-secret-namespace=$(POD_NAMESPACE)"
                    "--dynamic-serving-ca-secret-name=${name}-webhook-ca"
                    "--dynamic-serving-dns-names=${name}-webhook"
                    "--dynamic-serving-dns-names=${name}-webhook.$(POD_NAMESPACE)"
                    "--dynamic-serving-dns-names=${name}-webhook.$(POD_NAMESPACE).svc"
                  ];
                  ports = [
                    {
                      name = "https";
                      containerPort = 10250;
                      protocol = "TCP";
                    }
                    {
                      name = "healthcheck";
                      containerPort = 6080;
                      protocol = "TCP";
                    }
                    {
                      name = "http-metrics";
                      containerPort = 9402;
                      protocol = "TCP";
                    }
                  ];
                  livenessProbe = {
                    httpGet = {
                      path = "/livez";
                      port = 6080;
                      scheme = "HTTP";
                    };
                    initialDelaySeconds = 60;
                    periodSeconds = 10;
                    timeoutSeconds = 1;
                    successThreshold = 1;
                    failureThreshold = 3;
                  };
                  readinessProbe = {
                    httpGet = {
                      path = "/healthz";
                      port = 6080;
                      scheme = "HTTP";
                    };
                    initialDelaySeconds = 5;
                    periodSeconds = 5;
                    timeoutSeconds = 1;
                    successThreshold = 1;
                    failureThreshold = 3;
                  };
                  securityContext = containerSecurityContext;
                  env = [
                    {
                      name = "POD_NAMESPACE";
                      valueFrom.fieldRef = {
                        apiVersion = "v1";
                        fieldPath = "metadata.namespace";
                      };
                    }
                  ];
                }
              ];
              nodeSelector = {
                "kubernetes.io/os" = "linux";
              };
            };
          };
        };
      };

      # -- Webhook configurations --

      mutatingWebhookConfiguration = scope.mkClusterResource {
        apiVersion = "admissionregistration.k8s.io/v1";
        kind = "MutatingWebhookConfiguration";
        name = "${name}-webhook";
        labels = webhookLabels;
        annotations = {
          "cert-manager.io/inject-ca-from-secret" = "${ns}/${name}-webhook-ca";
        };
        extra.webhooks = [
          {
            name = "webhook.cert-manager.io";
            rules = [
              {
                apiGroups = [ "cert-manager.io" ];
                apiVersions = [ "v1" ];
                operations = [ "CREATE" ];
                resources = [ "certificaterequests" ];
              }
            ];
            admissionReviewVersions = [ "v1" ];
            matchPolicy = "Equivalent";
            timeoutSeconds = 30;
            failurePolicy = "Fail";
            sideEffects = "None";
            clientConfig.service = {
              name = self.webhookService.out.name;
              namespace = ns;
              path = "/mutate";
            };
          }
        ];
      };

      validatingWebhookConfiguration = scope.mkClusterResource {
        apiVersion = "admissionregistration.k8s.io/v1";
        kind = "ValidatingWebhookConfiguration";
        name = "${name}-webhook";
        labels = webhookLabels;
        annotations = {
          "cert-manager.io/inject-ca-from-secret" = "${ns}/${name}-webhook-ca";
        };
        extra.webhooks = [
          {
            name = "webhook.cert-manager.io";
            namespaceSelector = {
              matchExpressions = [
                {
                  key = "cert-manager.io/disable-validation";
                  operator = "NotIn";
                  values = [ "true" ];
                }
              ];
            };
            rules = [
              {
                apiGroups = [
                  "cert-manager.io"
                  "acme.cert-manager.io"
                ];
                apiVersions = [ "v1" ];
                operations = [
                  "CREATE"
                  "UPDATE"
                ];
                resources = [ "*/*" ];
              }
            ];
            admissionReviewVersions = [ "v1" ];
            matchPolicy = "Equivalent";
            timeoutSeconds = 30;
            failurePolicy = "Fail";
            sideEffects = "None";
            clientConfig.service = {
              name = self.webhookService.out.name;
              namespace = ns;
              path = "/validate";
            };
          }
        ];
      };

      # ============================================================
      # CA Injector — ServiceAccount, RBAC, Service, Deployment
      # ============================================================

      cainjectorServiceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "${name}-cainjector";
        labels = cainjectorLabels;
        extra.automountServiceAccountToken = true;
      };

      # -- CA Injector Service --

      cainjectorService = scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${name}-cainjector";
        labels = cainjectorLabels;
        spec = {
          type = "ClusterIP";
          selector = cainjectorSelector;
          ports = [
            {
              name = "http-metrics";
              port = 9402;
              protocol = "TCP";
              targetPort = 9402;
            }
          ];
        };
      };

      # -- CA Injector Deployment --

      cainjectorDeployment = scope.mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "${name}-cainjector";
        labels = cainjectorLabels;
        spec = {
          replicas = config.cainjector.replicaCount;
          selector.matchLabels = cainjectorSelector;
          template = {
            metadata = {
              labels = cainjectorLabels;
              annotations = {
                "prometheus.io/path" = "/metrics";
                "prometheus.io/scrape" = "true";
                "prometheus.io/port" = "9402";
              };
            };
            spec = {
              serviceAccountName = self.cainjectorServiceAccount.out.name;
              enableServiceLinks = false;
              securityContext = podSecurityContext;
              containers = [
                {
                  name = "cert-manager-cainjector";
                  image = "${config.cainjector.image.repository}:${config.cainjector.image.tag}";
                  imagePullPolicy = config.image.pullPolicy;
                  args = [
                    "--v=2"
                    "--leader-election-namespace=${ns}"
                  ];
                  ports = [
                    {
                      name = "http-metrics";
                      containerPort = 9402;
                      protocol = "TCP";
                    }
                  ];
                  env = [
                    {
                      name = "POD_NAMESPACE";
                      valueFrom.fieldRef = {
                        apiVersion = "v1";
                        fieldPath = "metadata.namespace";
                      };
                    }
                  ];
                  securityContext = containerSecurityContext;
                }
              ];
              nodeSelector = {
                "kubernetes.io/os" = "linux";
              };
            };
          };
        };
      };

      # ============================================================
      # Entry point
      # ============================================================

      main = {
        resource = self.controllerDeployment;
        requires =
          # CRDs
          (lib.optionals config.installCRDs [
            self.crds.certificates
            self.crds.certificateRequests
            self.crds.challenges
            self.crds.clusterIssuers
            self.crds.issuers
            self.crds.orders
          ])
          # Controller
          ++ [
            self.controllerServiceAccount
            self.controllerService
          ]
          # Aggregate roles (no binding — not auto-discovered via inverse deps)
          ++ [
            self.clusterViewRole
            self.viewRole
            self.editRole
          ]
          # Webhook
          ++ [
            self.webhookServiceAccount
            self.webhookService
            self.webhookDeployment
            self.mutatingWebhookConfiguration
            self.validatingWebhookConfiguration
          ]
          # CA Injector
          ++ [
            self.cainjectorServiceAccount
            self.cainjectorService
            self.cainjectorDeployment
          ];
      };
    }
    // controllerClusterRoles
    // controllerLeaderElection
    // controllerTokenRequest
    // webhookClusterRoles
    // webhookRoles
    // cainjectorClusterRoles
    // cainjectorLeaderElection;
}

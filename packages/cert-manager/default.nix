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
  config,
  lib,
}:

let
  cfg = scope.defaults config {
    image = {
      repository = "quay.io/jetstack/cert-manager-controller";
      tag = "v1.17.1";
      pullPolicy = "IfNotPresent";
    };
    webhook = {
      image = {
        repository = "quay.io/jetstack/cert-manager-webhook";
        tag = "v1.17.1";
      };
      replicaCount = 1;
    };
    cainjector = {
      image = {
        repository = "quay.io/jetstack/cert-manager-cainjector";
        tag = "v1.17.1";
      };
      replicaCount = 1;
    };
    acmesolver = {
      image = {
        repository = "quay.io/jetstack/cert-manager-acmesolver";
        tag = "v1.17.1";
      };
    };
    replicaCount = 1;
    installCRDs = true;
    resources = null;
    dns01RecursiveNameservers = "";
    dns01RecursiveNameserversOnly = false;
    prometheus = {
      enabled = false;
    };
  };

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
      name = "${sa}";
      namespace = ns;
    }
  ];

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

  # --- CRD helper ---

  mkCRD =
    {
      crdName,
      group,
      kind,
      listKind,
      plural,
      singular,
      crdScope ? "Namespaced",
      shortNames ? [ ],
      categories ? [ "cert-manager" ],
      printerColumns ? [ ],
    }:
    scope.mkClusterResource {
      apiVersion = "apiextensions.k8s.io/v1";
      kind = "CustomResourceDefinition";
      name = crdName;
      labels = controllerLabels;
      extra = {
        spec = {
          inherit group;
          scope = crdScope;
          names = {
            inherit
              kind
              listKind
              plural
              singular
              ;
          }
          // lib.optionalAttrs (shortNames != [ ]) { inherit shortNames; }
          // lib.optionalAttrs (categories != [ ]) { inherit categories; };
          versions = [
            (
              {
                name = "v1";
                served = true;
                storage = true;
                subresources.status = { };
                schema.openAPIV3Schema = {
                  type = "object";
                  # Note: Full OpenAPI validation schema omitted for brevity.
                  # In production, apply the complete CRD YAML from the upstream
                  # cert-manager release to get full validation.
                  properties = {
                    apiVersion = {
                      type = "string";
                    };
                    kind = {
                      type = "string";
                    };
                    metadata = {
                      type = "object";
                    };
                    spec = {
                      type = "object";
                      "x-kubernetes-preserve-unknown-fields" = true;
                    };
                    status = {
                      type = "object";
                      "x-kubernetes-preserve-unknown-fields" = true;
                    };
                  };
                };
              }
              // lib.optionalAttrs (printerColumns != [ ]) {
                additionalPrinterColumns = printerColumns;
              }
            )
          ];
        };
      };
    };

in
self: {

  # ============================================================
  # CRDs
  # ============================================================

  crdCertificates = mkCRD {
    crdName = "certificates.cert-manager.io";
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

  crdCertificateRequests = mkCRD {
    crdName = "certificaterequests.cert-manager.io";
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

  crdChallenges = mkCRD {
    crdName = "challenges.acme.cert-manager.io";
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

  crdClusterIssuers = mkCRD {
    crdName = "clusterissuers.cert-manager.io";
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

  crdIssuers = mkCRD {
    crdName = "issuers.cert-manager.io";
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

  crdOrders = mkCRD {
    crdName = "orders.acme.cert-manager.io";
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

  # -- Controller ClusterRoles --

  controllerRoleIssuers = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${name}-controller-issuers";
    labels = controllerLabels;
    extra.rules = [
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [
          "issuers"
          "issuers/status"
        ];
        verbs = [
          "update"
          "patch"
        ];
      }
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [ "issuers" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "secrets" ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "update"
          "delete"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "events" ];
        verbs = [
          "create"
          "patch"
        ];
      }
    ];
  };

  controllerRoleClusterIssuers = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${name}-controller-clusterissuers";
    labels = controllerLabels;
    extra.rules = [
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [
          "clusterissuers"
          "clusterissuers/status"
        ];
        verbs = [
          "update"
          "patch"
        ];
      }
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [ "clusterissuers" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "secrets" ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "update"
          "delete"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "events" ];
        verbs = [
          "create"
          "patch"
        ];
      }
    ];
  };

  controllerRoleCertificates = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${name}-controller-certificates";
    labels = controllerLabels;
    extra.rules = [
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [
          "certificates"
          "certificates/status"
          "certificaterequests"
          "certificaterequests/status"
        ];
        verbs = [
          "update"
          "patch"
        ];
      }
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [
          "certificates"
          "certificaterequests"
          "clusterissuers"
          "issuers"
        ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [
          "certificates/finalizers"
          "certificaterequests/finalizers"
        ];
        verbs = [ "update" ];
      }
      {
        apiGroups = [ "acme.cert-manager.io" ];
        resources = [ "orders" ];
        verbs = [
          "create"
          "delete"
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "secrets" ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "update"
          "delete"
          "patch"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "events" ];
        verbs = [
          "create"
          "patch"
        ];
      }
    ];
  };

  controllerRoleOrders = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${name}-controller-orders";
    labels = controllerLabels;
    extra.rules = [
      {
        apiGroups = [ "acme.cert-manager.io" ];
        resources = [
          "orders"
          "orders/status"
        ];
        verbs = [
          "update"
          "patch"
        ];
      }
      {
        apiGroups = [ "acme.cert-manager.io" ];
        resources = [
          "orders"
          "challenges"
        ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [
          "clusterissuers"
          "issuers"
        ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "acme.cert-manager.io" ];
        resources = [ "challenges" ];
        verbs = [
          "create"
          "delete"
        ];
      }
      {
        apiGroups = [ "acme.cert-manager.io" ];
        resources = [ "orders/finalizers" ];
        verbs = [ "update" ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "secrets" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "events" ];
        verbs = [
          "create"
          "patch"
        ];
      }
    ];
  };

  controllerRoleChallenges = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${name}-controller-challenges";
    labels = controllerLabels;
    extra.rules = [
      {
        apiGroups = [ "" ];
        resources = [ "secrets" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "events" ];
        verbs = [
          "create"
          "patch"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [
          "pods"
          "services"
        ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "delete"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "secrets" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "acme.cert-manager.io" ];
        resources = [
          "challenges"
          "challenges/status"
        ];
        verbs = [
          "update"
          "patch"
        ];
      }
      {
        apiGroups = [ "acme.cert-manager.io" ];
        resources = [ "challenges" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "acme.cert-manager.io" ];
        resources = [ "challenges/finalizers" ];
        verbs = [ "update" ];
      }
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [
          "issuers"
          "clusterissuers"
        ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "gateway.networking.k8s.io" ];
        resources = [ "httproutes" ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "delete"
          "update"
        ];
      }
      {
        apiGroups = [ "networking.k8s.io" ];
        resources = [ "ingresses" ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "delete"
          "update"
        ];
      }
      {
        apiGroups = [ "route.openshift.io" ];
        resources = [ "routes/custom-host" ];
        verbs = [ "create" ];
      }
    ];
  };

  controllerRoleIngressShim = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${name}-controller-ingress-shim";
    labels = controllerLabels;
    extra.rules = [
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [
          "certificates"
          "certificaterequests"
        ];
        verbs = [
          "create"
          "update"
          "delete"
        ];
      }
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [
          "certificates"
          "certificaterequests"
          "issuers"
          "clusterissuers"
        ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "networking.k8s.io" ];
        resources = [ "ingresses" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "networking.k8s.io" ];
        resources = [ "ingresses/finalizers" ];
        verbs = [ "update" ];
      }
      {
        apiGroups = [ "gateway.networking.k8s.io" ];
        resources = [
          "gateways"
          "httproutes"
        ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "gateway.networking.k8s.io" ];
        resources = [
          "gateways/finalizers"
          "httproutes/finalizers"
        ];
        verbs = [ "update" ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "events" ];
        verbs = [
          "create"
          "patch"
        ];
      }
    ];
  };

  controllerRoleApprove = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${name}-controller-approve:cert-manager-io";
    labels = controllerLabels;
    extra.rules = [
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [ "signers" ];
        verbs = [ "approve" ];
        resourceNames = [
          "issuers.cert-manager.io/*"
          "clusterissuers.cert-manager.io/*"
        ];
      }
    ];
  };

  controllerRoleCSR = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${name}-controller-certificatesigningrequests";
    labels = controllerLabels;
    extra.rules = [
      {
        apiGroups = [ "certificates.k8s.io" ];
        resources = [ "certificatesigningrequests" ];
        verbs = [
          "get"
          "list"
          "watch"
          "update"
        ];
      }
      {
        apiGroups = [ "certificates.k8s.io" ];
        resources = [ "certificatesigningrequests/status" ];
        verbs = [
          "update"
          "patch"
        ];
      }
      {
        apiGroups = [ "certificates.k8s.io" ];
        resources = [ "signers" ];
        resourceNames = [
          "issuers.cert-manager.io/*"
          "clusterissuers.cert-manager.io/*"
        ];
        verbs = [ "sign" ];
      }
      {
        apiGroups = [ "authorization.k8s.io" ];
        resources = [ "subjectaccessreviews" ];
        verbs = [ "create" ];
      }
    ];
  };

  # Aggregate roles for kubectl users.
  clusterViewRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${name}-cluster-view";
    labels = controllerLabels // {
      "rbac.authorization.k8s.io/aggregate-to-cluster-reader" = "true";
    };
    extra.rules = [
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [ "clusterissuers" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
    ];
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
    extra.rules = [
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [
          "certificates"
          "certificaterequests"
          "issuers"
        ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "acme.cert-manager.io" ];
        resources = [
          "challenges"
          "orders"
        ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
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
    extra.rules = [
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [
          "certificates"
          "certificaterequests"
          "issuers"
        ];
        verbs = [
          "create"
          "delete"
          "deletecollection"
          "patch"
          "update"
        ];
      }
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [ "certificates/status" ];
        verbs = [ "update" ];
      }
      {
        apiGroups = [ "acme.cert-manager.io" ];
        resources = [
          "challenges"
          "orders"
        ];
        verbs = [
          "create"
          "delete"
          "deletecollection"
          "patch"
          "update"
        ];
      }
    ];
  };

  # -- Controller ClusterRoleBindings --

  controllerBindingIssuers = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${name}-controller-issuers";
    labels = controllerLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.controllerRoleIssuers}";
      };
      subjects = mkControllerSubject self.controllerServiceAccount;
    };
  };

  controllerBindingClusterIssuers = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${name}-controller-clusterissuers";
    labels = controllerLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.controllerRoleClusterIssuers}";
      };
      subjects = mkControllerSubject self.controllerServiceAccount;
    };
  };

  controllerBindingCertificates = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${name}-controller-certificates";
    labels = controllerLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.controllerRoleCertificates}";
      };
      subjects = mkControllerSubject self.controllerServiceAccount;
    };
  };

  controllerBindingOrders = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${name}-controller-orders";
    labels = controllerLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.controllerRoleOrders}";
      };
      subjects = mkControllerSubject self.controllerServiceAccount;
    };
  };

  controllerBindingChallenges = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${name}-controller-challenges";
    labels = controllerLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.controllerRoleChallenges}";
      };
      subjects = mkControllerSubject self.controllerServiceAccount;
    };
  };

  controllerBindingIngressShim = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${name}-controller-ingress-shim";
    labels = controllerLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.controllerRoleIngressShim}";
      };
      subjects = mkControllerSubject self.controllerServiceAccount;
    };
  };

  controllerBindingApprove = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${name}-controller-approve:cert-manager-io";
    labels = controllerLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.controllerRoleApprove}";
      };
      subjects = mkControllerSubject self.controllerServiceAccount;
    };
  };

  controllerBindingCSR = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${name}-controller-certificatesigningrequests";
    labels = controllerLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.controllerRoleCSR}";
      };
      subjects = mkControllerSubject self.controllerServiceAccount;
    };
  };

  # -- Controller leader election (namespace-scoped) --

  controllerLeaderElectionRole = scope.mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "Role";
    name = "${name}:leaderelection";
    labels = controllerLabels;
    extra.rules = [
      {
        apiGroups = [ "coordination.k8s.io" ];
        resources = [ "leases" ];
        resourceNames = [ "cert-manager-controller" ];
        verbs = [
          "get"
          "update"
          "patch"
        ];
      }
      {
        apiGroups = [ "coordination.k8s.io" ];
        resources = [ "leases" ];
        verbs = [ "create" ];
      }
    ];
  };

  controllerLeaderElectionRoleBinding = scope.mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "RoleBinding";
    name = "${name}:leaderelection";
    labels = controllerLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "Role";
        name = "${self.controllerLeaderElectionRole}";
      };
      subjects = mkControllerSubject self.controllerServiceAccount;
    };
  };

  # -- Controller token request role (namespace-scoped) --

  controllerTokenRequestRole = scope.mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "Role";
    name = "${name}-tokenrequest";
    labels = controllerLabels;
    extra.rules = [
      {
        apiGroups = [ "" ];
        resources = [ "serviceaccounts/token" ];
        resourceNames = [ "${self.controllerServiceAccount}" ];
        verbs = [ "create" ];
      }
    ];
  };

  controllerTokenRequestRoleBinding = scope.mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "RoleBinding";
    name = "${name}-${name}-tokenrequest";
    labels = controllerLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "Role";
        name = "${self.controllerTokenRequestRole}";
      };
      subjects = mkControllerSubject self.controllerServiceAccount;
    };
  };

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
      replicas = cfg.replicaCount;
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
          serviceAccountName = "${self.controllerServiceAccount}";
          enableServiceLinks = false;
          securityContext = podSecurityContext;
          containers = [
            ({
              name = "cert-manager-controller";
              image = "${cfg.image.repository}:${cfg.image.tag}";
              imagePullPolicy = cfg.image.pullPolicy;
              args = [
                "--v=2"
                "--cluster-resource-namespace=$(POD_NAMESPACE)"
                "--leader-election-namespace=$(POD_NAMESPACE)"
                "--acme-http01-solver-image=${cfg.acmesolver.image.repository}:${cfg.acmesolver.image.tag}"
              ]
              ++ lib.optional cfg.dns01RecursiveNameserversOnly "--dns01-recursive-nameservers-only"
              ++ lib.optional (
                cfg.dns01RecursiveNameservers != ""
              ) "--dns01-recursive-nameservers=${cfg.dns01RecursiveNameservers}"
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
                  valueFrom.fieldRef.fieldPath = "metadata.namespace";
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
            // lib.optionalAttrs (cfg.resources != null) { resources = cfg.resources; })
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

  # -- Webhook ClusterRole + ClusterRoleBinding --

  webhookClusterRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${name}-webhook:subjectaccessreviews";
    labels = webhookLabels;
    extra.rules = [
      {
        apiGroups = [ "authorization.k8s.io" ];
        resources = [ "subjectaccessreviews" ];
        verbs = [ "create" ];
      }
    ];
  };

  webhookClusterRoleBinding = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${name}-webhook:subjectaccessreviews";
    labels = webhookLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.webhookClusterRole}";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = "${self.webhookServiceAccount}";
          namespace = ns;
        }
      ];
    };
  };

  # -- Webhook dynamic serving role (namespace-scoped) --

  webhookDynamicServingRole = scope.mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "Role";
    name = "${name}-webhook:dynamic-serving";
    labels = webhookLabels;
    extra.rules = [
      {
        apiGroups = [ "" ];
        resources = [ "secrets" ];
        resourceNames = [ "${name}-webhook-ca" ];
        verbs = [
          "get"
          "list"
          "watch"
          "update"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "secrets" ];
        verbs = [ "create" ];
      }
    ];
  };

  webhookDynamicServingRoleBinding = scope.mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "RoleBinding";
    name = "${name}-webhook:dynamic-serving";
    labels = webhookLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "Role";
        name = "${self.webhookDynamicServingRole}";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = "${self.webhookServiceAccount}";
          namespace = ns;
        }
      ];
    };
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
      replicas = cfg.webhook.replicaCount;
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
          serviceAccountName = "${self.webhookServiceAccount}";
          enableServiceLinks = false;
          securityContext = podSecurityContext;
          containers = [
            {
              name = "cert-manager-webhook";
              image = "${cfg.webhook.image.repository}:${cfg.webhook.image.tag}";
              imagePullPolicy = cfg.image.pullPolicy;
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
                  valueFrom.fieldRef.fieldPath = "metadata.namespace";
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
          name = "${self.webhookService}";
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
          name = "${self.webhookService}";
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

  # -- CA Injector ClusterRole --

  cainjectorClusterRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${name}-cainjector";
    labels = cainjectorLabels;
    extra.rules = [
      {
        apiGroups = [ "cert-manager.io" ];
        resources = [ "certificates" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "secrets" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "events" ];
        verbs = [
          "get"
          "create"
          "update"
          "patch"
        ];
      }
      {
        apiGroups = [ "admissionregistration.k8s.io" ];
        resources = [
          "validatingwebhookconfigurations"
          "mutatingwebhookconfigurations"
        ];
        verbs = [
          "get"
          "list"
          "watch"
          "update"
          "patch"
        ];
      }
      {
        apiGroups = [ "apiregistration.k8s.io" ];
        resources = [ "apiservices" ];
        verbs = [
          "get"
          "list"
          "watch"
          "update"
          "patch"
        ];
      }
      {
        apiGroups = [ "apiextensions.k8s.io" ];
        resources = [ "customresourcedefinitions" ];
        verbs = [
          "get"
          "list"
          "watch"
          "update"
          "patch"
        ];
      }
    ];
  };

  cainjectorClusterRoleBinding = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${name}-cainjector";
    labels = cainjectorLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.cainjectorClusterRole}";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = "${self.cainjectorServiceAccount}";
          namespace = ns;
        }
      ];
    };
  };

  # -- CA Injector leader election (namespace-scoped) --

  cainjectorLeaderElectionRole = scope.mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "Role";
    name = "${name}-cainjector:leaderelection";
    labels = cainjectorLabels;
    extra.rules = [
      {
        apiGroups = [ "coordination.k8s.io" ];
        resources = [ "leases" ];
        resourceNames = [
          "cert-manager-cainjector-leader-election"
          "cert-manager-cainjector-leader-election-core"
        ];
        verbs = [
          "get"
          "update"
          "patch"
        ];
      }
      {
        apiGroups = [ "coordination.k8s.io" ];
        resources = [ "leases" ];
        verbs = [ "create" ];
      }
    ];
  };

  cainjectorLeaderElectionRoleBinding = scope.mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "RoleBinding";
    name = "${name}-cainjector:leaderelection";
    labels = cainjectorLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "Role";
        name = "${self.cainjectorLeaderElectionRole}";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = "${self.cainjectorServiceAccount}";
          namespace = ns;
        }
      ];
    };
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
      replicas = cfg.cainjector.replicaCount;
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
          serviceAccountName = "${self.cainjectorServiceAccount}";
          enableServiceLinks = false;
          securityContext = podSecurityContext;
          containers = [
            {
              name = "cert-manager-cainjector";
              image = "${cfg.cainjector.image.repository}:${cfg.cainjector.image.tag}";
              imagePullPolicy = cfg.image.pullPolicy;
              args = [
                "--v=2"
                "--leader-election-namespace=$(POD_NAMESPACE)"
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
                  valueFrom.fieldRef.fieldPath = "metadata.namespace";
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
      (lib.optionals cfg.installCRDs [
        self.crdCertificates
        self.crdCertificateRequests
        self.crdChallenges
        self.crdClusterIssuers
        self.crdIssuers
        self.crdOrders
      ])
      # Controller RBAC
      ++ [
        self.controllerServiceAccount
        self.controllerRoleIssuers
        self.controllerRoleClusterIssuers
        self.controllerRoleCertificates
        self.controllerRoleOrders
        self.controllerRoleChallenges
        self.controllerRoleIngressShim
        self.controllerRoleApprove
        self.controllerRoleCSR
        self.clusterViewRole
        self.viewRole
        self.editRole
        self.controllerBindingIssuers
        self.controllerBindingClusterIssuers
        self.controllerBindingCertificates
        self.controllerBindingOrders
        self.controllerBindingChallenges
        self.controllerBindingIngressShim
        self.controllerBindingApprove
        self.controllerBindingCSR
        self.controllerLeaderElectionRole
        self.controllerLeaderElectionRoleBinding
        self.controllerTokenRequestRole
        self.controllerTokenRequestRoleBinding
        self.controllerService
      ]
      # Webhook
      ++ [
        self.webhookServiceAccount
        self.webhookClusterRole
        self.webhookClusterRoleBinding
        self.webhookDynamicServingRole
        self.webhookDynamicServingRoleBinding
        self.webhookService
        self.webhookDeployment
        self.mutatingWebhookConfiguration
        self.validatingWebhookConfiguration
      ]
      # CA Injector
      ++ [
        self.cainjectorServiceAccount
        self.cainjectorClusterRole
        self.cainjectorClusterRoleBinding
        self.cainjectorLeaderElectionRole
        self.cainjectorLeaderElectionRoleBinding
        self.cainjectorService
        self.cainjectorDeployment
      ];
  };
}

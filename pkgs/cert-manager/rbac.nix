# cert-manager RBAC resources.
#
# Contains: ServiceAccounts, ClusterRoles (incl. aggregated), ClusterRoleBindings,
# namespace-scoped Roles and RoleBindings for all 4 components.
# Uses mkRoleSet for batch generation of roles + bindings.
#
# This is the largest file in the cert-manager package because cert-manager has
# 8 ClusterRoles, 3 aggregated ClusterRoles, and multiple namespace-scoped roles.

{
  lib,
  kixlib,
  kixlib',
  cfg,
  helpers,
  ...
}:

let
  inherit (helpers)
    controllerLabels
    webhookLabels
    cainjectorLabels
    startupapicheckLabels
    ;

  # ============================================================================
  # SERVICE ACCOUNTS
  # ============================================================================

  controllerSa = kixlib'.rbac.mkServiceAccount {
    metadata = {
      name = "cert-manager";
      labels = controllerLabels.all // {
        "app.kubernetes.io/component" = "controller";
      };
    };
    automountServiceAccountToken = cfg.serviceAccount.automountServiceAccountToken;
  };

  webhookSa = kixlib'.rbac.mkServiceAccount {
    metadata = {
      name = "cert-manager-webhook";
      labels = webhookLabels.all;
    };
    automountServiceAccountToken = cfg.serviceAccount.automountServiceAccountToken;
  };

  cainjectorSa = kixlib'.rbac.mkServiceAccount {
    metadata = {
      name = "cert-manager-cainjector";
      labels = cainjectorLabels.all;
    };
    automountServiceAccountToken = cfg.serviceAccount.automountServiceAccountToken;
  };

  startupapicheckSa = kixlib'.rbac.mkServiceAccount {
    metadata = {
      name = "cert-manager-startupapicheck";
      labels = startupapicheckLabels.all;
    };
    automountServiceAccountToken = cfg.serviceAccount.automountServiceAccountToken;
  };

  # ============================================================================
  # CONTROLLER CLUSTER RBAC (8 ClusterRoles + 8 ClusterRoleBindings)
  # ============================================================================

  controllerSubjects = kixlib.rbac.subjects.sa {
    name = "cert-manager";
    namespace = cfg.namespace;
  };

  controllerRbac = kixlib'.rbac.mkRoleSet {
    subjects = controllerSubjects;
    roles = {
      "cert-manager-controller-issuers" = {
        rules = [
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
      "cert-manager-controller-clusterissuers" = {
        rules = [
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
      "cert-manager-controller-certificates" = {
        rules = [
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
      "cert-manager-controller-orders" = {
        rules = [
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
      "cert-manager-controller-challenges" = {
        rules = [
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
            apiGroups = [ "route.openshift.io" ];
            resources = [ "routes/custom-host" ];
            verbs = [ "create" ];
          }
          {
            apiGroups = [ "acme.cert-manager.io" ];
            resources = [ "challenges/finalizers" ];
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
        ];
      };
      "cert-manager-controller-ingress-shim" = {
        rules = [
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
      "cert-manager-controller-approve:cert-manager-io" = {
        metadata.labels = controllerLabels.all // {
          "app.kubernetes.io/component" = "cert-manager";
        };
        rules = [
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
      "cert-manager-controller-certificatesigningrequests" = {
        metadata.labels = controllerLabels.all // {
          "app.kubernetes.io/component" = "cert-manager";
        };
        rules = [
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
            verbs = [ "sign" ];
            resourceNames = [
              "issuers.cert-manager.io/*"
              "clusterissuers.cert-manager.io/*"
            ];
          }
          {
            apiGroups = [ "authorization.k8s.io" ];
            resources = [ "subjectaccessreviews" ];
            verbs = [ "create" ];
          }
        ];
      };
    };
  };

  # ============================================================================
  # AGGREGATED CLUSTER ROLES (no bindings, just roles with aggregation labels)
  # ============================================================================

  aggregatedClusterRoles = {
    cluster-view = kixlib'.rbac.mkClusterRole {
      metadata = {
        name = "cert-manager-cluster-view";
        labels = controllerLabels.all // {
          "rbac.authorization.k8s.io/aggregate-to-cluster-reader" = "true";
        };
      };
      rules = [
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
    view = kixlib'.rbac.mkClusterRole {
      metadata = {
        name = "cert-manager-view";
        labels = controllerLabels.all // {
          "rbac.authorization.k8s.io/aggregate-to-view" = "true";
          "rbac.authorization.k8s.io/aggregate-to-edit" = "true";
          "rbac.authorization.k8s.io/aggregate-to-admin" = "true";
          "rbac.authorization.k8s.io/aggregate-to-cluster-reader" = "true";
        };
      };
      rules = [
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
    edit = kixlib'.rbac.mkClusterRole {
      metadata = {
        name = "cert-manager-edit";
        labels = controllerLabels.all // {
          "rbac.authorization.k8s.io/aggregate-to-edit" = "true";
          "rbac.authorization.k8s.io/aggregate-to-admin" = "true";
        };
      };
      rules = [
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
  };

  # ============================================================================
  # CONTROLLER NAMESPACE-SCOPED RBAC (leader election + tokenrequest)
  # ============================================================================

  controllerNamespacedRbac = kixlib'.rbac.mkRoleSet {
    subjects = controllerSubjects;
    scope = "namespace";
    roles = {
      "cert-manager:leaderelection" = {
        metadata = {
          namespace = cfg.leaderElection.namespace;
          labels = controllerLabels.all // {
            "app.kubernetes.io/component" = "controller";
          };
        };
        rules = [
          {
            apiGroups = [ "coordination.k8s.io" ];
            resources = [ "leases" ];
            verbs = [
              "get"
              "update"
              "patch"
            ];
            resourceNames = [ "cert-manager-controller" ];
          }
          {
            apiGroups = [ "coordination.k8s.io" ];
            resources = [ "leases" ];
            verbs = [ "create" ];
          }
        ];
      };
      "cert-manager-tokenrequest" = {
        metadata.labels = controllerLabels.all // {
          "app.kubernetes.io/component" = "controller";
        };
        rules = [
          {
            apiGroups = [ "" ];
            resources = [ "serviceaccounts/token" ];
            verbs = [ "create" ];
            resourceNames = [ "cert-manager" ];
          }
        ];
      };
    };
  };

  # ============================================================================
  # WEBHOOK RBAC
  # ============================================================================

  webhookSubjects = kixlib.rbac.subjects.sa {
    name = "cert-manager-webhook";
    namespace = cfg.namespace;
  };

  webhookClusterRbac = kixlib'.rbac.mkRoleSet {
    subjects = webhookSubjects;
    metadata.labels = webhookLabels.all;
    roles = {
      "cert-manager-webhook:subjectaccessreviews" = {
        rules = [
          {
            apiGroups = [ "authorization.k8s.io" ];
            resources = [ "subjectaccessreviews" ];
            verbs = [ "create" ];
          }
        ];
      };
    };
  };

  webhookNamespacedRbac = kixlib'.rbac.mkRoleSet {
    subjects = webhookSubjects;
    scope = "namespace";
    metadata.labels = webhookLabels.all;
    roles = {
      "cert-manager-webhook:dynamic-serving" = {
        rules = [
          {
            apiGroups = [ "" ];
            resources = [ "secrets" ];
            verbs = [
              "get"
              "list"
              "watch"
              "update"
            ];
            resourceNames = [ "cert-manager-webhook-ca" ];
          }
          {
            apiGroups = [ "" ];
            resources = [ "secrets" ];
            verbs = [ "create" ];
          }
        ];
      };
    };
  };

  # ============================================================================
  # CAINJECTOR RBAC
  # ============================================================================

  cainjectorSubjects = kixlib.rbac.subjects.sa {
    name = "cert-manager-cainjector";
    namespace = cfg.namespace;
  };

  cainjectorClusterRbac = kixlib'.rbac.mkRoleSet {
    subjects = cainjectorSubjects;
    metadata.labels = cainjectorLabels.all;
    roles = {
      "cert-manager-cainjector" = {
        rules = [
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
    };
  };

  cainjectorNamespacedRbac = kixlib'.rbac.mkRoleSet {
    subjects = cainjectorSubjects;
    scope = "namespace";
    metadata.labels = cainjectorLabels.all;
    roles = {
      "cert-manager-cainjector:leaderelection" = {
        metadata.namespace = cfg.leaderElection.namespace;
        rules = [
          {
            apiGroups = [ "coordination.k8s.io" ];
            resources = [ "leases" ];
            verbs = [
              "get"
              "update"
              "patch"
            ];
            resourceNames = [
              "cert-manager-cainjector-leader-election"
              "cert-manager-cainjector-leader-election-core"
            ];
          }
          {
            apiGroups = [ "coordination.k8s.io" ];
            resources = [ "leases" ];
            verbs = [ "create" ];
          }
        ];
      };
    };
  };

  # ============================================================================
  # STARTUP API CHECK RBAC
  # ============================================================================

  startupapicheckRbac = kixlib'.rbac.mkRoleSet {
    subjects = kixlib.rbac.subjects.sa {
      name = "cert-manager-startupapicheck";
      namespace = cfg.namespace;
    };
    scope = "namespace";
    metadata.labels = startupapicheckLabels.all;
    roles = {
      "cert-manager-startupapicheck:create-cert" = {
        rules = [
          {
            apiGroups = [ "cert-manager.io" ];
            resources = [ "certificaterequests" ];
            verbs = [ "create" ];
          }
        ];
      };
    };
  };

in
{
  inherit
    controllerSa
    webhookSa
    cainjectorSa
    startupapicheckSa
    controllerRbac
    aggregatedClusterRoles
    controllerNamespacedRbac
    webhookClusterRbac
    webhookNamespacedRbac
    cainjectorClusterRbac
    cainjectorNamespacedRbac
    startupapicheckRbac
    ;
}

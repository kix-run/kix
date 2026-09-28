# Tailscale operator package.
#
# Deploys the Tailscale Kubernetes operator with cluster-wide and
# namespace-scoped RBAC, an IngressClass, ProxyClasses, and Connectors.
#
# Resources: ServiceAccount (operator + proxies), Role + RoleBinding (operator + proxies),
#            ClusterRole, ClusterRoleBinding, Deployment, IngressClass,
#            ProxyClass (cluster-scoped), Connector (cluster-scoped).

{
  scope,
  lib,
  kix,
  availability,
}:

let
  name = scope.instanceName;

  # Each Tailscale release tags the operator and proxy images alike. Both
  # declared tags come from this binding, so the proxy keeps its declared
  # tag until the instance moves `operatorImage.tag`.
  release = "v1.82.0";

  selectorLabels = {
    "app.kubernetes.io/name" = "tailscale";
    "app.kubernetes.io/instance" = name;
  };

in
{
  meta = {
    version = "1.0.0";
    description = "Tailscale Kubernetes operator with an IngressClass, plus any ProxyClasses and Connectors you configure";
    owner = "platform";
    # The operator is a single-leader controller with no leader
    # election, so only one replica may run at a time.
    availability.max = "none";
  };

  options = {
    # --- Images ---
    operatorImage = kix.options.image {
      repository = "tailscale/k8s-operator";
      tag = release;
      pullPolicy = "Always";
      description = "Image for the operator Deployment.";
    };

    proxyImage = kix.options.image {
      repository = "tailscale/tailscale";
      tag = release;
      tagText = "config.operatorImage.tag";
      pullPolicy = null;
      description = "Image the operator runs in the proxy pods it creates, passed as PROXY_IMAGE. `pullPolicy` is not passed to the operator.";
    };

    # --- Deployment ---
    replicaCount = lib.mkOption {
      type = lib.types.int;
      # Pinned to one at every level: see meta.availability.max.
      default = kix.availability.pick availability {
        none = 1;
        pod = 1;
        node = 1;
        zone = 1;
      };
      description = ''
        Number of Tailscale operator replicas. Pinned to one at every
        availability level (v2_discussions/145) because the operator has
        no leader election.
      '';
    };

    # The tailscale-operator chart (1.82.0) sets no resources. The requests
    # are a judgement for one idle controller; without them Kubernetes
    # would copy the limits into the requests.
    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
        requests = {
          cpu = "100m";
          memory = "128Mi";
        };
        limits = {
          cpu = "2";
          memory = "1Gi";
        };
      };
    };

    # --- Operator env vars (cluster-specific) ---
    operatorHostname = lib.mkOption {
      type = lib.types.str;
      default = "tailscale-operator";
    };

    operatorInitialTags = lib.mkOption {
      type = lib.types.str;
      default = "tag:k8s-operator";
    };

    operatorLogging = lib.mkOption {
      type = lib.types.str;
      default = "info";
    };

    proxyTags = lib.mkOption {
      type = lib.types.str;
      default = "tag:k8s";
    };

    proxyDefaultClass = lib.mkOption {
      type = lib.types.str;
      default = "default";
    };

    proxyFirewallMode = lib.mkOption {
      type = lib.types.str;
      default = "auto";
    };

    oauthSecretName = lib.mkOption {
      type = lib.types.str;
      default = "operator-oauth";
    };

    # --- IngressClass ---
    ingressClassController = lib.mkOption {
      type = lib.types.str;
      default = "tailscale.com/ts-ingress";
    };

    # --- ClusterRole rules ---
    clusterRoleRules = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [
        {
          apiGroups = [ "" ];
          resources = [
            "events"
            "services"
            "services/status"
          ];
          verbs = [
            "create"
            "delete"
            "deletecollection"
            "get"
            "list"
            "patch"
            "update"
            "watch"
          ];
        }
        {
          apiGroups = [ "apiextensions.k8s.io" ];
          resourceNames = [ "servicemonitors.monitoring.coreos.com" ];
          resources = [ "customresourcedefinitions" ];
          verbs = [
            "get"
            "list"
            "watch"
          ];
        }
        {
          apiGroups = [ "networking.k8s.io" ];
          resources = [
            "ingresses"
            "ingresses/status"
          ];
          verbs = [
            "create"
            "delete"
            "deletecollection"
            "get"
            "list"
            "patch"
            "update"
            "watch"
          ];
        }
        {
          apiGroups = [ "networking.k8s.io" ];
          resources = [ "ingressclasses" ];
          verbs = [
            "get"
            "list"
            "watch"
          ];
        }
        {
          apiGroups = [ "tailscale.com" ];
          resources = [
            "connectors"
            "connectors/status"
            "proxyclasses"
            "proxyclasses/status"
            "proxygroups"
            "proxygroups/status"
          ];
          verbs = [
            "get"
            "list"
            "watch"
            "update"
          ];
        }
        {
          apiGroups = [ "tailscale.com" ];
          resources = [
            "dnsconfigs"
            "dnsconfigs/status"
          ];
          verbs = [
            "get"
            "list"
            "watch"
            "update"
          ];
        }
        {
          apiGroups = [ "tailscale.com" ];
          resources = [
            "recorders"
            "recorders/status"
          ];
          verbs = [
            "get"
            "list"
            "watch"
            "update"
          ];
        }
      ];
    };

    # --- Namespace-scoped operator Role rules ---
    operatorRoleRules = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [
        {
          apiGroups = [ "" ];
          resources = [
            "secrets"
            "serviceaccounts"
            "configmaps"
          ];
          verbs = [
            "create"
            "delete"
            "deletecollection"
            "get"
            "list"
            "patch"
            "update"
            "watch"
          ];
        }
        {
          apiGroups = [ "" ];
          resources = [ "pods" ];
          verbs = [
            "get"
            "list"
            "watch"
            "update"
          ];
        }
        {
          apiGroups = [ "" ];
          resources = [ "pods/status" ];
          verbs = [ "update" ];
        }
        {
          apiGroups = [ "apps" ];
          resources = [
            "statefulsets"
            "deployments"
          ];
          verbs = [
            "create"
            "delete"
            "deletecollection"
            "get"
            "list"
            "patch"
            "update"
            "watch"
          ];
        }
        {
          apiGroups = [ "discovery.k8s.io" ];
          resources = [ "endpointslices" ];
          verbs = [
            "get"
            "list"
            "watch"
            "create"
            "update"
            "deletecollection"
          ];
        }
        {
          apiGroups = [ "monitoring.coreos.com" ];
          resources = [ "servicemonitors" ];
          verbs = [
            "get"
            "list"
            "update"
            "create"
            "delete"
          ];
        }
        {
          apiGroups = [ "rbac.authorization.k8s.io" ];
          resources = [
            "roles"
            "rolebindings"
          ];
          verbs = [
            "get"
            "create"
            "patch"
            "update"
            "list"
            "watch"
            "deletecollection"
          ];
        }
      ];
    };

    # --- Proxies Role rules ---
    proxiesRoleRules = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [
        {
          apiGroups = [ "" ];
          resources = [ "secrets" ];
          verbs = [
            "create"
            "delete"
            "deletecollection"
            "get"
            "list"
            "patch"
            "update"
            "watch"
          ];
        }
        {
          apiGroups = [ "" ];
          resources = [ "events" ];
          verbs = [
            "create"
            "patch"
            "get"
          ];
        }
      ];
    };

    # --- ProxyClasses (cluster-scoped CRs) ---
    proxyClasses = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "ProxyClass resources to create. Keys are resource names, values are specs.";
    };

    # --- Connectors (cluster-scoped CRs) ---
    connectors = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Connector resources to create. Keys are resource names, values are specs.";
    };
  };

  # The proxy's tag follows `operatorImage.tag` unless the instance sets it.
  config =
    { config, ... }:
    {
      proxyImage.tag = lib.mkDefault config.operatorImage.tag;
    };

  build =
    {
      self,
      config,
      clusterConfig,
    }:
    let
      # --- ProxyClass resources ---
      proxyClassResources = lib.mapAttrs (
        pcName: pcSpec:
        scope.mkClusterResource {
          apiVersion = "tailscale.com/v1alpha1";
          kind = "ProxyClass";
          name = pcName;
          labels = selectorLabels;
          spec = pcSpec;
        }
      ) config.proxyClasses;

      # --- Connector resources ---
      connectorResources = lib.mapAttrs (
        cName: cSpec:
        scope.mkClusterResource {
          apiVersion = "tailscale.com/v1alpha1";
          kind = "Connector";
          name = cName;
          labels = selectorLabels;
          spec = cSpec;
        }
      ) config.connectors;

    in
    {

      # --- OAuth secret reference ---
      # User-provided external Secret holding the operator OAuth client.
      # Wrapping it in a SecretRef makes the volume mount DI-tracked and
      # gates deployment on the secret existing.
      oauthSecret = scope.mkSecretRef {
        name = config.oauthSecretName;
        keys = [ ];
      };

      # --- Operator ServiceAccount ---
      operatorServiceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "operator";
        labels = selectorLabels;
      };

      # --- Proxies ServiceAccount ---
      proxiesServiceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "proxies";
        labels = selectorLabels;
      };

      # --- ClusterRole (operator-wide permissions) ---
      clusterRole = scope.mkClusterResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "${name}-operator";
        labels = selectorLabels;
        extra.rules = config.clusterRoleRules;
      };

      # --- ClusterRoleBinding ---
      clusterRoleBinding = scope.mkClusterResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        name = "${name}-operator";
        labels = selectorLabels;
        extra = {
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "ClusterRole";
            name = self.clusterRole.out.name;
          };
          subjects = [
            {
              kind = "ServiceAccount";
              name = self.operatorServiceAccount.out.name;
              namespace = scope.namespaceName;
            }
          ];
        };
      };

      # --- Operator Role (namespace-scoped) ---
      operatorRole = scope.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "Role";
        name = "operator";
        labels = selectorLabels;
        extra.rules = config.operatorRoleRules;
      };

      # --- Operator RoleBinding ---
      operatorRoleBinding = scope.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "RoleBinding";
        name = "operator";
        labels = selectorLabels;
        extra = {
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "Role";
            name = self.operatorRole.out.name;
          };
          subjects = [
            {
              kind = "ServiceAccount";
              name = self.operatorServiceAccount.out.name;
              namespace = scope.namespaceName;
            }
          ];
        };
      };

      # --- Proxies Role (namespace-scoped) ---
      proxiesRole = scope.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "Role";
        name = "proxies";
        labels = selectorLabels;
        extra.rules = config.proxiesRoleRules;
      };

      # --- Proxies RoleBinding ---
      proxiesRoleBinding = scope.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "RoleBinding";
        name = "proxies";
        labels = selectorLabels;
        extra = {
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "Role";
            name = self.proxiesRole.out.name;
          };
          subjects = [
            {
              kind = "ServiceAccount";
              name = self.proxiesServiceAccount.out.name;
              namespace = scope.namespaceName;
            }
          ];
        };
      };

      # --- Operator Deployment ---
      deployment =
        {
          name = "operator";
          labels = selectorLabels;
          spec = {
            replicas = config.replicaCount;
            selector.matchLabels = {
              app = "operator";
            };
            strategy.type = "Recreate";
            template.spec = {
              serviceAccountName = self.operatorServiceAccount.out.name;
              # Kubernetes' default, set explicitly; the chart sets none.
              terminationGracePeriodSeconds = 30;
              nodeSelector = {
                "kubernetes.io/os" = "linux";
              };
              containers = [
                {
                  name = "operator";
                  image = kix.image.ref config.operatorImage;
                  imagePullPolicy = config.operatorImage.pullPolicy;
                  env = [
                    {
                      name = "APISERVER_PROXY";
                      value = "false";
                    }
                    {
                      name = "CLIENT_ID_FILE";
                      value = "/oauth/client_id";
                    }
                    {
                      name = "CLIENT_SECRET_FILE";
                      value = "/oauth/client_secret";
                    }
                    {
                      name = "OPERATOR_HOSTNAME";
                      value = config.operatorHostname;
                    }
                    {
                      name = "OPERATOR_INITIAL_TAGS";
                      value = config.operatorInitialTags;
                    }
                    {
                      name = "OPERATOR_LOGGING";
                      value = config.operatorLogging;
                    }
                    {
                      name = "OPERATOR_NAMESPACE";
                      valueFrom.fieldRef = {
                        apiVersion = "v1";
                        fieldPath = "metadata.namespace";
                      };
                    }
                    {
                      name = "OPERATOR_SECRET";
                      value = "operator";
                    }
                    {
                      name = "POD_NAME";
                      valueFrom.fieldRef = {
                        apiVersion = "v1";
                        fieldPath = "metadata.name";
                      };
                    }
                    {
                      name = "POD_UID";
                      valueFrom.fieldRef = {
                        apiVersion = "v1";
                        fieldPath = "metadata.uid";
                      };
                    }
                    {
                      name = "PROXY_DEFAULT_CLASS";
                      value = config.proxyDefaultClass;
                    }
                    {
                      name = "PROXY_FIREWALL_MODE";
                      value = config.proxyFirewallMode;
                    }
                    {
                      name = "PROXY_IMAGE";
                      value = kix.image.ref config.proxyImage;
                    }
                    {
                      name = "PROXY_TAGS";
                      value = config.proxyTags;
                    }
                  ];
                  resources = config.resources;
                  volumeMounts = [
                    {
                      mountPath = "/oauth";
                      name = "oauth";
                      readOnly = true;
                    }
                  ];
                }
              ];
              volumes = [
                {
                  name = "oauth";
                  secret = {
                    defaultMode = 420;
                    secretName = self.oauthSecret.out.name;
                  };
                }
              ];
            };
          };
        }
        |> scope.mkDeployment;

      # --- IngressClass (cluster-scoped) ---
      ingressClass = scope.mkClusterResource {
        apiVersion = "networking.k8s.io/v1";
        kind = "IngressClass";
        name = name;
        labels = selectorLabels;
        spec = {
          controller = config.ingressClassController;
        };
      };

      # --- Entry point ---
      root = {
        resource = self.deployment;
        requires = [
          self.clusterRole
          self.clusterRoleBinding
          self.ingressClass
          self.proxiesServiceAccount
          self.proxiesRole
          self.proxiesRoleBinding
        ]
        ++ builtins.attrValues proxyClassResources
        ++ builtins.attrValues connectorResources;
      };
    }
    // proxyClassResources
    // connectorResources;
}

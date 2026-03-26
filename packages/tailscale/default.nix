# Tailscale operator package.
#
# Deploys the Tailscale Kubernetes operator with cluster-wide RBAC
# and an IngressClass for Tailscale-based ingress.
#
# Resources: ClusterRole, ClusterRoleBinding, IngressClass.
#
# main = IngressClass (root resource; depends on RBAC)

{
  scope,
  lib,
}:

let
  name = scope.instanceName;

  selectorLabels = {
    "app.kubernetes.io/name" = "tailscale";
    "app.kubernetes.io/instance" = name;
  };

in
{
  meta = {
    version = "1.0.0";
  };

  options = {
    # Name of the ServiceAccount the operator runs as (typically created
    # by the operator's own deployment manifests, not managed here).
    operatorServiceAccountName = lib.mkOption {
      type = lib.types.str;
      default = "operator";
    };

    # IngressClass controller identifier.
    ingressClassController = lib.mkOption {
      type = lib.types.str;
      default = "tailscale.com/ts-ingress";
    };

    # ClusterRole rules for the operator.  Sensible defaults cover the
    # typical Tailscale operator needs; override per-cluster if required.
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
  };

  build =
    {
      self,
      config,
      clusterConfig,
    }:
    {

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
              name = config.operatorServiceAccountName;
              namespace = scope.namespaceName;
            }
          ];
        };
      };

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
      main = {
        resource = self.ingressClass;
        requires = [
          self.clusterRole
          self.clusterRoleBinding
        ];
      };
    };
}

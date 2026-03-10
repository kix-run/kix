# CoreDNS RBAC resources.
#
# Contains: ServiceAccounts, ClusterRoles, ClusterRoleBindings for both
# the main CoreDNS deployment and the cluster-proportional autoscaler.

{
  lib,
  config,
  kixlib,
  cfg,
  helpers,
  ...
}:

let
  inherit (helpers) kixlibCoredns;

  # --- Main CoreDNS RBAC ---

  sa = kixlibCoredns.rbac.mkServiceAccount { };

  clusterRole = kixlibCoredns.rbac.mkClusterRole {
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

  serviceAccountName = if cfg.serviceAccount.create then kixlibCoredns.resourceName sa else "default";

  binding = kixlibCoredns.rbac.mkClusterRoleBindingWith {
    inherit clusterRole;
    serviceAccount = sa;
    subjects = [
      {
        kind = "ServiceAccount";
        name = serviceAccountName;
        namespace = cfg.namespace;
      }
    ];
  };

  # --- Autoscaler RBAC ---

  autoscalerName = "coredns-autoscaler";

  autoscalerLabelSet = kixlib.mkLabels {
    chart = autoscalerName;
    clusterLabels = config.cluster.labels;
    extra = lib.optionalAttrs cfg.isClusterService {
      "kubernetes.io/cluster-service" = "true";
      "kubernetes.io/name" = "CoreDNS";
    };
  };

  autoscalerSelectorLabels = autoscalerLabelSet.selector // {
    "k8s-app" = autoscalerName;
  };

  autoscalerLabels = autoscalerLabelSet.all // {
    "k8s-app" = autoscalerName;
  };

  autoscalerKixlib = kixlib.withMetadata {
    namespace = cfg.namespace;
    labels = autoscalerLabels;
    name = autoscalerName;
  };

  autoscalerSa = autoscalerKixlib.rbac.mkServiceAccount { };

  autoscalerClusterRole = autoscalerKixlib.rbac.mkClusterRole {
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

  autoscalerBinding = autoscalerKixlib.rbac.mkClusterRoleBinding autoscalerClusterRole autoscalerSa;

in
{
  inherit
    sa
    clusterRole
    binding
    serviceAccountName
    autoscalerKixlib
    autoscalerSa
    autoscalerClusterRole
    autoscalerBinding
    autoscalerSelectorLabels
    autoscalerLabels
    autoscalerName
    ;

  # Ready-made manifest list entries for the main RBAC resources.
  manifestList = [
    {
      name = "coredns-clusterrole";
      resource = clusterRole;
      enable = true;
    }
    {
      name = "coredns-clusterrolebinding";
      resource = binding;
      enable = true;
    }
    {
      name = "coredns-serviceaccount";
      resource = sa;
      enable = cfg.serviceAccount.create;
    }
  ];

  # Ready-made manifest list entries for the autoscaler RBAC resources.
  autoscalerManifestList = [
    {
      name = "coredns-autoscaler-serviceaccount";
      resource = autoscalerSa;
      enable = cfg.autoscaler.enabled;
      kixlib = autoscalerKixlib;
    }
    {
      name = "coredns-autoscaler-clusterrole";
      resource = autoscalerClusterRole;
      enable = cfg.autoscaler.enabled;
      kixlib = autoscalerKixlib;
    }
    {
      name = "coredns-autoscaler-clusterrolebinding";
      resource = autoscalerBinding;
      enable = cfg.autoscaler.enabled;
      kixlib = autoscalerKixlib;
    }
  ];
}

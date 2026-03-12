# CoreDNS RBAC resources.
#
# Contains: ServiceAccounts, ClusterRoles, ClusterRoleBindings for both
# the main CoreDNS deployment and the cluster-proportional autoscaler.
#
# Uses kixlib.rbac.dsl for intent-based verb construction and mkRoleSet
# for batch role + binding generation (same pattern as cert-manager).

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
  inherit (kixlib.rbac.dsl) rule grant allow;

  # --- Main CoreDNS RBAC ---

  sa = kixlibCoredns.rbac.mkServiceAccount { };

  serviceAccountName = if cfg.serviceAccount.create then kixlibCoredns.resourceName sa else "default";

  # mkRoleSet creates the ClusterRole + ClusterRoleBinding in one call.
  # The explicit subjects handle the conditional serviceAccountName (which
  # falls back to "default" when serviceAccount.create is false).
  mainRbac = kixlibCoredns.rbac.mkRoleSet {
    subjects = [
      {
        kind = "ServiceAccount";
        name = serviceAccountName;
        namespace = cfg.namespace;
      }
    ];
    roles = {
      # CoreDNS only needs list+watch (no get) for DNS service discovery.
      # Using `allow` rather than `watch` (which includes get) for exact parity
      # with the upstream Helm chart.
      "coredns" = grant [
        (
          rule [ "" ] [ "endpoints" "services" "pods" "namespaces" ]
          |> allow [
            "list"
            "watch"
          ]
        )
        (
          rule [ "discovery.k8s.io" ] [ "endpointslices" ]
          |> allow [
            "list"
            "watch"
          ]
        )
      ];
    };
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

  # Autoscaler needs non-standard verb combos (get+update, get+create),
  # so we use `allow` escape hatch instead of intent verbs.
  autoscalerRbac = autoscalerKixlib.rbac.mkRoleSet {
    subjects = [
      {
        kind = "ServiceAccount";
        name = autoscalerName;
        namespace = cfg.namespace;
      }
    ];
    roles = {
      "coredns-autoscaler" = grant [
        (rule [ "" ] [ "nodes" ] |> watch)
        (
          rule [ "" ] [ "replicationcontrollers/scale" ]
          |> allow [
            "get"
            "update"
          ]
        )
        (
          rule [ "extensions" "apps" ] [ "deployments/scale" "replicasets/scale" ]
          |> allow [
            "get"
            "update"
          ]
        )
        (
          rule [ "" ] [ "configmaps" ]
          |> allow [
            "get"
            "create"
          ]
        )
      ];
    };
  };

in
{
  inherit
    sa
    serviceAccountName
    autoscalerKixlib
    autoscalerSa
    autoscalerSelectorLabels
    autoscalerLabels
    autoscalerName
    ;

  # Ready-made manifest list entries for the main RBAC resources.
  # mkRoleSet generates role + binding entries; SA is added separately
  # because mkRoleSet only handles roles/bindings, not ServiceAccounts.
  manifestList = mainRbac.toManifestList true ++ [
    {
      name = "coredns-serviceaccount";
      resource = sa;
      enable = cfg.serviceAccount.create;
    }
  ];

  # Ready-made manifest list entries for the autoscaler RBAC resources.
  autoscalerManifestList = autoscalerRbac.toManifestList cfg.autoscaler.enabled ++ [
    {
      name = "coredns-autoscaler-serviceaccount";
      resource = autoscalerSa;
      enable = cfg.autoscaler.enabled;
      kixlib = autoscalerKixlib;
    }
  ];
}

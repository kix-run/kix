# RBAC rules of the Tailscale operator and its proxies, from
# cmd/k8s-operator/deploy/chart/templates/operator-rbac.yaml and
# proxy-rbac.yaml at the release in default.nix, with upstream's verbs.
#
# Left out: `serviceaccounts/token` create on the operator's own
# ServiceAccount. The operator mints that token only for a Tailnet that
# authenticates with workload identity federation, which the package does
# not support.
#
# Returns `grant` lists for `scope.rbac.mkClusterRoleSet` and `mkRoleSet`.

{ rbac }:

let
  inherit (rbac)
    group
    core
    grant
    allow
    restrictTo
    watch
    ;

  # Upstream's verb list for objects the operator owns outright.
  manage = allow [
    "create"
    "delete"
    "deletecollection"
    "get"
    "list"
    "patch"
    "update"
    "watch"
  ];
  reconcile = allow [
    "get"
    "list"
    "watch"
    "update"
  ];

  admission = group "admissionregistration.k8s.io" [
    "validatingadmissionpolicies"
    "validatingadmissionpolicybindings"
  ];
  apiextensions = group "apiextensions.k8s.io" [ "customresourcedefinitions" ];
  apps = group "apps" [
    "deployments"
    "statefulsets"
  ];
  discovery = group "discovery.k8s.io" [ "endpointslices" ];
  monitoring = group "monitoring.coreos.com" [ "servicemonitors" ];
  networking = group "networking.k8s.io" [
    "ingressclasses"
    "ingresses"
  ];
  rbacGroup = group "rbac.authorization.k8s.io" [
    "rolebindings"
    "roles"
  ];
  tailscale = group "tailscale.com" [ ];

  # Every tailscale.com kind the operator reconciles, with its status.
  tailscaleKinds =
    builtins.concatMap
      (plural: [
        (tailscale plural)
        (tailscale "${plural}/status")
      ])
      [
        "connectors"
        "dnsconfigs"
        "peerrelays"
        "proxyclasses"
        "proxygrouppolicies"
        "proxygroups"
        "recorders"
        "tailnets"
      ];
in
{
  # ClusterRole of the operator.
  cluster = grant [
    (core.nodes |> watch)
    (
      [
        core.events
        core.services
        (core "services/status")
      ]
      |> manage
    )
    (
      [
        networking.ingresses
        (networking "ingresses/status")
      ]
      |> manage
    )
    (networking.ingressclasses |> watch)
    (discovery.endpointslices |> watch)
    (tailscaleKinds |> reconcile)
    # The operator watches this one CRD to notice when ServiceMonitor
    # becomes available.
    (
      apiextensions.customresourcedefinitions
      |> restrictTo [ "servicemonitors.monitoring.coreos.com" ]
      |> watch
    )
    # The ProxyGroupPolicy reconciler writes ValidatingAdmissionPolicies.
    (
      [
        admission.validatingadmissionpolicies
        admission.validatingadmissionpolicybindings
      ]
      |> allow [
        "list"
        "create"
        "delete"
        "update"
        "get"
        "watch"
      ]
    )
  ];

  # Role of the operator in its own namespace, where it creates the proxies.
  operator = grant [
    (
      [
        core.secrets
        core.serviceaccounts
        core.configmaps
      ]
      |> manage
    )
    (core.pods |> reconcile)
    ((core "pods/status") |> allow [ "update" ])
    (
      [
        apps.statefulsets
        apps.deployments
      ]
      |> manage
    )
    (
      discovery.endpointslices
      |> allow [
        "get"
        "list"
        "watch"
        "create"
        "update"
        "deletecollection"
      ]
    )
    (
      [
        rbacGroup.roles
        rbacGroup.rolebindings
      ]
      |> allow [
        "get"
        "create"
        "patch"
        "update"
        "list"
        "watch"
        "deletecollection"
      ]
    )
    (
      monitoring.servicemonitors
      |> allow [
        "get"
        "list"
        "update"
        "create"
        "delete"
      ]
    )
  ];

  # Role of the `proxies` ServiceAccount, which the per-Service proxies run
  # as. They keep their tailnet state in Secrets and record events.
  proxies = grant [
    (core.secrets |> manage)
    (
      core.events
      |> allow [
        "create"
        "patch"
        "get"
      ]
    )
  ];
}

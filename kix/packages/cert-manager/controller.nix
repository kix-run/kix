# cert-manager controller — main reconciliation loop for Certificate/Issuer CRDs.

{
  self,
  config,
  clusterConfig,
  scope,
  lib,
  kix,
}:
let
  common = import ./common.nix { instanceName = scope.instanceName; };
  name = scope.instanceName;
  ns = scope.namespaceName;

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
  ocp = group "route.openshift.io" [ ];

  mkControllerSubject = sa: [
    {
      kind = "ServiceAccount";
      name = sa.out.name;
      namespace = ns;
    }
  ];

  # ── Controller cluster-scoped RBAC ─────────────────────────────────

  controllerClusterRoles = mkClusterRoleSet scope {
    subjects = mkControllerSubject self.controllerServiceAccount;
    labels = common.controllerLabels;
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
        # orders + challenges: get, list, watch (grant merges same apiGroup+verbs)
        (
          [
            acme.orders
            acme.challenges
          ]
          |> watch
        )
        # orders, orders/status: update, patch (grant merges same apiGroup+verbs)
        (
          acme.orders
          |> allow [
            "update"
            "patch"
          ]
        )
        (
          (acme "orders/status")
          |> allow [
            "update"
            "patch"
          ]
        )
        # challenges: create, delete
        (
          acme.challenges
          |> allow [
            "create"
            "delete"
          ]
        )
        # orders/finalizers: update
        (acme.orders |> finalize)
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
    labels = common.controllerLabels;
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
    labels = common.controllerLabels;
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

in
{
  # -- ServiceAccount --

  controllerServiceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${name}";
    labels = common.controllerLabels;
    extra.automountServiceAccountToken = true;
  };

  # -- Aggregate roles (no binding — RBAC aggregation labels) --

  clusterViewRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${name}-cluster-view";
    labels = common.controllerLabels // {
      "rbac.authorization.k8s.io/aggregate-to-cluster-reader" = "true";
    };
    extra.rules = grant [ (cm.clusterissuers |> watch) ];
  };

  viewRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${name}-view";
    labels = common.controllerLabels // {
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
    labels = common.controllerLabels // {
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

  # -- Service --

  controllerService = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${name}";
    labels = common.controllerLabels;
    spec = {
      type = "ClusterIP";
      selector = self.controllerDeployment.out.selector;
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

  # -- Deployment --

  controllerDeployment =
    {
      name = "${name}";
      labels = common.controllerLabels;
      spec = {
        replicas = config.replicaCount;
        selector.matchLabels = common.controllerLabels;
        template = {
          metadata.annotations = {
            "prometheus.io/path" = "/metrics";
            "prometheus.io/scrape" = "true";
            "prometheus.io/port" = "9402";
          };
          spec = {
            serviceAccountName = self.controllerServiceAccount.out.name;
            # Kubernetes' default, set explicitly; the chart (v1.17.1) sets none.
            terminationGracePeriodSeconds = 30;
            enableServiceLinks = false;
            securityContext = common.podSecurityContext;
            containers = [
              ({
                name = "cert-manager-controller";
                image = kix.image.ref config.image;
                imagePullPolicy = config.image.pullPolicy;
                args = [
                  "--v=2"
                  "--cluster-resource-namespace=$(POD_NAMESPACE)"
                  "--acme-http01-solver-image=${kix.image.ref config.acmesolver.image}"
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
                securityContext = common.containerSecurityContext;
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
                inherit (config) resources;
              })
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
// controllerClusterRoles
// controllerLeaderElection
// controllerTokenRequest

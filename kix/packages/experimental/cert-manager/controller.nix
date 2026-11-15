# cert-manager controller: reconciles Certificates, Issuers, ACME Orders, and
# Challenges, and creates Certificates for annotated Ingresses and Gateways
# (ingress-shim).

{
  self,
  config,
  scope,
  lib,
  kix,
  availability,
  prometheus ? null,
  ...
}:
let
  common = import ./common.nix { inherit lib; };
  labels = (common.labels name).controller;
  name = scope.instanceName;
  ns = scope.namespaceName;
  who = common.who scope;
  metricsOn = config.metrics.enabled && prometheus != null;
  acmesolverImage = kix.image.ref (
    common.checkRelease who config [
      "operandImages"
      "acmesolver"
    ]
  );

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
    "listenersets"
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

  controllerClusterRoles = mkClusterRoleSet scope {
    subjects = mkControllerSubject self.controllerServiceAccount;
    inherit labels;
    roles = {

      "${name}-controller-issuers" = grant [
        (reconcile cm.issuers)
        (readWrite core.secrets)
        (emit core.events)
      ];

      "${name}-controller-clusterissuers" = grant [
        (reconcile cm.clusterissuers)
        (readWrite core.secrets)
        (emit core.events)
      ];

      "${name}-controller-certificates" = grant [
        (reconcile cm.certificates)
        (reconcile cm.certificaterequests)
        (finalize cm.certificates)
        (finalize cm.certificaterequests)
        (watch cm.clusterissuers)
        (watch cm.issuers)
        (own acme.orders)
        (full core.secrets)
        (emit core.events)
      ];

      "${name}-controller-orders" = grant [
        (watch [
          acme.orders
          acme.challenges
        ])
        (allow [
          "update"
          "patch"
        ] acme.orders)
        (allow [
          "update"
          "patch"
        ] (acme "orders/status"))
        (allow [
          "create"
          "delete"
        ] acme.challenges)
        (finalize acme.orders)
        (finalize cm.clusterissuers)
        (finalize cm.issuers)
        (watch cm.clusterissuers)
        (watch cm.issuers)
        (watch core.secrets)
        (emit core.events)
      ];

      "${name}-controller-challenges" = grant [
        (reconcile acme.challenges)
        (finalize acme.challenges)
        (watch cm.issuers)
        (watch cm.clusterissuers)
        (watch core.secrets)
        (emit core.events)
        (own core.pods)
        (own core.services)
        (readWrite net.ingresses)
        (readWrite gw.httproutes)
        (allow [ "create" ] (ocp "routes/custom-host"))
      ];

      "${name}-controller-ingress-shim" = grant [
        (allow [
          "create"
          "update"
          "delete"
        ] cm.certificates)
        (allow [
          "create"
          "update"
          "delete"
        ] cm.certificaterequests)
        (watch cm.certificates)
        (watch cm.certificaterequests)
        (watch cm.issuers)
        (watch cm.clusterissuers)
        (watchAndFinalize net.ingresses)
        (watchAndFinalize gw.gateways)
        (watchAndFinalize gw.httproutes)
        (watchAndFinalize gw.listenersets)
        (emit core.events)
      ];

      "${name}-controller-approve:cert-manager-io" = grant [
        (lib.pipe cm.signers [
          (restrictTo [
            "issuers.cert-manager.io/*"
            "clusterissuers.cert-manager.io/*"
          ])
          (allow [ "approve" ])
        ])
      ];

      "${name}-controller-certificatesigningrequests" = grant [
        (allow [
          "get"
          "list"
          "watch"
          "update"
        ] certs.certificatesigningrequests)
        (allow [
          "update"
          "patch"
        ] (certs "certificatesigningrequests/status"))
        (lib.pipe certs.signers [
          (restrictTo [
            "issuers.cert-manager.io/*"
            "clusterissuers.cert-manager.io/*"
          ])
          (allow [ "sign" ])
        ])
        (allow [ "create" ] authz.subjectaccessreviews)
      ];
    };
  };

  controllerLeaderElection = mkRoleSet scope {
    subjects = mkControllerSubject self.controllerServiceAccount;
    inherit labels;
    roles = {
      "${name}:leaderelection" = grant [
        (lib.pipe coord.leases [
          (restrictTo [ "cert-manager-controller" ])
          (allow [
            "get"
            "update"
            "patch"
          ])
        ])
        (allow [ "create" ] coord.leases)
      ];
    };
  };

in
{
  controllerServiceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    inherit name labels;
    extra.automountServiceAccountToken = true;
  };

  # Aggregated into the built-in view, edit, admin, and cluster-reader roles
  # by label; nothing binds them directly.
  clusterViewRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${name}-cluster-view";
    labels = labels // {
      "rbac.authorization.k8s.io/aggregate-to-cluster-reader" = "true";
    };
    extra.rules = grant [ (watch cm.clusterissuers) ];
  };

  viewRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${name}-view";
    labels = labels // {
      "rbac.authorization.k8s.io/aggregate-to-view" = "true";
      "rbac.authorization.k8s.io/aggregate-to-edit" = "true";
      "rbac.authorization.k8s.io/aggregate-to-admin" = "true";
      "rbac.authorization.k8s.io/aggregate-to-cluster-reader" = "true";
    };
    extra.rules = grant [
      (watch cm.certificates)
      (watch cm.certificaterequests)
      (watch cm.issuers)
      (watch acme.challenges)
      (watch acme.orders)
    ];
  };

  editRole =
    let
      edit = allow [
        "create"
        "delete"
        "deletecollection"
        "patch"
        "update"
      ];
    in
    scope.mkClusterResource {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "ClusterRole";
      name = "${name}-edit";
      labels = labels // {
        "rbac.authorization.k8s.io/aggregate-to-edit" = "true";
        "rbac.authorization.k8s.io/aggregate-to-admin" = "true";
      };
      extra.rules = grant [
        (edit cm.certificates)
        (edit cm.certificaterequests)
        (edit cm.issuers)
        (allow [ "update" ] (cm "certificates/status"))
        # The controller creates Challenges and Orders; users may only
        # clean them up or edit a Challenge.
        (allow [
          "delete"
          "deletecollection"
          "patch"
          "update"
        ] acme.challenges)
        (allow [
          "delete"
          "deletecollection"
        ] acme.orders)
      ];
    };

  # Exists only for scraping.
  controllerService =
    if metricsOn then
      scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        inherit name;
        inherit labels;
        spec = {
          type = "ClusterIP";
          selector = self.controllerDeployment.out.selector;
          ports = [
            {
              name = "http-metrics";
              port = common.ports.metrics;
              protocol = "TCP";
              targetPort = common.ports.metrics;
            }
          ];
        };
      }
    else
      null;

  controllerDeployment = scope.mkDeployment {
    inherit name labels;
    # The controller watches every cert-manager kind and crashes until the
    # API server serves them.
    requires = builtins.attrValues self.crds;
    spec = {
      # Leader-elected: one replica serves; from `node` up a standby takes
      # over when a node is lost.
      replicas = kix.availability.pick availability {
        none = 1;
        pod = 1;
        node = 2;
        zone = 2;
      };
      selector.matchLabels = labels;
      template.spec = {
        serviceAccount = self.controllerServiceAccount;
        # Kubernetes' default, set because the scorecard asks every
        # workload to set it.
        terminationGracePeriodSeconds = 30;
        enableServiceLinks = false;
        securityContext = common.podSecurityContext;
        containers = [
          {
            name = "cert-manager-controller";
            image = kix.image.ref (common.checkRelease who config [ "image" ]);
            imagePullPolicy = config.image.pullPolicy;
            args = [
              "--v=2"
              "--cluster-resource-namespace=$(POD_NAMESPACE)"
              "--leader-election-namespace=${ns}"
              "--acme-http01-solver-image=${acmesolverImage}"
            ]
            ++ kix.guardArgs {
              inherit who;
              owned = {
                "--cluster-resource-namespace" =
                  "the controller reads ClusterIssuer Secrets from the instance's namespace (out.clusterResourceNamespace); remove it.";
                "--leader-election-namespace" =
                  "the leader-election Role lives in the instance's namespace; remove it.";
                "--acme-http01-solver-image" = "set operandImages.acmesolver instead.";
              };
            } config.extraArgs;
            ports = [
              {
                name = "http-metrics";
                containerPort = common.ports.metrics;
                protocol = "TCP";
              }
              {
                name = "http-healthz";
                containerPort = common.ports.controllerHealthz;
                protocol = "TCP";
              }
            ];
            securityContext = common.containerSecurityContext;
            # --cluster-resource-namespace expands $(POD_NAMESPACE), and
            # Kubernetes leaves an undefined variable unexpanded.
            env = kix.mkEnvVars (
              kix.mergeEnv {
                inherit who;
                owned = [
                  {
                    vars.POD_NAMESPACE.valueFrom.fieldRef.fieldPath = "metadata.namespace";
                    from = "the pod's namespace";
                    fix = "Remove it; --cluster-resource-namespace reads it.";
                  }
                ];
              } config.env
            );
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
          }
        ];
        nodeSelector."kubernetes.io/os" = "linux";
      };
    };
  };
}
// controllerClusterRoles
// controllerLeaderElection

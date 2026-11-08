# External Secrets Operator CRDs, controller RBAC, and controller Deployment.

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
  c = import ./common.nix { inherit lib kix scope; };
  inherit (c)
    name
    ns
    who
    ports
    controllerLeaseName
    controllerLabels
    podSecurityContext
    containerSecurityContext
    subjectsFor
    serviceAccount
    metricsServiceFor
    crdDocs
    crdSpecs
    kindOf
    pluralOf
    isGenerator
    storeKinds
    readyKinds
    ;

  hasMetrics = config.metrics.enabled && prometheus != null;

  inherit (scope.rbac)
    group
    core
    grant
    full
    watch
    finalize
    allow
    emit
    restrictTo
    mkClusterRoleSet
    mkRoleSet
    ;
  es = group "external-secrets.io" [ ];
  generators = group "generators.external-secrets.io" [ ];
  coord = group "coordination.k8s.io" [ "leases" ];

  # Each handle adds the webhook check to the requires of every custom
  # resource built from it.
  withCheck = args: args // { requires = (args.requires or [ ]) ++ [ self.webhookCheck ]; };
  gate =
    crd:
    crd
    // {
      out = crd.out // {
        cr = args: crd.out.cr (withCheck args);
        mkCR = consumerScope: args: crd.out.mkCR consumerScope (withCheck args);
      };
    };

  controllerArgs = [
    "--enable-leader-election=true"
    "--metrics-addr=:${toString ports.metrics}"
    "--live-addr=:${toString ports.controllerHealth}"
  ]
  ++ kix.guardArgs {
    inherit who;
    owned = {
      "--enable-leader-election" =
        "the package always enables leader election, so instances above availability none run one active controller; remove it.";
      "--leader-election-id" =
        "the leader-election Role grants the lease ${controllerLeaseName} only; remove it.";
      "--metrics-addr" =
        "the container's metrics port and the metrics Service use :${toString ports.metrics}; remove it.";
      "--metrics-secure" = "the ServiceMonitor scrapes plain HTTP; remove it.";
      "--metrics-auth" =
        "the ServiceMonitor scrapes without a token and the package grants no TokenReview RBAC; remove it.";
      "--live-addr" =
        "the liveness and readiness probes use :${toString ports.controllerHealth}; remove it.";
    };
  } config.extraArgs;

  # From deploy/charts/external-secrets/templates/rbac.yaml at the
  # release tag, with every reconciler and openshiftFinalizers enabled
  # (the chart defaults). The controller sets owner references with
  # blockOwnerDeletion, which the OwnerReferencesPermissionEnforcement
  # admission plugin allows only with update on the owner's
  # finalizers subresource.
  controllerRbac = mkClusterRoleSet scope {
    subjects = subjectsFor self.serviceAccount;
    roles."${name}-controller" = grant [
      (
        map es [
          "externalsecrets"
          "pushsecrets"
        ]
        |> full
      )
      (
        map es [
          "clusterexternalsecrets"
          "clusterpushsecrets"
          "clustersecretstores"
          "secretstores"
        ]
        |> allow [
          "get"
          "list"
          "watch"
          "update"
          "patch"
        ]
      )
      (
        map (p: es "${p}/status") [
          "clusterexternalsecrets"
          "clusterpushsecrets"
          "clustersecretstores"
          "externalsecrets"
          "pushsecrets"
          "secretstores"
        ]
        |> allow [
          "get"
          "update"
          "patch"
        ]
      )
      (
        map es [
          "clusterexternalsecrets"
          "clusterpushsecrets"
          "clustersecretstores"
          "externalsecrets"
          "pushsecrets"
          "secretstores"
        ]
        |> finalize
      )
      (
        generators "generatorstates"
        |> allow [
          "get"
          "list"
          "watch"
          "create"
          "update"
          "patch"
          "delete"
          "deletecollection"
        ]
      )
      (
        map (s: generators (pluralOf s)) (
          builtins.filter (s: isGenerator s && kindOf s != "GeneratorState") crdSpecs
        )
        |> watch
      )
      (
        [
          core.serviceaccounts
          core.configmaps
        ]
        |> watch
      )
      (
        core.namespaces
        |> allow [
          "get"
          "list"
          "watch"
          "update"
          "patch"
        ]
      )
      (core.secrets |> full)
      (core "serviceaccounts/token" |> allow [ "create" ])
      (core.events |> emit)
    ];
  };

  controllerLeaderRbac = mkRoleSet scope {
    subjects = subjectsFor self.serviceAccount;
    roles."${name}-leader-election" = grant [
      (coord.leases |> allow [ "create" ])
      (
        coord.leases
        |> restrictTo [ controllerLeaseName ]
        |> allow [
          "get"
          "update"
          "patch"
        ]
      )
    ];
  };
in
{
  serviceAccount = serviceAccount name;

  controllerClusterRole = controllerRbac."${name}-controller";
  controllerClusterRoleBinding = controllerRbac."${name}-controller-binding";
  leaderElectionRole = controllerLeaderRbac."${name}-leader-election";
  leaderElectionRoleBinding = controllerLeaderRbac."${name}-leader-election-binding";

  # The controller lists every kind at start, generators included.
  # The vendored label `external-secrets.io/component: controller` is
  # what the cert-controller's partial cache selects definitions by.
  crds = builtins.listToAttrs (
    map (
      doc:
      lib.nameValuePair (pluralOf doc.spec) (
        gate (
          scope.mkCRD (
            {
              inherit (doc) spec;
              labels = doc.metadata.labels or { };
              # Stores, secrets, and generators are reconciled by the
              # controller pods; none of them runs pods of its own.
              usesAtLeast = _: { };
            }
            // lib.optionalAttrs (builtins.elem (kindOf doc.spec) readyKinds) {
              readiness.condition = {
                type = "Ready";
                status = "True";
              };
            }
            # The controller pods, in this namespace, dial the provider
            # a store names, so a Service address in a store's spec
            # opens their egress to it and its ingress from them.
            // lib.optionalAttrs (builtins.elem (kindOf doc.spec) storeKinds) {
              factBehavior = {
                endpoint = "terminate";
                podSelector = controllerLabels;
                podNamespace = ns;
              };
            }
          )
        )
      )
    ) crdDocs
  );

  deployment = scope.mkDeployment {
    inherit name;
    requires = builtins.attrValues self.crds;
    spec = {
      # Leader election keeps one controller active, so a replacement
      # pod covers "pod" and a standby on another node covers "node".
      replicas = kix.availability.pick availability {
        none = 1;
        pod = 1;
        node = 2;
        zone = 2;
      };
      selector.matchLabels = controllerLabels;
      template.spec = {
        serviceAccount = self.serviceAccount;
        # The controller holds no connections that need draining.
        terminationGracePeriodSeconds = 30;
        securityContext = podSecurityContext;
        containers = [
          {
            name = "external-secrets";
            image = kix.image.ref config.image;
            imagePullPolicy = config.image.pullPolicy;
            args = controllerArgs;
            env = kix.mkEnvVars (kix.mergeEnv { inherit who; } config.env);
            ports = [
              (kix.port "metrics" ports.metrics)
              (kix.port "live" ports.controllerHealth)
            ];
            livenessProbe = {
              httpGet = {
                path = "/healthz";
                port = "live";
              };
              initialDelaySeconds = 10;
              periodSeconds = 10;
            };
            readinessProbe = {
              httpGet = {
                path = "/readyz";
                port = "live";
              };
              initialDelaySeconds = 5;
              periodSeconds = 10;
            };
            resources = config.resources;
            securityContext = containerSecurityContext;
          }
        ];
      };
    };
  };

  controllerMetricsService = metricsServiceFor hasMetrics self.deployment controllerLabels;
}

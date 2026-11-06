# infisical-operator: the Infisical Kubernetes operator, which syncs secrets
# between Infisical and Kubernetes Secrets and ConfigMaps.
#
# The package renders the controller, its RBAC, the seven custom resource
# definitions it watches, and an InfisicalConnection named `default` that
# points at `address`. An InfisicalAuth without `infisicalConnectionRef` uses
# that connection. The connection's IsReady condition means the operator
# reached `<address>/api/status`, so the first deploy finishes only once
# Infisical is reachable from the operator's pods.
#
# The controller reads and writes Secrets and ConfigMaps in every namespace
# and mints ServiceAccount tokens (for the Kubernetes auth method). Upstream
# requires both. Every instance watches every namespace, so a cluster runs
# one: `conflictsWith` refuses a second instance by alias, and
# `annotationDomains` refuses it whatever its aliases.
#
# Minimal instance:
#
#   instances.infisical.infisical-operator.package = packages.infisical-operator;
#
# Dependencies:
#   prometheus (optional)  metrics Service and ServiceMonitor.
#
# Alerts: with a prometheus dependency and `metrics.enabled`, a
# PrometheusRule `<instance>-alerts` selects the metrics Service's series.
#   InfisicalOperatorDown (warning)             no operator replica answers a
#                                               scrape. Synced Secrets and
#                                               ConfigMaps stay as they are,
#                                               but changes in Infisical do
#                                               not reach them.
#   InfisicalOperatorReconcileErrors (warning)  reconciles of one kind fail
#                                               for 15 minutes, such as a
#                                               sync that Infisical refuses.
# The operator registers no admission webhooks. Fewer ready replicas than
# desired is left to prometheus-default-rules
# (KubeDeploymentReplicasMismatch).
#
# Network policy: the package's intent opens TCP 443 to destinations outside
# the cluster. When the cluster enforces egress policy, an `address` inside
# the cluster or on another port fails the build until a
# `networkPolicy.platformIntents` entry selects the operator's pods and
# reaches it; the error gives the entry.
#
# Escape hatches: `extraArgs` and `env` for the operator; `partsOverlays` on
# parts `deployment` and `connection`.
#
# `out`:
#   out.mkInfisicalSecret scope { name; spec; }        (v1alpha1)
#   out.mkInfisicalStaticSecret scope { name; spec; }  (v1beta1)
#       Build the two kinds that write Secrets and ConfigMaps. Each target's
#       metadata is set explicitly (empty unless the caller sets it), and a
#       missing target namespace defaults to the caller's. Without explicit
#       metadata the operator copies the custom resource's labels and
#       annotations onto the object it creates, Kix's identity annotation
#       included, and `kix gc` then deletes that object as Kix-managed
#       garbage. Both refuse a custom resource with nowhere to write. The
#       custom resource requires the default connection, so it is applied
#       after the operator is running and Infisical is reachable. The result
#       carries `out.secretRef { name ? null; keys; type ? null; }`, a
#       `scope.mkSecretRef` for one of its Secret targets that is ordered
#       after the custom resource.
#   out.mkInfisicalAuth scope { name; spec; }
#       Sets `spec.infisicalConnectionRef` to the default connection when the
#       spec has none, which also orders the auth after the connection.
#   out.mkInfisicalDynamicSecret
#       Throws. The operator always copies an InfisicalDynamicSecret's
#       annotations onto the lease Secret it creates.
#   out.crds.{ClusterGenerator,InfisicalConnection,InfisicalPushSecret}
#       For `scope.mkCR`. These kinds create no Kubernetes object. There are
#       no handles for InfisicalSecret and InfisicalStaticSecret, so their
#       managed objects always go through the builders above, and none for
#       InfisicalAuth, which `mkInfisicalAuth` covers.
#
# Consumer pattern, in an instance that depends on `infisicalOperator`:
#
#   identity = scope.mkSecretRef { name = "infisical-identity"; keys = [ "clientId" "clientSecret" ]; };
#   auth = infisicalOperator.out.mkInfisicalAuth scope {
#     name = "billing";
#     spec = {
#       method = "universal";
#       universal = {
#         clientIdRef = { inherit ((self.identity.out.keyRef "clientId").valueFrom.secretKeyRef) name key; namespace = scope.namespaceName; };
#         clientSecretRef = { inherit ((self.identity.out.keyRef "clientSecret").valueFrom.secretKeyRef) name key; namespace = scope.namespaceName; };
#       };
#     };
#   };
#   sync = infisicalOperator.out.mkInfisicalStaticSecret scope {
#     name = "billing";
#     spec = {
#       infisicalAuthRef = { name = self.auth.out.name; namespace = scope.namespaceName; };
#       syncOptions.refreshInterval = "1m";
#       sources = [ { projectId = "<project id>"; environmentSlug = "prod"; secretPath = "/"; } ];
#       targets = [ { name = "billing"; kind = "Secret"; creationPolicy = "Owner"; } ];
#     };
#   };
#   credentials = self.sync.out.secretRef { keys = [ "API_KEY" ]; };
#
# Known limit: `kix deploy` writes its bookkeeping annotations in a second
# request after each apply. The operator writes an InfisicalAuth's status
# with an update that fails if the object changed since it read it, only
# logs that failure, and ignores metadata-only changes. An auth applied while
# the operator runs can therefore stay without IsReady, and the deploy waits
# on it until its readiness timeout; the InfisicalStaticSecret that names it
# does not sync meanwhile. Restarting the operator
# (`kubectl -n <namespace> rollout restart deployment/<instance>`) or
# updating a Secret the auth references makes the operator reconcile the
# auth again.
# A connection built from `out.crds.InfisicalConnection` has the same limit.
#
# Self-hosted Infisical behind a private CA: mount the CA through
# `partsOverlays` on part `deployment` and set `SSL_CERT_FILE` with `env`,
# which covers every kind; or set `spec.tls.caCertificate` on part
# `connection` through `partsOverlays`, and `spec.tls` on each v1alpha1
# custom resource. Without either, the deploy waits on the connection's
# IsReady until it times out.
#
# root = the operator Deployment.

{
  scope,
  lib,
  kix,
  availability,
}:
let
  # The upstream release: meta.version, the default image.tag, the CRD tag
  # in crds/sources.txt (checked below), and the RBAC rules in the build.
  release = "v0.11.10";
  sourceUrls = builtins.filter (l: l != "" && !lib.hasPrefix "#" l) (
    lib.splitString "\n" (builtins.readFile ./crds/sources.txt)
  );

  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "infisical-operator ${ns}/${name}";

  metricsPort = 8080;
  healthPort = 8081;
  # The metrics Service, whose name the alerts select on.
  metricsServiceName = "${name}-metrics";

  egress = import ./egress.nix { inherit lib; };

  inherit (scope.rbac)
    group
    core
    grant
    full
    readWrite
    watch
    allow
    emit
    restrictTo
    finalize
    mkClusterRoleSet
    mkRoleSet
    ;
  apps = group "apps" [
    "daemonsets"
    "deployments"
    "statefulsets"
  ];
  authn = group "authentication.k8s.io" [ "tokenreviews" ];
  coord = group "coordination.k8s.io" [ "leases" ];
  infisical = group "secrets.infisical.com" [ ];

  vendored =
    plural: (builtins.fromJSON (builtins.readFile ./crds/${plural}.secrets.infisical.com.json)).spec;
  condition = type: status: {
    condition = {
      type = "secrets.infisical.com/${type}";
      inherit status;
    };
  };

  # "v0.11.3" -> [ "0" "11" ".3" ]; null when the tag is not a version.
  versionParts = tag: builtins.match "v?([0-9]+)\\.([0-9]+)(\\..*)?" tag;
  releaseMinor = lib.take 2 (versionParts release);

  # The operator trims a trailing "/" and then "/api" from the address and
  # appends "/api" for API calls. The package does the same, so the default
  # connection and INFISICAL_HOST_API agree.
  stripTrailingSlashes = s: builtins.head (builtins.match "(.*[^/])/*" s);
  normaliseAddress = address: lib.removeSuffix "/api" (stripTrailingSlashes address);

  # Labels and annotations are the operator's own fields, so empty maps here
  # keep Kix's labels and annotations off the object the operator creates.
  # Without them the operator copies the custom resource's metadata, the
  # kix.run identity annotation included, and `kix gc` deletes that object.
  emptyMetadata = {
    annotations = { };
    labels = { };
  };
in
{
  meta = {
    version = release;
    description = "Infisical Kubernetes operator, which syncs secrets between Infisical and Kubernetes Secrets";
    owner = "platform";
    defaultAliases = [ "infisicalOperator" ];
    # One instance per cluster; see the header.
    conflictsWith = [ "cluster:infisicalOperator" ];
    # Workloads opt in to restarts on secret change with
    # secrets.infisical.com/auto-reload.
    annotationDomains = [ "secrets.infisical.com" ];
    # Infisical Cloud serves its API on TCP 443. meta is static, so this
    # intent cannot follow `address`; under egress enforcement the build
    # refuses an address it does not cover unless a platform intent does
    # (egress.nix).
    network.intents.infisicalApi.egress = [
      {
        to = "world";
        ports = [
          {
            port = 443;
            protocol = "TCP";
          }
        ];
      }
    ];
  };

  assertions =
    { config, ... }:
    let
      imageTag = builtins.unsafeDiscardStringContext config.image.tag;
    in
    [
      {
        assertion = versionParts imageTag != null && lib.take 2 (versionParts imageTag) == releaseMinor;
        message = "image.tag \"${imageTag}\" is not a v${lib.concatStringsSep "." releaseMinor} release, and the CRDs and RBAC in kix/packages/infisical-operator are from ${release}. Remove image.tag or set a v${lib.concatStringsSep "." releaseMinor} tag. To move the package to another release, change release in default.nix and the tag in crds/sources.txt, run uv run scripts/vendor-crds.py infisical-operator, and compare the manager ClusterRole with config/rbac/role.yaml at the new tag.";
      }
      {
        assertion = sourceUrls != [ ] && lib.all (lib.hasInfix "/${release}/") sourceUrls;
        message = "kix/packages/infisical-operator/crds/sources.txt fetches CRDs from a tag other than ${release}, the package's release. Set the tag in every URL to ${release} and run uv run scripts/vendor-crds.py infisical-operator.";
      }
    ];

  options = {
    image = kix.options.image {
      repository = "docker.io/infisical/kubernetes-operator";
      tag = release;
      digest = "sha256:c4ad1d6e389653598de3138e7f60f8f34a002af3d3ca736c8716c498b3172035";
    };

    address = lib.mkOption {
      type = lib.types.strMatching "https?://[^/]+.*";
      default = "https://app.infisical.com";
      description = ''
        Infisical URL, for the default InfisicalConnection and the
        operator's INFISICAL_HOST_API. Infisical Cloud EU is
        `https://eu.infisical.com`. A trailing `/` or `/api` is removed, as
        the operator does. The operator must reach `<address>/api/status`
        for the first deploy to finish. When the cluster enforces egress
        policy, an address inside the cluster or on a port other than 443
        also needs a `networkPolicy.platformIntents` entry, which the build
        error spells out. For a private CA, see the package header.
      '';
    };

    resources = kix.options.resources {
      requests = {
        cpu = "10m";
        memory = "64Mi";
      };
      limits = {
        cpu = "500m";
        memory = "128Mi";
      };
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Arguments appended to the operator's own. The package owns --leader-elect, --health-probe-bind-address, --metrics-bind-address, and --metrics-secure.";
    };

    env = kix.options.env;

    metrics = kix.options.monitor;
  };

  build = [
    (
      {
        self,
        config,
        clusterConfig,
        prometheus ? null,
        ...
      }:
      let
        addr = normaliseAddress config.address;
        hasMetrics = config.metrics.enabled && prometheus != null;

        env = kix.mkEnvVars (
          kix.mergeEnv {
            inherit who;
            owned = [
              {
                vars.INFISICAL_HOST_API = "${addr}/api";
                from = "the address option";
                fix = "Set address instead, so the default InfisicalConnection and the network intent agree with it.";
              }
            ];
          } config.env
        );

        args = [
          "--leader-elect"
          "--health-probe-bind-address=:${toString healthPort}"
          "--metrics-bind-address=:${toString metricsPort}"
          # The operator serves metrics over TLS with a self-signed
          # certificate and no authentication, so plain HTTP exposes nothing
          # more and the ServiceMonitor needs no TLS settings.
          "--metrics-secure=false"
        ]
        ++ kix.guardArgs {
          inherit who;
          owned = {
            "--leader-elect" =
              "the package always enables leader election, so instances above availability none run one active controller; remove it.";
            "--health-probe-bind-address" =
              "the liveness and readiness probes use :${toString healthPort}; remove it.";
            "--metrics-bind-address" =
              "the container's metrics port and the metrics Service use :${toString metricsPort}; remove it.";
            "--metrics-secure" = "the ServiceMonitor scrapes plain HTTP; remove it.";
          };
        } config.extraArgs;

        egressProblem = egress.check {
          inherit who clusterConfig;
          address = addr;
          namespace = ns;
          intentName = "${name}-egress";
          inherit (scope) selectorLabels;
        };

        plurals = map (crd: crd.rawManifest.spec.names.plural) (builtins.attrValues self.crds);
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = ns;
          }
        ];

        managerRbac = mkClusterRoleSet scope {
          inherit subjects;
          # From config/rbac/role.yaml at the release tag.
          roles.${name} = grant [
            (core.configmaps |> readWrite)
            (core.secrets |> readWrite)
            (
              core.pods
              |> allow [
                "get"
                "list"
              ]
            )
            (core.serviceaccounts |> watch)
            (core "serviceaccounts/token" |> allow [ "create" ])
            (
              [
                apps.daemonsets
                apps.deployments
                apps.statefulsets
              ]
              |> allow [
                "get"
                "list"
                "update"
                "watch"
              ]
            )
            (authn.tokenreviews |> allow [ "create" ])
            (map infisical plurals |> full)
            (
              map (p: infisical "${p}/status") (builtins.filter (p: p != "clustergenerators") plurals)
              |> allow [
                "get"
                "patch"
                "update"
              ]
            )
            (
              map infisical [
                "infisicaldynamicsecrets"
                "infisicalpushsecrets"
                "infisicalsecrets"
                "infisicalstaticsecrets"
              ]
              |> finalize
            )
          ];
        };

        leaderElectionName = "${name}-leader-election";
        leaderElectionRbac = mkRoleSet scope {
          inherit subjects;
          roles.${leaderElectionName} = grant [
            (coord.leases |> allow [ "create" ])
            # The lease name is the operator's compiled-in LeaderElectionID.
            (
              coord.leases
              |> restrictTo [ "cf2b8c44.infisical.com" ]
              |> allow [
                "get"
                "update"
                "patch"
              ]
            )
            (core.events |> emit)
          ];
        };

        connectionRef = {
          name = self.connection.out.name;
          namespace = ns;
        };

        # The custom resource also requires the default connection: it is
        # applied once the controller runs and Infisical is reachable.
        # Neither kind names the connection, so the requirement is explicit.
        operand =
          part: consumerScope: args:
          self.crds.${part}.out.mkCR consumerScope (
            args
            // {
              requires = (args.requires or [ ]) ++ [ self.connection ];
            }
          );

        # Builder errors name this instance (`who`) and the consumer's
        # custom resource.
        crName =
          consumerScope: kind: args:
          "${kind} ${consumerScope.namespaceName}/${args.name}";

        withMetadata = attrs: attrs // { metadata = emptyMetadata // (attrs.metadata or { }); };

        pinTemplateMetadata =
          consumerScope: args:
          let
            spec = args.spec or { };
            what = crName consumerScope "InfisicalSecret" args;
            secretRefs = spec.managedKubeSecretReferences or [ ];
            configMapRefs = spec.managedKubeConfigMapReferences or [ ];
            # A reference without a template gets every synced key, which is
            # the operator's behaviour for a missing template.
            pinTemplate =
              ref:
              ref
              // {
                template =
                  if ref ? template then
                    { metadata = { }; } // ref.template
                  else
                    {
                      includeAllSecrets = true;
                      metadata = { };
                    };
              };
          in
          if spec ? managedSecretReference then
            throw "${who}: ${what} sets managedSecretReference, which upstream is deprecating and rejects alongside managedKubeSecretReferences. Move it into managedKubeSecretReferences."
          else if secretRefs == [ ] && configMapRefs == [ ] then
            throw "${who}: ${what} sets no managedKubeSecretReferences or managedKubeConfigMapReferences, so the operator has nowhere to write. Add one."
          else
            args
            // {
              spec =
                spec
                // lib.optionalAttrs (secretRefs != [ ]) {
                  managedKubeSecretReferences = map (
                    ref: pinTemplate ({ secretNamespace = consumerScope.namespaceName; } // ref)
                  ) secretRefs;
                }
                // lib.optionalAttrs (configMapRefs != [ ]) {
                  managedKubeConfigMapReferences = map (
                    ref: pinTemplate ({ configMapNamespace = consumerScope.namespaceName; } // ref)
                  ) configMapRefs;
                };
            };

        pinTargets =
          consumerScope: args:
          let
            spec = args.spec or { };
          in
          if (spec.targets or [ ]) == [ ] then
            throw "${who}: ${
              crName consumerScope "InfisicalStaticSecret" args
            } sets no targets, so the operator has nowhere to write. Add one."
          else
            args
            // {
              spec = spec // {
                targets = map (
                  target: withMetadata ({ namespace = consumerScope.namespaceName; } // target)
                ) spec.targets;
              };
            };

        # Adds out.secretRef to a built custom resource. `targets` are its
        # Secret targets as { name; namespace; type; }.
        withSecretRefs =
          consumerScope: what: targets: cr:
          let
            names = map (t: t.name) targets;
            listed = lib.concatStringsSep ", " names;
            secretRef =
              {
                name ? null,
                keys,
                type ? null,
              }:
              let
                target =
                  if targets == [ ] then
                    throw "${who}: ${what} writes no Secret, so its out.secretRef has nothing to reference. Add a Secret target."
                  else if name == null then
                    if builtins.length targets == 1 then
                      builtins.head targets
                    else
                      throw "${who}: out.secretRef of ${what} needs a name, because the custom resource has more than one Secret target; pass name = one of: ${listed}."
                  else
                    lib.findFirst (t: t.name == name)
                      (throw "${who}: out.secretRef of ${what} names Secret \"${name}\", which is not one of its targets; targets are: ${listed}.")
                      targets;
              in
              if target.namespace != consumerScope.namespaceName then
                throw "${who}: out.secretRef of ${what} builds a reference in ${consumerScope.namespaceName}; the target ${target.name} is in ${target.namespace}. Build the reference from an instance in ${target.namespace}."
              else
                consumerScope.mkSecretRef {
                  inherit (target) name;
                  inherit keys;
                  type = if type != null then type else target.type;
                  requires = [ cr ];
                };
          in
          cr
          // {
            out = cr.out // {
              inherit secretRef;
            };
          };
      in
      {
        serviceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          inherit name;
        };

        clusterRole = managerRbac.${name};
        clusterRoleBinding = managerRbac."${name}-binding";
        leaderElectionRole = leaderElectionRbac.${leaderElectionName};
        leaderElectionRoleBinding = leaderElectionRbac."${leaderElectionName}-binding";

        # The controller lists every kind at start. Without a CRD its caches
        # never sync and the manager exits.
        # Every kind syncs or generates Secrets from the manager; none runs pods.
        crds = {
          clusterGenerators = scope.mkCRD {
            spec = vendored "clustergenerators";
            usesAtLeast = _: { };
          };
          infisicalAuths = scope.mkCRD {
            spec = vendored "infisicalauths";
            readiness = condition "IsReady" "True";
            usesAtLeast = _: { };
          };
          infisicalConnections = scope.mkCRD {
            spec = vendored "infisicalconnections";
            readiness = condition "IsReady" "True";
            usesAtLeast = _: { };
          };
          infisicalDynamicSecrets = scope.mkCRD {
            spec = vendored "infisicaldynamicsecrets";
            readiness = condition "Reconcile" "True";
            usesAtLeast = _: { };
          };
          # The operator sets Reconcile to True on an error and to False on
          # success.
          infisicalPushSecrets = scope.mkCRD {
            spec = vendored "infisicalpushsecrets";
            readiness = condition "Reconcile" "False";
            usesAtLeast = _: { };
          };
          infisicalSecrets = scope.mkCRD {
            spec = vendored "infisicalsecrets";
            readiness = condition "ReadyToSyncSecrets" "True";
            usesAtLeast = _: { };
          };
          # The operator sets no IsReady condition on this kind.
          infisicalStaticSecrets = scope.mkCRD {
            spec = vendored "infisicalstaticsecrets";
            readiness = condition "LastReconcileStatus" "True";
            usesAtLeast = _: { };
          };
        };

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
            selector.matchLabels = scope.selectorLabels;
            template.spec = {
              serviceAccount = self.serviceAccount;
              terminationGracePeriodSeconds = 10;
              securityContext = {
                runAsNonRoot = true;
                seccompProfile.type = "RuntimeDefault";
              };
              containers = [
                {
                  name = "manager";
                  image = kix.image.ref config.image;
                  imagePullPolicy = config.image.pullPolicy;
                  command = [ "/manager" ];
                  inherit args env;
                  ports = [
                    (kix.port "metrics" metricsPort)
                    (kix.port "health" healthPort)
                  ];
                  livenessProbe = {
                    httpGet = {
                      path = "/healthz";
                      port = "health";
                    };
                    initialDelaySeconds = 15;
                    periodSeconds = 20;
                  };
                  readinessProbe = {
                    httpGet = {
                      path = "/readyz";
                      port = "health";
                    };
                    initialDelaySeconds = 5;
                    periodSeconds = 10;
                  };
                  resources = config.resources;
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    capabilities.drop = [ "ALL" ];
                    readOnlyRootFilesystem = true;
                  };
                }
              ];
            };
          };
        };

        metricsService =
          if hasMetrics then
            self.deployment
            |> kix.service.fromWorkload {
              name = metricsServiceName;
              ports = [
                {
                  name = "metrics";
                  port = metricsPort;
                  targetPort = "metrics";
                  protocol = "TCP";
                }
              ];
            }
            |> scope.mkResource
          else
            null;

        # Upstream's chart ships this connection disabled. Kix renders it so
        # that the first deploy proves the operator runs and reaches
        # Infisical.
        #
        # It requires only its CRD, not the Deployment, so on a first deploy
        # it is normally applied before the operator's first reconcile. The
        # operator writes the connection's status with an update that fails
        # when the object changed after its read, ignores metadata-only
        # changes, and retries a success after five minutes. A connection the
        # operator reconciles before the annotation patch `kix deploy` sends
        # after each apply can lose IsReady for longer than the deploy waits.
        # That stays possible when a later deploy changes `address` for a
        # running operator.
        connection =
          assert lib.assertMsg (egressProblem == null) egressProblem;
          self.crds.infisicalConnections.out.mkCR scope {
            name = "default";
            spec.address = addr;
          };

        root = {
          resource = self.deployment;
          requires = [
            self.serviceAccount
          ]
          ++ lib.optional hasMetrics self.metricsService
          ++ builtins.attrValues self.crds;
          # The PackageInstance completes once the default connection is
          # ready. Dependents wait through the builders' requirements.
          postHooks = [ self.connection ];

          out = {
            crds = {
              ClusterGenerator = self.crds.clusterGenerators;
              InfisicalConnection = self.crds.infisicalConnections;
              InfisicalPushSecret = self.crds.infisicalPushSecrets;
            };

            mkInfisicalSecret =
              consumerScope: args:
              let
                pinned = pinTemplateMetadata consumerScope args;
                targets = map (ref: {
                  name = ref.secretName;
                  namespace = ref.secretNamespace;
                  type = ref.secretType or "Opaque";
                }) (pinned.spec.managedKubeSecretReferences or [ ]);
              in
              withSecretRefs consumerScope (crName consumerScope "InfisicalSecret" args) targets (
                operand "infisicalSecrets" consumerScope pinned
              );

            mkInfisicalStaticSecret =
              consumerScope: args:
              let
                pinned = pinTargets consumerScope args;
                targets = map (t: {
                  inherit (t) name namespace;
                  type = t.secretType or "Opaque";
                }) (builtins.filter (t: (t.kind or null) == "Secret") pinned.spec.targets);
              in
              withSecretRefs consumerScope (crName consumerScope "InfisicalStaticSecret" args) targets (
                operand "infisicalStaticSecrets" consumerScope pinned
              );

            # The connection name carries the dependency on the connection.
            mkInfisicalAuth =
              consumerScope: args:
              self.crds.infisicalAuths.out.mkCR consumerScope (
                args
                // {
                  spec = {
                    infisicalConnectionRef = connectionRef;
                  }
                  // (args.spec or { });
                }
              );

            mkInfisicalDynamicSecret =
              _: _:
              throw "${who}: there is no InfisicalDynamicSecret builder. The operator copies the custom resource's annotations, Kix's included, onto the lease Secret it creates and has no setting to stop it. Create InfisicalDynamicSecrets outside Kix.";
          };
        };
      }
    )

    (
      let
        sel = ''namespace="${ns}",service="${metricsServiceName}"'';
        reconcileErrors = "sum by (namespace, service, controller) (increase(controller_runtime_reconcile_errors_total{${sel}}[30m]))";
        reconciles = "sum by (namespace, service, controller) (increase(controller_runtime_reconcile_total{${sel}}[30m]))";
        operator = "Infisical operator ${ns}/${name}";
      in
      kix.monitor {
        service = "metricsService";
        port = "metrics";
        alerts = {
          InfisicalOperatorDown = {
            expr = "sum by (namespace, service) (up{${sel}}) == 0 or absent(up{${sel}})";
            "for" = "10m";
            severity = "warning";
            summary = "The Infisical operator is down.";
            description = "No replica of the ${operator} has answered a scrape for 10 minutes. Secrets and ConfigMaps it synced keep their values, but changes made in Infisical do not reach them. Check the operator Deployment in ${ns}.";
          };
          InfisicalOperatorReconcileErrors = {
            # controller-runtime counts an optimistic-lock conflict as an error
            # and retries at once, so a busy healthy controller shows a few.
            # Alert on the share of reconciles that fail, with a floor.
            expr = "${reconcileErrors} / ${reconciles} > 0.1 and ${reconcileErrors} > 2";
            "for" = "15m";
            severity = "warning";
            summary = "The Infisical operator fails to reconcile its resources.";
            description = "The {{ $labels.controller }} controller of the ${operator} has failed {{ $value | humanizePercentage }} of its reconciles over the last 30 minutes, so a Secret or ConfigMap it manages may be stale. The operator log and the conditions of the custom resource name the error, such as an authentication or connection failure.";
          };
        };
      }
    )
  ];
}

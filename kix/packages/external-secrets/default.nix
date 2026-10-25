# external-secrets: External Secrets Operator, which syncs secrets from
# external stores (Vault, cloud secret managers, and others) into
# Kubernetes Secrets.
#
# The package renders three Deployments of one image: the controller, the
# admission webhook, and the cert-controller. It also renders their
# ServiceAccounts and RBAC, the 25 custom resource definitions of the
# release (crds/, from upstream's deploy/crds/bundle.yaml), the webhook
# Service, two ValidatingWebhookConfigurations, an empty Secret for the
# webhook's certificate, and a webhook check Job.
#
# The cert-controller writes a CA and a serving certificate into that
# Secret and the CA into the `caBundle` of each webhook entry. Kix renders
# the entries without `caBundle`, so the two never write the same field.
# The webhook validates ExternalSecrets, SecretStores, and
# ClusterSecretStores with failurePolicy Fail, and the API server refuses
# those writes until the CA is in place. Every custom resource built from
# `out` therefore requires the check Job, which succeeds once the API server
# admits a server-side dry-run create of an ExternalSecret and of a
# SecretStore.
#
# The controller reads and writes Secrets in every namespace, reads
# ConfigMaps, and mints ServiceAccount tokens (for the Kubernetes provider
# and Kubernetes auth methods), as upstream's chart grants by default.
# Every instance watches every namespace and the webhook configurations are
# cluster-wide, so a cluster runs one: `conflictsWith` refuses a second
# instance.
#
# Minimal instance:
#
#   instances.external-secrets.external-secrets.package = packages.external-secrets;
#
# DI deps:
#   prometheus (optional)  metrics Services and ServiceMonitors for the three
#                          components. The package ships no alerts.
#
# Network policy: the intents open TCP 443 to destinations outside the
# cluster for provider APIs, and admit the API server to TCP 10250 for the
# webhook. Package intents apply to every workload of the instance. The
# SecretStore and ClusterSecretStore definitions declare that the
# controller dials the provider, so a store whose spec carries a Kix
# Service address (`openbao.out.externalSecretsProvider`) opens the
# controller's egress to that Service and the Service's ingress from the
# controller. A provider outside the cluster on another port, or one
# inside it written as a literal address, needs a
# `networkPolicy.platformIntents` entry for the controller's pods.
#
# Escape hatches: `extraArgs` and `env` for the controller;
# `webhookCheck.image`; `partsOverlays` on any part.
#
# Exposes:
#   out.mkSecretStore scope { name; spec; }
#       Builds a SecretStore in the caller's namespace. Refuses a
#       `{ name; key; }` Secret selector anywhere in the spec whose name is a
#       literal string, so each credential comes from a secret dependency
#       (`(dep.out.keyRef "<key>").valueFrom.secretKeyRef`), which orders the
#       store after the Secret and checks the key.
#   out.mkClusterSecretStore scope { name; spec; }
#       Builds a ClusterSecretStore with the same refusal, and also refuses a
#       selector without `namespace`, which the controller would read from
#       each ExternalSecret's namespace.
#   out.mkExternalSecret scope { name; spec; }
#       Builds an ExternalSecret. Sets `spec.target.template.metadata` to `{ }`
#       unless the spec sets it: without a template the controller copies the
#       ExternalSecret's labels and annotations, Kix's identity annotation
#       included, onto the Secret it writes, and `kix gc` then deletes that
#       Secret as Kix-managed garbage. Refuses `spec.target.manifest`
#       (generic targets), which the controller runs only with
#       `--unsafe-allow-generic-targets` and RBAC the package does not grant.
#       The result carries `out.secretRef { keys; type ? null; }`, a
#       `scope.mkSecretRef` for the target Secret that is ordered after the
#       ExternalSecret. It refuses creationPolicy None, and, when the keys the
#       Secret receives are known (no `dataFrom` or `templateFrom`), a key
#       the ExternalSecret does not write.
#   out.crds.<Kind>
#       For `scope.mkCR`: ClusterExternalSecret, PushSecret,
#       ClusterPushSecret, ClusterGenerator, and the generator kinds
#       (Password, UUID, Fake, VaultDynamicSecret, ...). There are no handles
#       for ExternalSecret, SecretStore, and ClusterSecretStore, which go
#       through the builders above, and none for GeneratorState, which the
#       controller manages.
#
# Consumer pattern, in an instance that depends on `externalSecrets` and on
# a secret dependency `vaultToken` declaring key `token`:
#
#   store = externalSecrets.out.mkSecretStore scope {
#     name = "vault";
#     spec.provider.vault = {
#       server = "https://vault.example.com";
#       path = "secret";
#       version = "v2";
#       auth.tokenSecretRef = (vaultToken.out.keyRef "token").valueFrom.secretKeyRef;
#     };
#   };
#   sync = externalSecrets.out.mkExternalSecret scope {
#     name = "billing";
#     spec = {
#       secretStoreRef = { name = self.store.out.name; kind = "SecretStore"; };
#       refreshInterval = "1h";
#       data = [ { secretKey = "API_KEY"; remoteRef = { key = "billing"; property = "api-key"; }; } ];
#     };
#   };
#   credentials = self.sync.out.secretRef { keys = [ "API_KEY" ]; };
#
# kix/lib/tests/units/external-secrets.nix evaluates this pattern.
#
# root = the controller Deployment; the webhook check runs after it.

{
  scope,
  lib,
  kix,
  availability,
}:
let
  # The upstream release: meta.version, the default image.tag, and the CRD
  # tag in crds/sources.txt (kix-lib test external-secrets-sources-match-release).
  release = "v2.11.0";

  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "external-secrets ${ns}/${name}";

  ports = {
    metrics = 8080;
    webhookHealth = 8081;
    controllerHealth = 8082;
    webhook = 10250;
  };

  # The Service the webhook entries call, and the name its serving
  # certificate is issued for. The cert-controller args and the entries do
  # not read the Service's `out.name`: the Service selects the webhook pods,
  # which wait for the certificate the cert-controller writes, so the
  # reference would order the cert-controller after those pods.
  webhookServiceName = "${name}-webhook";
  certDir = "/tmp/certs";

  # The controller-runtime leader election IDs, the controller's from its
  # `--leader-election-id` default and the cert-controller's compiled in
  # (cmd/controller/certcontroller.go).
  controllerLeaseName = "external-secrets-controller";
  certControllerLeaseName = "crd-certs-controller";

  labelsFor = component: scope.selectorLabels // { "app.kubernetes.io/component" = component; };

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
  admission = group "admissionregistration.k8s.io" [ "validatingwebhookconfigurations" ];
  apiext = group "apiextensions.k8s.io" [ "customresourcedefinitions" ];
  discovery = group "discovery.k8s.io" [ "endpointslices" ];
  coord = group "coordination.k8s.io" [ "leases" ];

  crdFiles = builtins.attrNames (
    lib.filterAttrs (f: type: type == "regular" && lib.hasSuffix ".json" f) (builtins.readDir ./crds)
  );
  crdDocs = map (f: builtins.fromJSON (builtins.readFile ./crds/${f})) crdFiles;
  crdSpecs = map (doc: doc.spec) crdDocs;
  kindOf = spec: spec.names.kind;
  pluralOf = spec: spec.names.plural;
  isGenerator = spec: spec.group == "generators.external-secrets.io";

  # The kinds whose provider the controller dials.
  storeKinds = [
    "ClusterSecretStore"
    "SecretStore"
  ];

  # Every kind with status conditions sets Ready to True on success
  # (apis/externalsecrets/v1/*_types.go, apis/externalsecrets/v1alpha1/pushsecret_types.go,
  # apis/generators/v1alpha1/generator_state_types.go). ClusterPushSecret
  # reports PushSecret's condition type.
  readyKinds = [
    "ClusterExternalSecret"
    "ClusterPushSecret"
    "ClusterSecretStore"
    "ExternalSecret"
    "GeneratorState"
    "PushSecret"
    "SecretStore"
  ];

  # Kinds the builders cover, and the kind the controller writes itself.
  unexposedKinds = [
    "ClusterSecretStore"
    "ExternalSecret"
    "GeneratorState"
    "SecretStore"
  ];

  # "v2.11.0" -> [ "2" "11" ".0" ]; null when the tag is not a version.
  versionParts = tag: builtins.match "v?([0-9]+)\\.([0-9]+)(\\..*)?" tag;
  releaseMinor = lib.take 2 (versionParts release);
  releaseMinorText = lib.concatStringsSep "." releaseMinor;

  # Secret selectors (`{ name; key; namespace?; }`, the upstream
  # SecretKeySelector) in a store spec, with their paths. `literal` is true
  # when the name is a plain string; a name from a secret dependency's
  # `keyRef` or from `kix.untrackedRef` carries string context.
  secretSelectors =
    path: v:
    if builtins.isAttrs v then
      let
        isSelector =
          v ? name
          && v ? key
          && builtins.isString v.name
          && lib.all (
            n:
            builtins.elem n [
              "name"
              "key"
              "namespace"
            ]
          ) (builtins.attrNames v);
      in
      if isSelector then
        [
          {
            inherit path;
            inherit (v) name key;
            literal = !builtins.hasContext v.name;
            hasNamespace = v ? namespace;
          }
        ]
      else
        lib.concatLists (lib.mapAttrsToList (k: secretSelectors "${path}.${k}") v)
    else if builtins.isList v then
      lib.concatLists (lib.imap0 (i: secretSelectors "${path}[${toString i}]") v)
    else
      [ ];
in
{
  meta = {
    version = release;
    description = "External Secrets Operator, which syncs secrets from external stores into Kubernetes Secrets";
    owner = "platform";
    defaultAliases = [ "externalSecrets" ];
    # One instance per cluster; see the header.
    conflictsWith = [ "cluster:externalSecrets" ];
    # The vendored CRDs carry x-kubernetes-validations (CEL) rules.
    k8s.minVersion = "1.25";
    network.intents = {
      # Provider APIs are runtime data in SecretStore specs. Cloud secret
      # managers serve HTTPS on 443.
      providers.egress = [
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
      # The API server calls the admission webhook. Only the webhook pods
      # listen on this port.
      webhook.ingress = [
        {
          from = "apiserver";
          ports = [
            {
              port = ports.webhook;
              protocol = "TCP";
            }
          ];
        }
      ];
    };
  };

  assertions =
    { config, ... }:
    let
      generic = builtins.filter (
        a:
        a == "--unsafe-allow-generic-targets"
        || (
          lib.hasPrefix "--unsafe-allow-generic-targets=" a && a != "--unsafe-allow-generic-targets=false"
        )
      ) config.extraArgs;
    in
    [
      {
        assertion =
          versionParts config.image.tag != null && lib.take 2 (versionParts config.image.tag) == releaseMinor;
        message = "image.tag \"${config.image.tag}\" is not a v${releaseMinorText} release, and the CRDs and RBAC in kix/packages/external-secrets are from ${release}. Remove image.tag or set a v${releaseMinorText}.x tag.";
      }
      {
        assertion = generic == [ ];
        message = "extraArgs sets ${lib.concatStringsSep ", " generic}, which lets ExternalSecrets write ConfigMaps and custom resources. The package grants the controller no RBAC for them and out.mkExternalSecret refuses spec.target.manifest. Remove the flag; create generic targets outside Kix.";
      }
    ];

  options = {
    image = kix.options.image {
      repository = "ghcr.io/external-secrets/external-secrets";
      tag = release;
      digest = "sha256:66fb710878cbf3eba4a927e35c5d75e29a202c9bab238aad64bfb23b786b962b";
      description = "Image of the controller, the webhook, and the cert-controller. Its major.minor must match the vendored CRDs.";
    };

    # The controller caches the Secrets its ExternalSecrets manage, so its
    # memory grows with their number and size.
    resources = kix.options.resources {
      requests = {
        cpu = "10m";
        memory = "64Mi";
      };
      limits = {
        cpu = "500m";
        memory = "512Mi";
      };
      description = "Resource requests and limits for the controller container. Raise `limits.memory` on a cluster with many ExternalSecrets. Each field keeps its default until set, and null removes a default.";
    };

    webhook.resources = kix.options.resources {
      requests = {
        cpu = "10m";
        memory = "32Mi";
      };
      limits = {
        cpu = "200m";
        memory = "128Mi";
      };
      description = "Resource requests and limits for the webhook container. Each field keeps its default until set, and null removes a default.";
    };

    certController.resources = kix.options.resources {
      requests = {
        cpu = "10m";
        memory = "32Mi";
      };
      limits = {
        cpu = "200m";
        memory = "256Mi";
      };
      description = "Resource requests and limits for the cert-controller container. Each field keeps its default until set, and null removes a default.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "--concurrent=4"
        "--loglevel=debug"
      ];
      description = "Flags appended to the controller's arguments. The package owns --enable-leader-election, --leader-election-id, --metrics-addr, --metrics-secure, --metrics-auth, and --live-addr, and refuses --unsafe-allow-generic-targets.";
    };

    env = kix.options.env;

    webhookCheck.image = kix.options.image {
      repository = "registry.k8s.io/kubectl";
      tag = "v1.36.5";
      digest = "sha256:0667e3f3e6ef435d7cd4c16684244703ebd67314c17511c2a9f87ea44f6cdf6b";
      description = "Image of the webhook check Job. It runs `kubectl create --dry-run=server`, so any kubectl image whose entrypoint is kubectl works.";
    };

    metrics = kix.options.monitor;
  };

  build = [
    (
      {
        self,
        config,
        prometheus ? null,
        ...
      }:
      let
        hasMetrics = config.metrics.enabled && prometheus != null;

        controllerLabels = labelsFor "controller";
        webhookLabels = labelsFor "webhook";
        certControllerLabels = labelsFor "cert-controller";

        podSecurityContext = {
          runAsNonRoot = true;
          seccompProfile.type = "RuntimeDefault";
        };
        containerSecurityContext = {
          allowPrivilegeEscalation = false;
          capabilities.drop = [ "ALL" ];
          readOnlyRootFilesystem = true;
        };

        subjectsFor = sa: [
          {
            kind = "ServiceAccount";
            name = sa.out.name;
            namespace = ns;
          }
        ];

        serviceAccount =
          saName:
          scope.mkResource {
            apiVersion = "v1";
            kind = "ServiceAccount";
            name = saName;
          };

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

        partOf = kind: pluralOf (lib.findFirst (s: kindOf s == kind) null crdSpecs);
        crdOf = kind: self.crds.${partOf kind};

        # Builder errors name this instance (`who`) and the consumer's
        # custom resource.
        crName =
          consumerScope: kind: args:
          "${kind} ${consumerScope.namespaceName}/${args.name}";

        # Returns `result` once every Secret selector in the store's spec has
        # a tracked name and, when `needNamespace`, a namespace. A
        # ClusterSecretStore selector without one is read from each
        # ExternalSecret's namespace (referent authentication), which Kix
        # can neither order nor check.
        checkStoreSelectors =
          what: needNamespace: args: result:
          let
            selectors = secretSelectors "spec" (args.spec or { });
            literal = builtins.filter (sel: sel.literal) selectors;
            noNamespace = builtins.filter (sel: !sel.hasNamespace) selectors;
            first = builtins.head literal;
            firstNoNamespace = builtins.head noNamespace;
          in
          if literal != [ ] then
            throw "${who}: ${what} names Secret \"${first.name}\" at ${first.path} by a literal string, so Kix neither orders the store after the Secret nor checks that it holds key \"${first.key}\". Use (<secret dependency>.out.keyRef \"${first.key}\").valueFrom.secretKeyRef, or, for a Secret created outside Kix, name = kix.untrackedRef { name = \"${first.name}\"; kind = \"Secret\"; }."
          else if needNamespace && noNamespace != [ ] then
            throw "${who}: ${what} names Secret \"${firstNoNamespace.name}\" at ${firstNoNamespace.path} without a namespace, so the controller reads it from the namespace of each ExternalSecret that uses the store, and Kix can neither order the store after it nor check its keys. Add namespace = scope.namespaceName to the selector (the namespace of this instance's secret dependency)."
          else
            result;

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

        webhookConfigNames = [
          "${name}-secretstore-validate"
          "${name}-externalsecret-validate"
        ];

        # From cert-controller-rbac.yaml at the release tag, narrowed to the
        # calls the cert-controller makes: it reads Secrets uncached by name
        # and writes the certificate Secret only. It writes a definition
        # only when the definition has a conversion webhook, which none of
        # the vendored ones has, so it gets no write access to definitions.
        certControllerRbac = mkClusterRoleSet scope {
          subjects = subjectsFor self.certControllerServiceAccount;
          roles."${name}-cert-controller" = grant [
            (apiext.customresourcedefinitions |> watch)
            (admission.validatingwebhookconfigurations |> watch)
            (
              admission.validatingwebhookconfigurations
              |> restrictTo webhookConfigNames
              |> allow [
                "update"
                "patch"
              ]
            )
            (discovery.endpointslices |> watch)
            # Events about the cluster-scoped webhook configurations go to
            # the default namespace.
            (core.events |> emit)
          ];
        };

        certControllerRoles = mkRoleSet scope {
          subjects = subjectsFor self.certControllerServiceAccount;
          roles."${name}-cert-controller" = grant [
            (
              core.secrets
              |> restrictTo [ self.webhookCertSecret.out.name ]
              |> allow [
                "get"
                "update"
                "patch"
              ]
            )
            (coord.leases |> allow [ "create" ])
            (
              coord.leases
              |> restrictTo [ certControllerLeaseName ]
              |> allow [
                "get"
                "update"
                "patch"
              ]
            )
          ];
        };

        # The cert-controller injects the CA only into configurations with
        # this label (pkg/controllers/webhookconfig/webhookconfig.go), and
        # only into entries whose name ends in external-secrets.io.
        webhookConfig =
          configName: entries:
          scope.mkClusterResource {
            apiVersion = "admissionregistration.k8s.io/v1";
            kind = "ValidatingWebhookConfiguration";
            name = configName;
            labels."external-secrets.io/component" = "webhook";
            extra.webhooks = map (e: {
              name = "validate.${e.singular}.external-secrets.io";
              rules = [
                {
                  apiGroups = [ "external-secrets.io" ];
                  apiVersions = [ "v1" ];
                  operations = [
                    "CREATE"
                    "UPDATE"
                    "DELETE"
                  ];
                  resources = [ "${e.singular}s" ];
                  inherit (e) scope;
                }
              ];
              clientConfig.service = {
                name = webhookServiceName;
                namespace = ns;
                path = "/validate-external-secrets-io-v1-${e.singular}";
              };
              admissionReviewVersions = [
                "v1"
                "v1beta1"
              ];
              sideEffects = "None";
              timeoutSeconds = 5;
              failurePolicy = "Fail";
            }) entries;
          };

        metricsServiceFor =
          workload: labels:
          if hasMetrics then
            workload
            |> kix.service.fromWorkload {
              name = "${workload.out.name}-metrics";
              inherit labels;
              ports = [
                {
                  name = "metrics";
                  port = ports.metrics;
                  targetPort = "metrics";
                  protocol = "TCP";
                }
              ];
            }
            |> scope.mkResource
          else
            null;

        # The check: a server-side dry-run create of an ExternalSecret and of
        # a SecretStore, one per webhook configuration, since the
        # cert-controller injects the CA into each separately. With
        # failurePolicy Fail the API server admits each only after calling
        # the webhook and trusting its certificate, which also needs the CA
        # in that configuration. Until then kubectl fails and the Job
        # restarts the container.
        checkName = "${name}-webhook-check";
        checkLabels = labelsFor "webhook-check";
        # A fixed name would fail with AlreadyExists when an object of that
        # name exists.
        checkMetadata = {
          generateName = "${checkName}-";
          namespace = ns;
        };
        checkManifests = {
          "externalsecret.json" = builtins.toJSON {
            apiVersion = "external-secrets.io/v1";
            kind = "ExternalSecret";
            metadata = checkMetadata;
            spec = {
              secretStoreRef = {
                name = checkName;
                kind = "SecretStore";
              };
              data = [
                {
                  secretKey = "check";
                  remoteRef.key = "check";
                }
              ];
            };
          };
          # The fake provider needs no credentials; its webhook validation
          # requires a non-empty key and value in each entry.
          "secretstore.json" = builtins.toJSON {
            apiVersion = "external-secrets.io/v1";
            kind = "SecretStore";
            metadata = checkMetadata;
            spec.provider.fake.data = [
              {
                key = "check";
                value = "check";
              }
            ];
          };
        };

        # Refuses a generic target and sets empty template metadata when the
        # spec has none (see out.mkExternalSecret in the header).
        pinExternalSecret =
          consumerScope: args:
          let
            spec = args.spec or { };
            target = spec.target or { };
            what = crName consumerScope "ExternalSecret" args;
          in
          if target ? manifest then
            throw "${who}: ${what} sets spec.target.manifest, a generic target. The controller writes one only with --unsafe-allow-generic-targets, and the package grants it no RBAC for ConfigMaps or custom resources. Write a Secret target, or create this ExternalSecret outside Kix."
          else
            args
            // {
              spec = spec // {
                target = target // {
                  template = {
                    metadata = { };
                  }
                  // (target.template or { });
                };
              };
            };

        withSecretRef =
          consumerScope: what: args: cr:
          let
            inherit (args) spec;
            target = spec.target;
            template = target.template;
            policy = target.creationPolicy or "Owner";
            # A plain name: the reference requires the ExternalSecret below.
            secretName = target.name or args.name;
            dataKeys = map (d: d.secretKey) (spec.data or [ ]);
            templateKeys = builtins.attrNames (template.data or { });
            # The Secret's keys, or null when dataFrom or templateFrom adds
            # keys only the store knows, or when creationPolicy Merge keeps
            # the keys another writer put in the Secret. Template data replaces the synced
            # keys unless mergePolicy is Merge (ApplyTemplate in
            # pkg/controllers/externalsecret/externalsecret_controller_template.go).
            knownKeys =
              if policy == "Merge" || (spec.dataFrom or [ ]) != [ ] || (template.templateFrom or [ ]) != [ ] then
                null
              else if templateKeys == [ ] then
                dataKeys
              else
                templateKeys ++ lib.optionals ((template.mergePolicy or "Replace") == "Merge") dataKeys;
            secretRef =
              {
                keys,
                type ? null,
              }:
              let
                unknown = if knownKeys == null then [ ] else builtins.filter (k: !(builtins.elem k knownKeys)) keys;
              in
              if policy == "None" then
                throw "${who}: out.secretRef of ${what}: creationPolicy None writes no Secret. Use another creationPolicy, or reference the Secret through its own dependency."
              else if unknown != [ ] then
                throw "${who}: out.secretRef of ${what} declares ${lib.concatStringsSep ", " unknown}, which the ExternalSecret does not write; it writes ${lib.concatStringsSep ", " knownKeys}. Declare only those keys, or add the missing ones to spec.data or spec.target.template.data."
              else
                consumerScope.mkSecretRef {
                  name = secretName;
                  inherit keys;
                  type =
                    if type != null then
                      type
                    else if (template.type or "") != "" then
                      template.type
                    else
                      "Opaque";
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
        serviceAccount = serviceAccount name;
        webhookServiceAccount = serviceAccount "${name}-webhook";
        certControllerServiceAccount = serviceAccount "${name}-cert-controller";

        controllerClusterRole = controllerRbac."${name}-controller";
        controllerClusterRoleBinding = controllerRbac."${name}-controller-binding";
        leaderElectionRole = controllerLeaderRbac."${name}-leader-election";
        leaderElectionRoleBinding = controllerLeaderRbac."${name}-leader-election-binding";
        certControllerClusterRole = certControllerRbac."${name}-cert-controller";
        certControllerClusterRoleBinding = certControllerRbac."${name}-cert-controller-binding";
        certControllerRole = certControllerRoles."${name}-cert-controller";
        certControllerRoleBinding = certControllerRoles."${name}-cert-controller-binding";

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

        # Empty at creation; the cert-controller writes ca.crt, ca.key,
        # tls.crt, and tls.key into it and never creates it.
        webhookCertSecret = scope.mkSecret {
          name = "${name}-webhook-tls";
          keys = [ ];
        };

        webhookDeployment =
          kix.withMounts
            [
              (kix.mount.secret self.webhookCertSecret {
                name = "certs";
                mountPath = certDir;
              })
            ]
            {
              name = "${name}-webhook";
              spec = {
                replicas = kix.availability.pick availability {
                  none = 1;
                  pod = 2;
                  node = 2;
                  zone = 2;
                };
                selector.matchLabels = webhookLabels;
                template.spec = {
                  serviceAccount = self.webhookServiceAccount;
                  terminationGracePeriodSeconds = 30;
                  securityContext = podSecurityContext;
                  containers = [
                    {
                      name = "webhook";
                      image = kix.image.ref config.image;
                      imagePullPolicy = config.image.pullPolicy;
                      args = [
                        "webhook"
                        "--port=${toString ports.webhook}"
                        "--dns-name=${webhookServiceName}.$(POD_NAMESPACE).svc"
                        "--cert-dir=${certDir}"
                        "--metrics-addr=:${toString ports.metrics}"
                        "--healthz-addr=:${toString ports.webhookHealth}"
                      ];
                      env = [
                        {
                          name = "POD_NAMESPACE";
                          valueFrom.fieldRef.fieldPath = "metadata.namespace";
                        }
                      ];
                      ports = [
                        (kix.port "metrics" ports.metrics)
                        (kix.port "webhook" ports.webhook)
                        (kix.port "ready" ports.webhookHealth)
                      ];
                      # The health server starts only after the webhook has
                      # waited up to 2 minutes for a valid certificate in
                      # certDir (waitForCerts in cmd/controller/webhook.go),
                      # so the startup probe allows 150 s before liveness
                      # applies.
                      startupProbe = {
                        httpGet = {
                          path = "/healthz";
                          port = "ready";
                        };
                        periodSeconds = 5;
                        failureThreshold = 30;
                      };
                      livenessProbe = {
                        httpGet = {
                          path = "/healthz";
                          port = "ready";
                        };
                        periodSeconds = 5;
                      };
                      # Ready once the certificate in certDir is valid for
                      # the Service name.
                      readinessProbe = {
                        httpGet = {
                          path = "/readyz";
                          port = "ready";
                        };
                        initialDelaySeconds = 20;
                        periodSeconds = 5;
                      };
                      resources = config.webhook.resources;
                      securityContext = containerSecurityContext;
                    }
                  ];
                };
              };
            }
          |> scope.mkDeployment;

        # Also the webhook's metrics Service, so no second Service carries
        # the webhook's labels.
        webhookService = scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = webhookServiceName;
          labels = webhookLabels;
          spec = {
            selector = self.webhookDeployment.out.selector;
            ports = [
              {
                name = "webhook";
                port = 443;
                targetPort = ports.webhook;
                protocol = "TCP";
              }
            ]
            ++ lib.optional hasMetrics {
              name = "metrics";
              port = ports.metrics;
              targetPort = ports.metrics;
              protocol = "TCP";
            };
          };
        };

        secretStoreWebhook = webhookConfig (builtins.elemAt webhookConfigNames 0) [
          {
            singular = "secretstore";
            scope = "Namespaced";
          }
          {
            singular = "clustersecretstore";
            scope = "Cluster";
          }
        ];
        externalSecretWebhook = webhookConfig (builtins.elemAt webhookConfigNames 1) [
          {
            singular = "externalsecret";
            scope = "Namespaced";
          }
        ];

        # Its readiness waits for the webhook pods' endpoints, so it does not
        # require the webhook Deployment, whose pods wait for the
        # certificate it writes.
        certControllerDeployment = scope.mkDeployment {
          name = "${name}-cert-controller";
          requires = [
            self.secretStoreWebhook
            self.externalSecretWebhook
          ];
          spec = {
            replicas = kix.availability.pick availability {
              none = 1;
              pod = 1;
              node = 2;
              zone = 2;
            };
            selector.matchLabels = certControllerLabels;
            template.spec = {
              serviceAccount = self.certControllerServiceAccount;
              terminationGracePeriodSeconds = 30;
              securityContext = podSecurityContext;
              containers = [
                {
                  name = "cert-controller";
                  image = kix.image.ref config.image;
                  imagePullPolicy = config.image.pullPolicy;
                  args = [
                    "certcontroller"
                    "--service-name=${webhookServiceName}"
                    "--service-namespace=${ns}"
                    "--secret-name=${self.webhookCertSecret.out.name}"
                    "--secret-namespace=${ns}"
                    "--metrics-addr=:${toString ports.metrics}"
                    "--healthz-addr=:${toString ports.webhookHealth}"
                    "--enable-leader-election=true"
                    # Caches only definitions labelled
                    # external-secrets.io/component=controller and webhook
                    # configurations labelled =webhook, instead of every one
                    # in the cluster.
                    "--enable-partial-cache=true"
                  ];
                  ports = [
                    (kix.port "metrics" ports.metrics)
                    (kix.port "ready" ports.webhookHealth)
                  ];
                  livenessProbe = {
                    httpGet = {
                      path = "/healthz";
                      port = "ready";
                    };
                    initialDelaySeconds = 20;
                    periodSeconds = 5;
                  };
                  readinessProbe = {
                    httpGet = {
                      path = "/readyz";
                      port = "ready";
                    };
                    initialDelaySeconds = 20;
                    periodSeconds = 5;
                  };
                  resources = config.certController.resources;
                  securityContext = containerSecurityContext;
                }
              ];
            };
          };
        };

        controllerMetricsService = metricsServiceFor self.deployment controllerLabels;
        certControllerMetricsService = metricsServiceFor self.certControllerDeployment certControllerLabels;

        webhookCheckServiceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          name = checkName;
          labels = checkLabels;
          extra.automountServiceAccountToken = true;
        };

        # A dry-run create needs the create verb; the API server persists
        # nothing.
        webhookCheckRbac = mkRoleSet scope {
          subjects = subjectsFor self.webhookCheckServiceAccount;
          labels = checkLabels;
          roles.${checkName} = grant [
            (
              map es [
                "externalsecrets"
                "secretstores"
              ]
              |> allow [ "create" ]
            )
          ];
        };

        webhookCheckManifest = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = checkName;
          labels = checkLabels;
          data = checkManifests;
        };

        webhookCheck =
          kix.withMounts
            [
              (kix.mount.configMap self.webhookCheckManifest {
                name = "manifest";
                mountPath = "/check";
                readOnly = true;
              })
              (kix.mount.emptyDir {
                name = "tmp";
                mountPath = "/tmp";
              })
            ]
            {
              name = checkName;
              labels = checkLabels;
              # A Job's pod template is immutable, so a changed check
              # replaces the Job.
              annotations.${kix.keys.rerun} = kix.keyValues.rerunOnChange;
              requires = [
                self.webhookDeployment
                self.webhookService
                self.certControllerDeployment
                self.secretStoreWebhook
                self.externalSecretWebhook
                (crdOf "ExternalSecret")
                (crdOf "SecretStore")
              ]
              ++ builtins.attrValues self.webhookCheckRbac;
              spec = {
                # The container restarts with the kubelet's back-off (10 s,
                # doubling, capped at 300 s), so six restarts wait about ten
                # minutes for the cert-controller to inject the CA.
                backoffLimit = 6;
                template = {
                  metadata = {
                    labels = checkLabels;
                    annotations."checksum/manifest" = self.webhookCheckManifest.out.identityHash;
                  };
                  spec = {
                    restartPolicy = "OnFailure";
                    serviceAccount = self.webhookCheckServiceAccount;
                    enableServiceLinks = false;
                    # The kubectl image declares user 0.
                    securityContext = {
                      runAsNonRoot = true;
                      runAsUser = 65532;
                      runAsGroup = 65532;
                      seccompProfile.type = "RuntimeDefault";
                    };
                    containers = [
                      (
                        {
                          name = "webhook-check";
                          image = kix.image.ref config.webhookCheck.image;
                          args = [
                            "create"
                            "--dry-run=server"
                          ]
                          ++ map (f: "--filename=/check/${f}") (builtins.attrNames checkManifests)
                          ++ [
                            "--output=name"
                          ];
                          # kubectl writes its discovery cache under $HOME.
                          env = [
                            {
                              name = "HOME";
                              value = "/tmp";
                            }
                          ];
                          securityContext = containerSecurityContext;
                          # A ResourceQuota on requests or limits refuses a
                          # pod that does not set them, and every custom
                          # resource built from `out` waits on this Job.
                          resources = {
                            requests = {
                              cpu = "10m";
                              memory = "32Mi";
                            };
                            limits = {
                              cpu = "200m";
                              memory = "128Mi";
                            };
                          };
                        }
                        // lib.optionalAttrs (config.webhookCheck.image.pullPolicy != null) {
                          imagePullPolicy = config.webhookCheck.image.pullPolicy;
                        }
                      )
                    ];
                  };
                };
              };
            }
          |> scope.mkJob;

        root = {
          resource = self.deployment;
          requires = lib.filter (r: r != null) (
            [
              self.serviceAccount
              self.controllerClusterRole
              self.controllerClusterRoleBinding
              self.leaderElectionRole
              self.leaderElectionRoleBinding
              self.certControllerClusterRole
              self.certControllerClusterRoleBinding
              self.certControllerRole
              self.certControllerRoleBinding
              self.webhookService
              self.webhookDeployment
              self.certControllerDeployment
              self.controllerMetricsService
              self.certControllerMetricsService
              (self.controllerMonitor or null)
              (self.webhookMonitor or null)
              (self.certControllerMonitor or null)
            ]
            ++ builtins.attrValues self.crds
          );
          postHooks = [ self.webhookCheck ];

          out = {
            crds = builtins.listToAttrs (
              map (spec: lib.nameValuePair (kindOf spec) self.crds.${pluralOf spec}) (
                builtins.filter (spec: !(builtins.elem (kindOf spec) unexposedKinds)) crdSpecs
              )
            );

            mkSecretStore =
              consumerScope: args:
              checkStoreSelectors (crName consumerScope "SecretStore" args) false args (
                (crdOf "SecretStore").out.mkCR consumerScope args
              );

            mkClusterSecretStore =
              consumerScope: args:
              checkStoreSelectors "ClusterSecretStore ${args.name}" true args (
                (crdOf "ClusterSecretStore").out.mkCR consumerScope args
              );

            mkExternalSecret =
              consumerScope: args:
              let
                pinned = pinExternalSecret consumerScope args;
              in
              withSecretRef consumerScope (crName consumerScope "ExternalSecret" args) pinned (
                (crdOf "ExternalSecret").out.mkCR consumerScope pinned
              );
          };
        };
      }
    )

    # DI passes a build function only the arguments its formals name, so
    # each wrapper names every argument kix.monitor reads.
    (
      {
        self,
        config,
        scope,
        lib,
        prometheus ? null,
        ...
      }@args:
      kix.monitor {
        service = "controllerMetricsService";
        monitorPart = "controllerMonitor";
        rulesPart = "controllerAlerts";
      } args
    )
    (
      {
        self,
        config,
        scope,
        lib,
        prometheus ? null,
        ...
      }@args:
      kix.monitor {
        name = "${scope.instanceName}-webhook";
        service = "webhookService";
        monitorPart = "webhookMonitor";
        rulesPart = "webhookAlerts";
      } args
    )
    (
      {
        self,
        config,
        scope,
        lib,
        prometheus ? null,
        ...
      }@args:
      kix.monitor {
        name = "${scope.instanceName}-cert-controller";
        service = "certControllerMetricsService";
        monitorPart = "certControllerMonitor";
        rulesPart = "certControllerAlerts";
      } args
    )
  ];
}

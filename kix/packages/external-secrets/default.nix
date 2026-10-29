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
  c = import ./common.nix { inherit lib kix scope; };
  inherit (c)
    release
    who
    ports
    crdSpecs
    kindOf
    pluralOf
    unexposedKinds
    crdOf
    versionParts
    releaseMinor
    releaseMinorText
    ;

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
    ./controller.nix
    ./webhook.nix

    (
      { self, ... }:
      let
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
                (crdOf self "SecretStore").out.mkCR consumerScope args
              );

            mkClusterSecretStore =
              consumerScope: args:
              checkStoreSelectors "ClusterSecretStore ${args.name}" true args (
                (crdOf self "ClusterSecretStore").out.mkCR consumerScope args
              );

            mkExternalSecret =
              consumerScope: args:
              let
                pinned = pinExternalSecret consumerScope args;
              in
              withSecretRef consumerScope (crName consumerScope "ExternalSecret" args) pinned (
                (crdOf self "ExternalSecret").out.mkCR consumerScope pinned
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

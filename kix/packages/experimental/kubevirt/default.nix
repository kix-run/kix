# kubevirt: KubeVirt, which runs virtual machines as pods.
#
# The package renders virt-operator, its roles (rbac/*.json, vendored from
# upstream's operator bundle), the KubeVirt custom resource definition, the
# PriorityClass `kubevirt-cluster-critical`, and a KubeVirt resource.
# virt-operator then runs virt-api and virt-controller in this namespace and
# virt-handler on every node, and installs the CRDs of its own kinds
# (VirtualMachine, VirtualMachineInstance, and the rest). The deploy waits
# for the KubeVirt resource to reach phase Deployed.
#
# A cluster runs one instance: the KubeVirt CRD, the PriorityClass, the
# admin ClusterRole `kubevirt.io:operator`, and the CRDs and webhooks
# virt-operator installs are cluster-wide, so `conflictsWith` refuses a
# second instance. virt-handler runs privileged, as root, in the host PID
# namespace, so the namespace is labelled for the privileged Pod Security
# level.
#
# Nodes need /dev/kvm. On nodes without it, set
# `extraSpec.configuration.developerConfiguration.useEmulation = true`, or
# virtual machines stay ErrorUnschedulable and a deploy that builds one
# waits until it times out.
#
# Upgrades: virt-operator moves the operands to its own version once its
# Deployment changes. Running virtual machines keep their old virt-launcher
# pods until they restart or migrate. KubeVirt supports updating only from
# one release to the next: from the latest patch of one minor to the latest
# patch of the next. This package moved from v1.5.0 to v1.9.1 in one step,
# which skips that path. To follow it instead, set `image.tag` (and
# `image.digest`) to each step in turn and deploy once per step: v1.5.3,
# v1.6.6, v1.7.4, v1.8.4, then remove the setting. The package accepts
# these minors because the vendored CRD and roles of v1.9.1 contain every
# field and rule the older releases use. Upstream documents no way back.
#
# Minimal instance:
#
#   instances.kubevirt.kubevirt.package = packages.experimental.kubevirt;
#
# A consumer takes `kubevirt` as a dependency and builds virtual machines
# with out.mkVirtualMachine. A disk the VM imports belongs in its
# `dataVolumeTemplates`, which needs a `cdi` instance in the cluster;
# clusters/test-virtualization.nix has the full example.
#
#   vm = kubevirt.out.mkVirtualMachine scope {
#     name = "demo";
#     spec = {
#       runStrategy = "Always";
#       dataVolumeTemplates = [ { metadata.name = "demo-disk"; spec = { ... }; } ];
#       template.spec = { domain = { ... }; volumes = [ ... ]; };
#     };
#   };
#
# Network policy: with an enforcer, the API server reaches virt-operator's
# admission webhook on 8444 and virt-api (an aggregated API and admission
# webhooks) on 8443. virt-api reaches virt-handler's console server on 8186,
# virt-handler pods reach each other for live migration, and every operand
# and virt-operator's install strategy Job reach DNS and the API server.
# virt-launcher pods run in the virtual machine's namespace and are the
# consumer's to allow (out.operandSelectors.virtLauncher). virt-exportproxy
# gets DNS, the API server, ingress from any pod on 8443, and egress to any
# pod on 8443, where the export server pods in the VirtualMachine
# namespaces listen. Those export server pods are the consumer's to allow.
# virt-template-apiserver (an aggregated API) and virt-template-controller
# (admission webhooks) get DNS, the API server, and ingress from the API
# server on 9443. virt-operator runs them unless `extraSpec` turns the
# Template feature gate off. The package writes no policy for
# virt-synchronization-controller, which runs only with the alpha
# DecentralizedLiveMigration gate and talks to other clusters.
#
# Monitoring: virt-operator creates its own ServiceMonitor and
# PrometheusRule when the prometheus-operator CRDs exist, in
# `monitorNamespace` (this namespace by default). Setting
# `extraSpec.monitorNamespace` and `extraSpec.monitorAccount` puts them in a
# Prometheus's namespace, outside the Kix graph.
#
# Escape hatches: `extraSpec`, deep-merged into the KubeVirt resource's
# spec; `partsOverlays`; `scope.mkCR kubevirt.out.crds.VirtualMachine` for a
# VirtualMachine out.mkVirtualMachine refuses.
#
# `out`:
#   out.crds.VirtualMachine
#   out.mkVirtualMachine scope { name; spec; annotations ? { }; requires ? [ ]; ... }
#       A VirtualMachine the deploy waits on: until printableStatus is
#       Running for runStrategy "Always" or running = true, and Stopped for
#       "Halted" or running = false. Any other run strategy is refused,
#       because the VM's state then depends on a user or the guest. With
#       `dataVolumeTemplates`, the VM also waits for the DataVolume CRD of
#       the cluster's `cdi` instance, and is refused without one.
#   out.operandSelectors.virtLauncher
#       Pod labels of the virt-launcher pods that run each VM.
#   out.extraImages
#       Every image virt-operator runs, digest-pinned.
#   out.version
#       The KubeVirt version `image.tag` names.
#
# root = the virt-operator Deployment.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  # The upstream release: meta.version, the default image.tag, and the tag
  # in crds/sources.txt and rbac/sources.txt (kix-lib test
  # kubevirt-cdi-sources-match-release).
  release = "v1.9.1";

  # "v1.9.1" -> "v1.9"; null for a tag that is not a vX.Y release.
  # Upstream tags every release with the leading v.
  minorOf =
    tag: lib.mapNullable (m: "v${builtins.head m}") (builtins.match "v([0-9]+\\.[0-9]+)(\\..*)?" tag);

  # Minors image.tag may name: the release's own, and the older steps of
  # upstream's update path, so that a cluster can walk up one minor per
  # deploy. A minor belongs here only while the vendored CRD and roles hold
  # every field and rule it uses. Check that when `release` moves.
  acceptedMinors = [
    "v1.5"
    "v1.6"
    "v1.7"
    "v1.8"
    (minorOf release)
  ];

  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "kubevirt ${ns}/${name}";

  readJSON = file: builtins.fromJSON (builtins.readFile file);

  # Each operand image: the index digest of its release tag (a digest
  # applies while the image keeps that tag), the virt-operator variable it
  # is passed in, and what runs it.
  operands = {
    virt-api = {
      digest = "sha256:d341c751dbe632d183989cce78203a888293e0e2a32719f32461bd6273322485";
      env = "VIRT_API_IMAGE";
      what = "virt-api";
    };
    virt-controller = {
      digest = "sha256:75c94c787eec15458729848e00fe0b421ca8998c6219de8c2d3cae72ff0bd287";
      env = "VIRT_CONTROLLER_IMAGE";
      what = "virt-controller";
    };
    virt-handler = {
      digest = "sha256:c23b635ea4aff7f0779c6c061c431da0469c7796255e6de90a5970236b5ea61b";
      env = "VIRT_HANDLER_IMAGE";
      what = "virt-handler on every node";
    };
    virt-launcher = {
      digest = "sha256:53e6d12197761cda653201f82e295ac6098d689a58bc2c68df0970c248d61fa6";
      env = "VIRT_LAUNCHER_IMAGE";
      what = "the pod of each virtual machine";
    };
    virt-exportproxy = {
      digest = "sha256:fe9a0a297e7b407c3a322c6f5fccba5313c668907c30cb0b80b8c51bcdea640a";
      env = "VIRT_EXPORTPROXY_IMAGE";
      what = "virt-exportproxy, with the VMExport feature gate";
    };
    virt-exportserver = {
      digest = "sha256:76c01dca74921eb5fd74d00b82e77a60d58e8213c72d84cc66a3bc92679690b8";
      env = "VIRT_EXPORTSERVER_IMAGE";
      what = "a VirtualMachineExport's server pod";
    };
    libguestfs-tools = {
      digest = "sha256:08df144de2a77ad8259f93df3dca7e13e73669651ce8fbe63f58c23e4fdd6427";
      env = "GS_IMAGE";
      what = "`virtctl guestfs` pods, on demand";
    };
    pr-helper = {
      digest = "sha256:c7724681efa3297091d0ce0edf4fda52c062455fb83b76484499a46ae261f61d";
      env = "PR_HELPER_IMAGE";
      what = "the persistent reservation helper, with the PersistentReservation feature gate";
    };
    sidecar-shim = {
      digest = "sha256:d48c6af64305c28de7e9a5509a11737b115cc0193f57f2a0f42faff85bebe5cd";
      env = "SIDECAR_SHIM_IMAGE";
      what = "hook sidecars, on demand";
    };
    virt-synchronization-controller = {
      digest = "sha256:5f3da789a7b7a4febb1ece9f4a085ceb73aabcd468af84563ea7b6809341eb10";
      env = "VIRT_SYNCHRONIZATIONCONTROLLER_IMAGE";
      what = "virt-synchronization-controller, with the DecentralizedLiveMigration feature gate";
    };
    # virt-template has its own releases. virt-operator runs the version its
    # embedded bundle names (pkg/virt-operator/resource/generate/components/
    # data/virt-template/install-virt-operator.yaml at the release), and
    # takes these variables as whole image references.
    virt-template-apiserver = {
      tag = "v0.2.3";
      digest = "sha256:27defde24b4a4705d6096a86d134df0dc324243b56be8f0c057e1882c6da338b";
      env = "VIRT_TEMPLATE_APISERVER_IMAGE";
      what = "virt-template-apiserver, unless the Template feature gate is off";
    };
    virt-template-controller = {
      tag = "v0.2.3";
      digest = "sha256:b45ac55de5fc9dbbee14974b45718c41eaed4d4979f92677dab3500598e33d22";
      env = "VIRT_TEMPLATE_CONTROLLER_IMAGE";
      what = "virt-template-controller, unless the Template feature gate is off";
    };
  };

  # Labels virt-operator puts on the pods it runs
  # (pkg/virt-operator/resource/generate/components and strategy_job.go at
  # the release).
  podLabels = component: { "kubevirt.io" = component; };

  tcp = port: {
    inherit port;
    protocol = "TCP";
  };
in
{
  meta = {
    version = lib.removePrefix "v" release;
    description = "KubeVirt, for running virtual machines on Kubernetes: virt-operator and a KubeVirt resource";
    owner = "platform";
    defaultAliases = [ "kubevirt" ];
    # One instance per cluster; see the header.
    conflictsWith = [ "cluster:kubevirt" ];
    # KubeVirt's support matrix (kubevirt/sig-release,
    # releases/k8s-support-matrix.md) lists the Kubernetes versions each
    # minor release supports. Move both bounds with `release`.
    k8s = {
      minVersion = "1.34";
      maxVersion = "1.36";
      reason = "[K0297] KubeVirt ${release} supports Kubernetes 1.34 to 1.36 only. Move the cluster to a Kubernetes version in that range, or use a Kix release whose kubevirt package supports it";
    };
    # virt-operator runs virt-handler on every node, privileged, as root, in
    # the host PID namespace. Upstream labels its namespace the same way.
    podSecurity = "privileged";
    # The API server calls virt-operator's admission webhook, which the
    # operator serves on 8444 behind the Service it creates.
    network.intents.webhook.ingress = [
      {
        from = "apiserver";
        ports = [ (tcp 8444) ];
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
        assertion = builtins.elem (minorOf imageTag) acceptedMinors;
        message = "image.tag \"${imageTag}\" is not a ${lib.concatStringsSep ", " acceptedMinors} release (upstream tags look like ${release}), and the CRD and roles under kix/packages/experimental/kubevirt/{crds,rbac} are vendored from ${release}. Remove image.tag or set a tag of one of those minors. To move to another release, change release in kix/packages/experimental/kubevirt/default.nix and the tag in crds/sources.txt and rbac/sources.txt, then run uv run scripts/vendor-crds.py kubevirt.";
      }
    ]
    ++ map (n: {
      assertion = config.operandImages.${n}.pullPolicy == null;
      message = "operandImages.${n}.pullPolicy = \"${
        toString config.operandImages.${n}.pullPolicy
      }\" has no effect: virt-operator gives every operand the KubeVirt resource's imagePullPolicy, which is image.pullPolicy. Remove it.";
    }) (builtins.attrNames operands);

  options = {
    image = kix.options.image {
      repository = "quay.io/kubevirt/virt-operator";
      tag = release;
      digest = "sha256:a8adf7b772e9ce0bf7e2ce889910fc41ebadf552c9dbe843e9b86641e34f5df9";
      description = "Image of virt-operator. Its minor must be the release's, or an older step of upstream's update path (v1.5 to v1.8) while walking up one minor per deploy. Each operand image defaults to this repository's registry and path with its own name (quay.io/kubevirt/<name>) and to this tag, and every operand uses this image's pullPolicy.";
    };

    operandImages = lib.mapAttrs (
      n: operand:
      kix.options.image {
        repository = "quay.io/kubevirt/${n}";
        tag = operand.tag or release;
        inherit (operand) digest;
        tagText = if operand ? tag then null else "config.image.tag";
        pullPolicy = null;
        description = "Image virt-operator uses for ${operand.what} (${operand.env}). Listed in out.extraImages. Its repository follows image.repository and its tag ${
          if operand ? tag then "is virt-template's own release" else "follows image.tag"
        }. The KubeVirt resource's imagePullPolicy applies, so pullPolicy must stay null.";
      }
    ) operands;

    # Requests from kubevirt-operator.yaml at the release. Upstream sets no
    # limits; these are the package's.
    resources = kix.options.resources {
      requests = {
        cpu = "10m";
        memory = "450Mi";
      };
      limits = {
        cpu = "1";
        memory = "1Gi";
      };
    };

    extraSpec = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Fields deep-merged into the KubeVirt resource's spec, such as `configuration.developerConfiguration.featureGates`, `configuration.developerConfiguration.useEmulation` (for nodes without /dev/kvm), `workloads`, or `monitorNamespace` and `monitorAccount`. The package refuses `infra.replicas`, which follows the instance's availability, `imagePullPolicy`, which is image.pullPolicy, and `imageRegistry` and `imageTag`, which image and operandImages set.";
    };
  };

  config =
    { config, ... }:
    {
      operandImages = lib.mapAttrs (
        n: operand:
        {
          repository = lib.mkDefault "${dirOf config.image.repository}/${n}";
        }
        // lib.optionalAttrs (!(operand ? tag)) { tag = lib.mkDefault config.image.tag; }
      ) operands;
    };

  build =
    {
      self,
      config,
      cdi ? null,
      ...
    }:
    let
      pick = kix.availability.pick availability;
      operandRefs = lib.mapAttrs (_: kix.image.ref) config.operandImages;

      # virt-operator reads the operand tag from the text after
      # `virt-operator:` in this variable, so `repo:tag@digest` would give
      # every operand the tag `tag@digest`. With `repo@digest` it takes
      # KUBEVIRT_VERSION as the tag (pkg/virt-operator/util/config.go), and
      # the strategy Job runs the value as its image.
      operatorImage =
        if kix.image.isPinned config.image then
          builtins.unsafeDiscardStringContext "${config.image.repository}@${config.image.digest}"
        else
          kix.image.ref config.image;

      # Without infra.replicas, virt-operator runs two virt-controller
      # replicas and max(2, nodes / 10) virt-api replicas, so the package
      # sets it only at `none`. virt-operator logs an AdvancedFeatureUse
      # event when it is set.
      baseSpec = {
        monitorNamespace = ns;
      }
      // lib.optionalAttrs (availability == "none") { infra.replicas = 1; }
      // lib.optionalAttrs (config.image.pullPolicy != null) {
        imagePullPolicy = config.image.pullPolicy;
      };

      # Policies for the pods virt-operator runs in this namespace. The spec
      # is read only when an enforcer exists.
      operandPolicy =
        suffix: selector:
        {
          intents,
          extra ? _: { },
        }:
        kix.operandPolicy {
          inherit scope;
          name = "${name}-${suffix}";
          spec =
            let
              netpol = scope.networkPolicyEnforcer.netpol;
              translated = netpol.translateIntentRules { intents.operand = intents; };
              more = extra netpol;
              egress = translated.egressRules ++ more.egress or [ ];
              ingress = translated.ingressRules ++ more.ingress or [ ];
            in
            netpol.mkEndpointSelector selector
            // lib.optionalAttrs (egress != [ ]) { inherit egress; }
            // lib.optionalAttrs (ingress != [ ]) { inherit ingress; };
        };
      clusterAccess = [
        { to = "dns"; }
        { to = "apiserver"; }
      ];
      consoleServer = [ (tcp 8186) ];

      # virt-operator runs virt-template unless the Template feature gate is
      # disabled or configuration.virtTemplateDeployment.enabled is false
      # (pkg/virt-operator/resource/apply/reconcile.go,
      # virtTemplateDeploymentEnabled). The gate is Beta, so it is on by
      # default.
      templateEnabled =
        let
          disabled =
            lib.attrByPath
              [
                "configuration"
                "developerConfiguration"
                "disabledFeatureGates"
              ]
              [ ]
              config.extraSpec;
          enabled = lib.attrByPath [
            "configuration"
            "virtTemplateDeployment"
            "enabled"
          ] null config.extraSpec;
        in
        !(builtins.isList disabled && builtins.elem "Template" disabled) && enabled != false;

      # Labels of the virt-template pods (the embedded virt-template bundle).
      templateLabels = component: {
        "app.kubernetes.io/name" = "virt-template";
        control-plane = component;
      };

      mkVirtualMachine =
        consumerScope: args:
        let
          vmName = args.name or "<unnamed>";
          consumer = "${consumerScope.namespaceName or "?"}/${consumerScope.instanceName or "?"}";
          what = "VirtualMachine \"${vmName}\" in ${consumer}";
          spec =
            args.spec or (scope.fail {
              package = "kubevirt";
              message = "out.mkVirtualMachine: ${what} has no spec.";
              fix = "Pass spec with runStrategy and template.";
            });
          accepted = "out.mkVirtualMachine accepts runStrategy \"Always\" or \"Halted\", or running = true or false, and waits for the VM to reach Running or Stopped";
          refusal =
            reason:
            scope.fail {
              package = "kubevirt";
              message = "${what} ${reason}.";
              fix = "${accepted}.";
            };
          printableStatus =
            if (spec ? runStrategy) && (spec ? running) then
              refusal "sets both runStrategy and running, which KubeVirt rejects"
            else if !(spec ? runStrategy) && !(spec ? running) then
              refusal "sets neither runStrategy nor running, which KubeVirt rejects"
            else if spec ? running then
              if spec.running == true then
                "Running"
              else if spec.running == false then
                "Stopped"
              else
                refusal "sets running to ${builtins.toJSON spec.running}, which is not a boolean"
            else if spec.runStrategy == "Always" then
              "Running"
            else if spec.runStrategy == "Halted" then
              "Stopped"
            else
              refusal "sets runStrategy ${builtins.toJSON spec.runStrategy}. With Manual the VM waits for a user to start it, and with RerunOnFailure or Once it waits on the guest, so a deploy would wait until it times out. Build such a VM with scope.mkCR kubevirt.out.crds.VirtualMachine { ... }";
          dataVolumeCrd =
            if (spec.dataVolumeTemplates or [ ]) == [ ] then
              [ ]
            else if cdi == null then
              scope.fail {
                package = "kubevirt";
                message = "${what} has dataVolumeTemplates, and the cluster has no cdi instance to import them.";
                fix = "Add a cdi instance (instances.cdi.cdi.package = packages.experimental.cdi).";
              }
            else
              [ cdi.out.crds.DataVolume ];
        in
        self.crds.virtualMachines.out.mkCR consumerScope (
          args
          // {
            requires = (args.requires or [ ]) ++ dataVolumeCrd;
            annotations = (args.annotations or { }) // {
              ${kix.keys.readiness} = builtins.toJSON {
                path = "/status/printableStatus";
                equals = printableStatus;
              };
            };
          }
        );
    in
    {
      # The install strategy Job virt-operator starts runs as
      # `kubevirt-operator` (pkg/virt-operator/strategy_job.go), and virt-api
      # trusts that name, so the ServiceAccount keeps it.
      serviceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "kubevirt-operator";
      };

      clusterRbac = scope.rbac.mkClusterRoleSet scope {
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = ns;
          }
        ];
        roles."${name}-operator" = (readJSON ./rbac/clusterrole-kubevirt-operator.json).rules;
      };

      operatorRbac = scope.rbac.mkRoleSet scope {
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = ns;
          }
        ];
        roles."${name}-operator" = (readJSON ./rbac/role-kubevirt-operator.json).rules;
      };

      # Aggregates into the built-in admin role, so namespace admins can
      # manage KubeVirt resources. Nothing binds it.
      adminClusterRole =
        let
          upstream = readJSON ./rbac/clusterrole-kubevirt.io_operator.json;
        in
        scope.mkClusterResource {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "ClusterRole";
          inherit (upstream.metadata) name labels;
          extra.rules = upstream.rules;
        };

      # virt-operator writes this name into the pod specs of virt-api,
      # virt-controller, and virt-handler, and nothing else creates it.
      priorityClass = scope.mkClusterResource {
        apiVersion = "scheduling.k8s.io/v1";
        kind = "PriorityClass";
        name = "kubevirt-cluster-critical";
        extra = {
          value = 1000000000;
          globalDefault = false;
          description = "This priority class should be used for core kubevirt components only.";
        };
      };

      deployment = scope.mkDeployment {
        name = "${name}-operator";
        # virt-operator watches KubeVirt objects from the start, so it waits
        # for the one definition the package ships. The definitions the
        # operator installs itself cannot be waited on here.
        requires = [
          self.crds.kubeVirts
        ]
        ++ builtins.attrValues self.clusterRbac
        ++ builtins.attrValues self.operatorRbac;
        spec = {
          # virt-operator holds a leader election lease, so a replacement pod
          # covers "pod" and a standby on another node covers "node".
          replicas = pick {
            none = 1;
            pod = 1;
            node = 2;
            zone = 2;
          };
          selector.matchLabels = scope.selectorLabels;
          strategy.type = "RollingUpdate";
          template = {
            # Upstream's pod labels. The webhook Service virt-operator
            # creates selects kubevirt.io, and its metrics Service selects
            # prometheus.kubevirt.io.
            metadata.labels = scope.selectorLabels // {
              "kubevirt.io" = "virt-operator";
              name = "virt-operator";
              "prometheus.kubevirt.io" = "true";
            };
            spec = {
              serviceAccount = self.serviceAccount;
              terminationGracePeriodSeconds = 30;
              securityContext = {
                runAsNonRoot = true;
                seccompProfile.type = "RuntimeDefault";
              };
              nodeSelector."kubernetes.io/os" = "linux";
              priorityClassName = self.priorityClass.out.name;
              tolerations = [
                {
                  key = "CriticalAddonsOnly";
                  operator = "Exists";
                }
              ];
              containers = [
                {
                  name = "virt-operator";
                  image = kix.image.ref config.image;
                  imagePullPolicy = config.image.pullPolicy;
                  command = [ "virt-operator" ];
                  args = [
                    "--port"
                    "8443"
                    "-v"
                    "2"
                  ];
                  env = [
                    {
                      name = "KUBEVIRT_VERSION";
                      value = builtins.unsafeDiscardStringContext config.image.tag;
                    }
                    {
                      name = "VIRT_OPERATOR_IMAGE";
                      value = operatorImage;
                    }
                  ]
                  ++ lib.mapAttrsToList (n: ref: {
                    name = operands.${n}.env;
                    value = ref;
                  }) operandRefs;
                  ports = [
                    (kix.port "metrics" 8443)
                    (kix.port "webhooks" 8444)
                  ];
                  # Both probes as kubevirt-operator.yaml has them.
                  # virt-operator serves no other health endpoint.
                  readinessProbe = {
                    httpGet = {
                      path = "/metrics";
                      port = 8443;
                      scheme = "HTTPS";
                    };
                    initialDelaySeconds = 5;
                    periodSeconds = 10;
                    timeoutSeconds = 10;
                  };
                  livenessProbe = {
                    httpGet = {
                      path = "/metrics";
                      port = 8443;
                      scheme = "HTTPS";
                    };
                    initialDelaySeconds = 5;
                    periodSeconds = 10;
                    timeoutSeconds = 10;
                  };
                  terminationMessagePolicy = "FallbackToLogsOnError";
                  resources = config.resources;
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    capabilities.drop = [ "ALL" ];
                    readOnlyRootFilesystem = true;
                    seccompProfile.type = "RuntimeDefault";
                  };
                  volumeMounts = [
                    {
                      name = "kubevirt-operator-certs";
                      mountPath = "/etc/virt-operator/certificates";
                      readOnly = true;
                    }
                    {
                      name = "profile-data";
                      mountPath = "/profile-data";
                    }
                  ];
                }
              ];
              volumes = [
                {
                  name = "kubevirt-operator-certs";
                  secret = {
                    # virt-operator creates this Secret at runtime; its Role
                    # grants create on the name.
                    secretName = kix.untrackedRef {
                      name = "kubevirt-operator-certs";
                      by = "self";
                    };
                    optional = true;
                  };
                }
                {
                  name = "profile-data";
                  emptyDir = kix.keep { };
                }
              ];
            };
          };
        };
      };

      kubevirtCR = scope.mkCR self.crds.kubeVirts {
        inherit name;
        spec = kix.mergeGuarded {
          inherit who;
          locked = [
            [
              "infra"
              "replicas"
            ]
            [ "imagePullPolicy" ]
            [ "imageRegistry" ]
            [ "imageTag" ]
          ];
        } baseSpec config.extraSpec;
        requires = [
          self.deployment
          self.priorityClass
        ];
      };

      crds = {
        # The KubeVirt CRD is the only one upstream's bundle ships; the
        # operator installs the rest with full schemas.
        kubeVirts = scope.mkCRD {
          spec = (readJSON ./crds/kubevirts.kubevirt.io.json).spec;
          holdsData = false;
          readiness = {
            path = "/status/phase";
            equals = "Deployed";
          };
        };

        # virt-operator installs the VirtualMachine CRD once the KubeVirt
        # resource exists. Readiness is stamped per VM by
        # out.mkVirtualMachine.
        virtualMachines = scope.mkCRDRef {
          group = "kubevirt.io";
          kind = "VirtualMachine";
          plural = "virtualmachines";
          version = "v1";
          installedBy = self.kubevirtCR;
          # Deleting a VirtualMachine deletes the disks its
          # `spec.dataVolumeTemplates` made.
          holdsData = true;
          # Count one `virt-launcher` pod when the VM is configured to run
          # (`spec.runStrategy` is `Always` or `RerunOnFailure`, or
          # `spec.running` is `true`). Only the pod count is reported because
          # hugepages or a referenced instance type can change the launcher
          # pod's resource requests. Claims from `spec.dataVolumeTemplates`
          # are left out: CDI makes them, and when depends on its settings.
          usesAtLeast =
            cr:
            let
              spec = cr.spec or { };
              runs =
                if spec ? runStrategy then
                  builtins.elem spec.runStrategy [
                    "Always"
                    "RerunOnFailure"
                  ]
                else
                  spec.running or false;
            in
            {
              pods = if runs then 1 else 0;
            };
        };
      };

      # Null without an enforcer.
      operandPolicies = {
        virtApi = operandPolicy "virt-api" (podLabels "virt-api") {
          intents = {
            ingress = [
              {
                from = "apiserver";
                ports = [ (tcp 8443) ];
              }
            ];
            egress = clusterAccess;
          };
          extra = netpol: {
            egress = [
              (netpol.mkServiceEgressRule {
                selector = podLabels "virt-handler";
                namespace = ns;
                sourceNamespace = ns;
                ports = consoleServer;
              })
            ];
          };
        };
        virtController = operandPolicy "virt-controller" (podLabels "virt-controller") {
          intents.egress = clusterAccess;
        };
        virtHandler = operandPolicy "virt-handler" (podLabels "virt-handler") {
          intents.egress = clusterAccess;
          extra =
            netpol:
            let
              peers = netpol.mkSelfRules { selector = podLabels "virt-handler"; };
            in
            {
              inherit (peers) egress;
              ingress = peers.ingress ++ [
                (netpol.mkCallerIngressRule {
                  callerSelector = podLabels "virt-api";
                  callerNamespace = ns;
                  ports = consoleServer;
                })
              ];
            };
        };
        strategyJob = operandPolicy "strategy-dumper" (podLabels "virt-operator-strategy-dumper") {
          intents.egress = clusterAccess;
        };
        # Clients reach the proxy through its Service on 8443; the proxy
        # forwards to export server pods in the VirtualMachines' namespaces
        # on 8443.
        exportProxy = operandPolicy "virt-exportproxy" (podLabels "virt-exportproxy") {
          intents = {
            ingress = [
              {
                from = "all-pods";
                ports = [ (tcp 8443) ];
              }
            ];
            egress = clusterAccess ++ [
              {
                to = "all-pods";
                ports = [ (tcp 8443) ];
              }
            ];
          };
        };
        # The API server reaches virt-template-apiserver's aggregated API on
        # 9443.
        templateApiserver =
          if templateEnabled then
            operandPolicy "virt-template-apiserver" (templateLabels "apiserver") {
              intents = {
                ingress = [
                  {
                    from = "apiserver";
                    ports = [ (tcp 9443) ];
                  }
                ];
                egress = clusterAccess;
              };
            }
          else
            null;
        # The API server reaches virt-template-controller's admission
        # webhooks on 9443.
        templateController =
          if templateEnabled then
            operandPolicy "virt-template-controller" (templateLabels "controller-manager") {
              intents = {
                ingress = [
                  {
                    from = "apiserver";
                    ports = [ (tcp 9443) ];
                  }
                ];
                egress = clusterAccess;
              };
            }
          else
            null;
      };

      root = {
        resource = self.deployment;
        requires = [
          self.adminClusterRole
          self.kubevirtCR
          self.crds.virtualMachines
        ]
        ++ builtins.filter (p: p != null) (builtins.attrValues self.operandPolicies);

        out = {
          version = kix.image.version config.image;
          crds.VirtualMachine = self.crds.virtualMachines;
          inherit mkVirtualMachine;
          operandSelectors.virtLauncher = podLabels "virt-launcher";
          extraImages = builtins.attrValues operandRefs;
        };
      };
    };
}

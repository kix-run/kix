# NixOS module options consumed by buildCluster.

{ lib, options, ... }:
let
  versions = import ./core/version.nix { inherit lib; };
  errors = import ./core/error.nix { inherit lib; };
  defaultLimits = import ./core/default-limits.nix;

  isMoved = package: (package._type or "") == "kix-moved";
  isRemoved = package: (package._type or "") == "kix-removed";

  # Return the name and the spelling of every package that moved to
  # experimental and that an instance names by an old spelling, read from the raw definitions so
  # that one error can list them all. A definition this cannot read, such
  # as one under `mkIf`, is skipped.
  movedNames =
    let
      attrsOnly = v: builtins.isAttrs v && !(v ? _type);
      fromDef =
        def:
        lib.optionals (attrsOnly def) (
          lib.concatMap (
            instances:
            lib.optionals (attrsOnly instances) (
              lib.concatMap (
                inst:
                let
                  read = builtins.tryEval (
                    if attrsOnly inst && inst ? package && isMoved inst.package then inst.package else null
                  );
                in
                lib.optional (read.success && read.value != null) {
                  inherit (read.value) name;
                  spelled = read.value.spelled or "packages.${read.value.name}";
                }
              ) (builtins.attrValues instances)
            )
          ) (builtins.attrValues def)
        );
    in
    lib.unique (lib.concatMap fromDef options.instances.definitions);

  # Return the error for an instance whose package moved to experimental:
  # the package's own error, or one that lists every moved package the
  # cluster names, so a migration takes one build rather than one per name.
  movedMessage =
    package:
    let
      own = {
        inherit (package) name;
        spelled = package.spelled or "packages.${package.name}";
      };
      names = lib.unique ([ own ] ++ movedNames);
    in
    if builtins.length names == 1 then
      package.error
    else
      {
        inherit (import ../packages/was-stable.nix) id;
        message = "These ${toString (builtins.length names)} packages are experimental now, so they may change in any release.";
        fix = lib.concatStringsSep "\n" (
          [ "Write the new names:" ]
          ++ map (n: "  ${n.spelled} -> packages.experimental.${n.name}") (
            lib.sort (a: b: a.spelled < b.spelled) names
          )
        );
      };
in
{
  imports = [
    ./plugins/netpol/module.nix
    ./plugins/availability/module.nix
  ];

  options = {

    clusterLabels = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Labels injected into every resource.";
    };

    clusterDomain = lib.mkOption {
      type = lib.types.str;
      default = "cluster.local";
      description = "Kubernetes cluster DNS domain. Used to construct resource FQDNs (e.g. svc.cluster.local).";
    };

    cluster.domain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "example.com";
      description = ''
        Public base domain for exposed services. When an instance has no
        explicit `ingress.host`, `kix.expose` derives
        `<instance>.<domain>`. When null, it creates no Ingress or HTTPRoute.
      '';
    };

    cluster.secrets.accept = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.listOf (
          lib.types.enum [
            "inline"
            "sops"
            "external"
            "controller"
            "configuration"
          ]
        )
      );
      default = null;
      example = [
        "sops"
        "external"
        "controller"
      ];
      description = ''
        Where a Secret's values may come from. Null accepts every source.
        When set, the `security.secretSource` scorecard rule reports every
        key of a Secret whose source is not listed. `inline`: the value is
        written in the Nix expression, so it is in the Nix store and in
        every build. `sops`: the deploy decrypts it from a SOPS file.
        `external`: something outside Kix creates the Secret
        (`scope.mkSecretRef`, a `secret-ref` instance). `controller`: Kix
        creates the Secret empty and a controller fills it.
        `configuration`: a package renders software configuration into a
        Secret and classifies it so. The library does not verify the
        classification or that the package refuses credential keys, so
        listing this takes the package's word. A key the package marks
        plain (a username, a host) is accepted under every setting.
      '';
    };

    instances = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.attrsOf (
          lib.types.submodule {
            options = {
              package = lib.mkOption {
                type = lib.types.raw;
                # A package that moved to experimental or was removed leaves
                # a marker under its old name, which carries the error to show.
                apply =
                  package:
                  if isMoved package then
                    errors.fail (movedMessage package)
                  else if isRemoved package then
                    errors.fail package.error
                  else if builtins.isPath package then
                    errors.fail {
                      message = "An instance's `package` is set to the path ${toString package} without `import`.";
                      fix = "Write `package = import ${toString package};`.";
                    }
                  else
                    package;
                description = ''
                  The package function. types.raw avoids recursive merge
                  processing that would break lib.fix in package evaluation.
                  Two modules declaring the same (ns, instance) is caught
                  by the submodule merge at the instance level.
                '';
              };
              aliases = lib.mkOption {
                type = lib.types.nullOr (lib.types.listOf lib.types.str);
                default = null;
                description = ''
                  Extra dependency names that resolve to this instance, besides
                  its own name and the package's `meta.roles`. When `null` (the
                  default), Kix uses the package's `meta.defaultAliases`. Setting
                  a list replaces `meta.defaultAliases`, so `[ ]` clears them.

                  When a cluster runs multiple instances of the same service,
                  wire consumers explicitly with `deps.<argName> = ref.<ns>.<inst>`.
                '';
              };
              config = lib.mkOption {
                type = lib.types.deferredModule;
                default = { };
                description = ''
                  Instance configuration. Multiple modules can contribute
                  config to the same instance; they merge via deferredModule.
                  Use mkDefault/mkForce for priority control.
                '';
              };
              deps = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = { };
                description = ''
                  Explicit DI overrides. Keys are package function arg names.
                  A value is `ref.<ns>.<inst>`, a list of such refs (the
                  package receives a list of instances), or any other value,
                  bound as it is. Collision = error (two modules setting same
                  dep for same instance must be resolved explicitly).
                '';
              };
              partsOverlays = lib.mkOption {
                # Use `raw` so the module system does not wrap overlay functions
                # and eagerly merge their return values while the `self` fixed
                # point is still being computed.
                type = lib.types.listOf lib.types.raw;
                default = [ ];
                description = ''
                  Parts overlay functions (scope: self: base: attrset).
                  Applied in order after package evaluation. Multiple modules
                  contribute overlays; they concatenate.
                '';
              };
              version = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
              };
              labelStyle = lib.mkOption {
                type = lib.types.enum [
                  "kix"
                  "helm"
                ];
                default = "kix";
                description = ''
                  Label convention for selectors and metadata.
                  "kix" uses app.kubernetes.io/* keys.
                  "helm" uses app/release keys for Helm compatibility.
                '';
              };
              selectorLabels = lib.mkOption {
                type = lib.types.nullOr (lib.types.attrsOf lib.types.str);
                default = null;
                description = ''
                  Override auto-generated selector labels. Use when the cluster has
                  immutable selectors (e.g. StatefulSet) that don't match the kix
                  or Helm naming convention.
                '';
              };
              extraDeps = lib.mkOption {
                type = lib.types.listOf lib.types.raw;
                default = [ ];
                description = ''
                  Additional dependencies for a kix.mkImport instance's
                  PackageInstance marker, for ordering that no value read
                  from another instance carries. Each entry is a resource or
                  `ref.<namespace>.<instance>`, which stands for that
                  instance's PackageInstance marker. Evaluation fails,
                  whether or not the instance is active, for any other
                  value, for a ref to the import itself, and for a non-empty
                  list on a managed instance. When the import is active, a
                  ref to an optional instance that is not active also fails;
                  a ref does not activate one.
                '';
              };
              platformIntents = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = { };
                description = ''
                  Platform connectivity intents for this import instance's
                  pre-installed pods. Each intent declares enforcer-agnostic
                  connectivity requirements (same schema as
                  networkPolicy.platformIntents). When an enforcer is available,
                  the intents are materialized into CNP resources and injected
                  as extraDeps on the import's marker. This establishes the
                  dependency chain: workload → import marker → CNPs → enforcer.
                '';
              };
              optional = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = ''
                  Dormant instance: included in DI resolution but only deployed
                  if a non-optional instance transitively depends on it.
                  Lets cluster operators pre-configure instances with full control.
                '';
              };
            };
          }
        )
      );
      default = { };
    };

    availablePackages = lib.mkOption {
      type = lib.types.attrsOf lib.types.raw;
      default = { };
      description = ''
        Package registry for auto-instantiation. Accepts either raw package
        functions or attrsets { package, namespace?, aliases? }.
        When DI resolution fails for a required dep, the system checks this
        registry and auto-creates an instance with default config.
        Nice DX: availablePackages = packages;
        That puts the stable packages in the registry. Add an
        experimental package by name:
        availablePackages = packages // { inherit (packages.experimental) stackgres-operator; };

        A name that more than one entry answers (by entry name,
        meta.roles, meta.defaultAliases or the entry's aliases) is refused
        when something depends on it. Select one with an optional instance
        of that name, or remove the others from this registry.
      '';
    };

    autoNamespace = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Default namespace for auto-instantiated packages.
        null = co-locate with the requesting package's namespace.
        A string = place all auto-instances in this namespace.
        Per-package namespace overrides this.
      '';
    };

    namespaces = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            labels = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
            };
            annotations = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
            };
            resourceQuota = lib.mkOption {
              type = lib.types.nullOr lib.types.anything;
              default = null;
            };
            networkPolicies = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = { };
            };
            podSecurity = lib.mkOption {
              type = lib.types.nullOr (
                lib.types.enum [
                  "privileged"
                  "baseline"
                  "restricted"
                ]
              );
              default = null;
              description = ''
                Pod Security Standards level enforced on this namespace
                (`pod-security.kubernetes.io/enforce`). A package whose pods
                need more declares `meta.podSecurity`; the namespace gets the
                most permissive level any of its instances needs, and a level
                set here that is stricter than an instance needs is an eval
                error. Unset with no instance declaring one, the namespace
                carries no label.
              '';
            };
          };
        }
      );
      default = { };
    };

    globalPartsOverlays = lib.mkOption {
      # `raw` for the reason given at `partsOverlays`.
      type = lib.types.listOf lib.types.raw;
      default = [ ];
      description = ''
        Parts overlay functions applied to ALL instances. Signature:
        scope → self → base → attrset. The overlay decides per-instance
        whether to act by inspecting base.
      '';
    };

    k8sVersion = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.addCheck lib.types.str versions.isVersion
        // {
          description = "Kubernetes version such as \"1.31\"";
        }
      );
      default = null;
      description = ''
        Target Kubernetes version (e.g. "1.31"). Used by package meta
        compatibility checks (meta.k8s.minVersion / maxVersion). A version
        less precise than a package's constraint is reported as a warning.
        Deploy, plan, and the operator stop when the cluster runs a different
        version, compared as precisely as written: "1.31" matches any 1.31.x.
        A value with a patch number, such as "1.31.4", stops the deploy after
        every patch upgrade, which managed clusters apply on their own.
      '';
    };

    cluster.provider = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Kubernetes distribution or provider (e.g. "k3s", "kind", "kubeadm",
        "eks", "talos"). The vendor field: carried for display/telemetry only.
        Nothing in the compiler may branch on it. Branch on cluster.roles,
        cluster.capabilities, or resolved role providers instead.
      '';
    };

    cluster.kubernetes.uid = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.addCheck lib.types.str (
          s: builtins.match "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}" s != null
        )
        // {
          description = "lowercase UUID such as \"4d7b1c2e-9f3a-4b8e-a1c5-6d2e8f0a9b3c\"";
        }
      );
      default = null;
      description = ''
        The Kubernetes cluster this definition belongs to, named by the UID
        of its `kube-system` Namespace (`kubectl get namespace kube-system
        -o jsonpath='{.metadata.uid}'` or `kix status <cluster>`). That UID
        is set when the cluster is created and never changes. When set, the
        build carries it, and deploy, plan, rollback, hard gc, and the
        operator refuse to run the build against any other Kubernetes
        cluster. Once a bound build has deployed, that Kubernetes cluster
        also refuses builds that do not name it. Several Kix clusters on one
        Kubernetes cluster all set the same UID. null leaves the definition
        unbound.
      '';
    };

    cluster.recordNamespace = lib.mkOption {
      type = lib.types.str;
      default = "kube-system";
      description = ''
        The namespace that holds the PackageInstance record of each instance
        under a `_`-prefixed key, such as `instances._cluster`. Such an
        instance has no namespace of its own, and Kubernetes only stores a
        PackageInstance inside a namespace. Records of other instances stay
        in their own namespace. Kix does not create this namespace, so it
        must exist. Some managed services, such as GKE Autopilot, refuse
        writes to `kube-system`. Clusters there set another namespace that
        exists.
      '';
    };

    cluster.factBehavior = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = ''
        Per-kind override of the fact terminate/conduct table, keyed
        "group/Kind" (bare kinds collide across API groups). Normally the
        CRD-owning package declares behavior on the CRD itself (the
        `factBehavior` arg of `scope.mkCRD` / `scope.mkCRDRef`, delivered
        to every CR built via `scope.mkCR`); this option is the cluster
        operator's escape hatch: it wins over the CRD declaration and
        also covers builder-less CRs (helm-rendered, raw kind strings).
        Shape: `{ "stackgres.io/SGCluster" = { endpoint = "terminate" |
        "conduct"; podSelector = cr: { ... }; }; }`. "terminate" means the
        kind's controller dials the endpoints embedded in the resource, so
        netpol opens egress for the operand pods named by `podSelector`.
        "conduct" means the resource merely carries the values onward.
        Validated eagerly at cluster eval.
      '';
    };

    cluster.roles = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            binding = lib.mkOption {
              type = lib.types.nullOr (
                lib.types.enum [
                  "absent"
                  "shadowable"
                  "exclusive"
                ]
              );
              default = null;
              description = ''
                How the environment claims this role (linker semantics):
                - null: unknown; relying consumers warn.
                - "absent": role vacant; a managed instance fills it, a
                  consumer without one gets a link error.
                - "shadowable": environment provides a default (weak symbol,
                  usually paired with a platform import declaring the role);
                  a managed instance overrides cleanly.
                - "exclusive": environment owns the role (strong symbol);
                  a managed instance claiming it is an eval error pointing
                  at this axiom (e.g. kindnet on stock kind).
              '';
            };
            provider = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                Display name of the environment's implementation (e.g.
                "kindnet", "flannel"). Informational only; never branched on.
              '';
            };
          };
        }
      );
      default = { };
      description = ''
        Binding modes for environment-provided roles. Keys must be registry
        roles (kix/lib/eval/roles.nix). Managed packages never declare
        binding modes. A managed instance is strong by nature; modes exist
        only for the environment's claim on a role.
      '';
    };

    cluster.capabilities = {

      multiNode = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = ''
          Whether the cluster has multiple schedulable nodes. When false,
          pod anti-affinity and topology spread constraints are meaningless.
          null = unknown.
        '';
      };

      availabilityZones = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        description = "Known availability zones. null = unknown; [ ] = known single-zone.";
      };

      nodeAutoscaling = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = ''
          Whether the cluster has built-in node autoscaling (cloud autoscaler,
          Karpenter, GKE Autopilot). When true, cluster.nodes is a snapshot
          and the actual node count may vary. null = unknown.
        '';
      };

      managedControlPlane = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = ''
          Whether the control plane is managed by a provider (EKS, GKE, AKS).
          When true, kube-system components like CoreDNS/etcd are not user-managed,
          and deploying replacements will conflict. null = unknown.
        '';
      };

      gpu = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Whether GPU scheduling (nvidia.com/gpu) is available. null = unknown.";
      };

      privilegedContainers = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = ''
          Whether pods can run privileged, use hostNetwork, hostPID, etc.
          False on GKE Autopilot (hard platform restriction) and effectively
          false on OpenShift (SCC restricted by default). null = unknown:
          relying workloads warn instead of failing.
        '';
      };

      podSecurityEnforcement = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.enum [
            "privileged"
            "baseline"
            "restricted"
          ]
        );
        default = null;
        description = ''
          Pod Security Admission enforcement level, if any.
          null = no cluster-wide enforcement (individual namespaces may still set labels).
          "baseline" = GKE Autopilot default.
          "restricted" = OpenShift SCC default.
        '';
      };

      daemonSets = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = ''
          Whether DaemonSets can be deployed. False on GKE Autopilot where
          the platform manages all node-level daemons. null = unknown.
        '';
      };

      criticalPriorityNamespaces = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        description = ''
          Namespaces where the cluster allows pods with the built-in
          `system-node-critical` or `system-cluster-critical` PriorityClass.
          When set, any workload using either class outside these namespaces
          fails the build. The `gke` flavor sets this to `[ "kube-system" ]`
          because GKE rejects these pods in namespaces without a matching
          ResourceQuota. `null` means no known restriction.
        '';
      };
    };

    cluster.defaultLimits = {
      cpu = lib.mkOption {
        type = lib.types.enum defaultLimits.modes;
        default = defaultLimits.default.cpu;
        description = ''
          Whether packages apply their default CPU limits across the cluster.
          `"package"` keeps each package's default CPU limit. `"none"` drops
          default CPU limits declared with `kix.options.resources`, keeps all
          CPU requests and any `limits.cpu` set on an instance, and tells the
          `reliability.boundedResources` scorecard rule not to require
          `limits.cpu`. Many clusters set `"none"` because CPU limits throttle
          containers even when a node has idle CPU, while CPU requests still
          guarantee each container's share.
        '';
      };
      memory = lib.mkOption {
        type = lib.types.enum defaultLimits.modes;
        default = defaultLimits.default.memory;
        description = ''
          Whether packages apply their default memory limits across the
          cluster. `"package"` keeps each package's default memory limit.
          `"none"` drops default memory limits declared with
          `kix.options.resources`, keeps all memory requests and any
          `limits.memory` set on an instance, and tells the
          `reliability.boundedResources` scorecard rule not to require
          `limits.memory`. Keep this set to `"package"` unless you set
          `limits.memory` per instance or intend to run without memory limits.
          Kubernetes cannot throttle memory, so a container without a memory
          limit can exhaust a node's memory and cause the kernel to kill other
          pods on that node.
        '';
      };
    };

    # Node containerd paths and settings. Flavors set the defaults for their
    # node images, and host-level packages such as spegel read them.
    cluster.containerd = {
      socket = lib.mkOption {
        type = lib.types.strMatching "/.+";
        default = "/run/containerd/containerd.sock";
        description = "Path of containerd's gRPC socket on each node.";
      };
      registryConfigPath = lib.mkOption {
        type = lib.types.strMatching "/.+";
        default = "/etc/containerd/certs.d";
        description = "The CRI registry `config_path` on each node: the directory of per-registry `hosts.toml` files that containerd reads mirrors from.";
      };
      contentPath = lib.mkOption {
        type = lib.types.strMatching "/.+";
        default = "/var/lib/containerd/io.containerd.content.v1.content";
        description = "Path of containerd's content store on each node.";
      };
      discardUnpackedLayers = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = ''
          The CRI `discard_unpacked_layers` setting on each node. When true,
          containerd deletes an image's compressed layers once it has
          unpacked them, so a node cannot serve them to its peers. The
          kind, Talos, EKS, and GKE flavours set it to true, as their node
          images ship. null = unknown.
        '';
      };
    };

    cluster.maintenance = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Whether the cluster is in a maintenance window. When true,
              tooling that consumes `cluster.out.maintenance` may suppress
              non-actionable pages or surface a banner.
            '';
          };
          reason = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Free-form human reason for the maintenance window.";
          };
          until = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              Optional ISO-8601 timestamp at which the maintenance window
              ends. Informational: kix does not auto-clear the flag.
            '';
          };
        };
      };
      default = { };
      description = ''
        Maintenance-mode marker. No-op at build time; consumers read the
        materialized form via `cluster.out.maintenance` (Alertmanager
        routing, operator UI, dashboards).
      '';
    };

    cluster.network = {
      podCidr = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Pod network CIDR (e.g. '10.244.0.0/16'). Read by the cilium
          package as its IPAM pool when it installs the chart with
          cluster-pool IPAM. The kind, k3s, and rke2 flavours set their
          defaults.
        '';
      };
      serviceCidr = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Service network CIDR (e.g. '10.96.0.0/16').";
      };
      dnsUpstream = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Upstream DNS resolvers. The coredns package's forward plugin reads them; empty means /etc/resolv.conf.";
      };
    };

    cluster.nodes = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            roles = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ "worker" ];
              description = "Node roles (e.g. 'control-plane', 'worker', 'storage', 'gpu').";
            };
            cpu = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
              description = "vCPU count.";
            };
            memory = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Total memory, K8s quantity format (e.g. '16Gi').";
            };
            labels = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
              description = "Node labels (topology, zone, etc).";
            };
            taints = lib.mkOption {
              type = lib.types.listOf lib.types.anything;
              default = [ ];
            };
          };
        }
      );
      default = { };
      description = ''
        Static node inventory. Packages can read this for topology-aware
        defaults (replica count, anti-affinity, storage pools).
        Leave empty for autoscaled or unknown-topology clusters.
      '';
    };

    scorecard = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Evaluate the scorecard rules during the cluster build. On by
              default, with every finding capped at `maxSeverity` (warning),
              so a cluster sees what the rules have to say and nothing fails
              until it raises the cap.
            '';
          };
          rules = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = import ./rules { inherit lib; };
            defaultText = lib.literalExpression "kix.rules";
            description = ''
              Rule definitions. Nested attrset: { category.ruleName = rule; }.
              Each rule has: description, level, severity, check, and optional
              tags and appliesTo fields. Defaults to the full built-in set;
              setting this replaces it, so a cluster that wants the built-in
              set plus a change to one rule uses `ruleOverrides` instead.
            '';
          };
          maxSeverity = lib.mkOption {
            type = lib.types.enum [
              "info"
              "warning"
              "error"
            ];
            default = "warning";
            description = ''
              The highest severity a finding can have in this cluster. A rule
              resolved above it is reported at this level instead, so the
              default, `warning`, means every finding is printed and none
              fails the build. A repository that wants a red build on an
              error-severity rule sets `error`; this repository's own
              clusters do, through `clusterModules` in their flakes.
            '';
          };
          ruleDefaults = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = { };
            description = ''
              Cluster-wide rule defaults. Currently supports:
              severity = "warning"|"error"|"info": default severity for rules
              that don't specify their own.
            '';
          };
          ruleOverrides = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = { };
            description = ''
              Scope-specific rule overrides. Supports:
              byNamespace."pattern" = { "rule.pattern".severity = ...; };
              byOwner."pattern" = { "rule.pattern".severity = ...; };
              byRule."ruleName" = { enabled = false; };
            '';
          };
          knownAnnotationDomains = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "eks.amazonaws.com" ];
            description = ''
              Annotation domains handled outside Kix, such as cloud provider
              or organization annotations. The
              `architecture.annotationDomainOwnership` scorecard rule ignores
              these domains instead of requiring an in-cluster package that
              declares them in `meta.annotationDomains`.
            '';
          };
        };
      };
      default = { };
      description = "Build-time policy rules and severity settings for the cluster. The \"Scorecard and rules\" page of the Kix docs lists the rules.";
    };

    consumers = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            namespaces = lib.mkOption {
              type = lib.types.attrsOf (
                lib.types.submodule {
                  options = {
                    podSecurity = lib.mkOption {
                      type = lib.types.nullOr (
                        lib.types.enum [
                          "privileged"
                          "baseline"
                          "restricted"
                        ]
                      );
                      default = null;
                      description = "The Pod Security level of the namespaces this entry grants.";
                    };
                    quota = lib.mkOption {
                      type = lib.types.attrsOf lib.types.str;
                      default = { };
                      example = {
                        pods = "4";
                        "requests.cpu" = "500m";
                      };
                      description = ''
                        The ResourceQuota `hard` limits of each namespace this
                        entry grants, with Kubernetes' key names. Each
                        namespace gets its own quota of these limits.
                      '';
                    };
                    max = lib.mkOption {
                      type = lib.types.nullOr lib.types.ints.positive;
                      default = null;
                      description = ''
                        The most namespaces matching this pattern the
                        consumer may create, exact names inside it included.
                        Only on a pattern. The consumer's build fails when it
                        renders more.
                      '';
                    };
                    secrets = lib.mkOption {
                      type = lib.types.listOf (
                        lib.types.submodule {
                          options = {
                            name = lib.mkOption { type = lib.types.str; };
                            keys = lib.mkOption {
                              type = lib.types.listOf lib.types.str;
                              default = [ ];
                            };
                            type = lib.mkOption {
                              type = lib.types.str;
                              default = "Opaque";
                            };
                          };
                        }
                      );
                      default = [ ];
                      description = ''
                        Secrets present in this namespace for the consumer to
                        use. Only on an exact name. The interface lists them
                        by name, keys, and type. Kix does not create them:
                        this cluster's own instances do, for example a
                        packages.secret instance in that namespace, or a
                        package that mints a credential per consumer.
                      '';
                    };
                  };
                }
              );
              example = lib.literalExpression ''
                {
                  "acme-*" = {
                    podSecurity = "restricted";
                    quota = { pods = "4"; "requests.memory" = "512Mi"; };
                    max = 3;
                  };
                  acme-db.quota."requests.memory" = "2Gi";
                  reports = { };
                }
              '';
              description = ''
                The namespaces the consumer may create and use, each key with
                the settings of the namespaces it grants. A key is an exact
                name, a prefix such as "acme-*", or "*" for every namespace
                that is not this cluster's. This cluster's namespaces are
                those its build renders into, and `reservedNamespaces`. One
                consumer may hold "*". A consumer's own patterns may not
                overlap, and no two consumers' keys may match the same
                namespace.

                A namespace takes the settings of the pattern that matches
                it, then those of its exact name on top: the exact name's
                `podSecurity` replaces the pattern's, and its `quota` keys
                replace the pattern's keys of the same name.
              '';
            };
            services = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              example = [ "data/postgres-shared" ];
              description = ''
                Instances of this cluster the consumer may use, as
                "namespace/instance". Each reaches the consumer as a
                `kix.mkImport` with the instance's `out` and roles.
              '';
            };
            clusterScoped = lib.mkOption {
              type = lib.types.listOf (
                lib.types.submodule {
                  options = {
                    kind = lib.mkOption { type = lib.types.str; };
                    name = lib.mkOption { type = lib.types.str; };
                  };
                }
              );
              default = [ ];
              description = "Cluster-scoped objects the consumer may render, by kind and name.";
            };
          };
        }
      );
      default = { };
      description = ''
        Other Kix clusters this cluster hosts on the same Kubernetes
        cluster, keyed by consumer name. A consumer names its own cluster
        and builds it from its own repository against the interface file
        this cluster writes for it (`kix-interface-acme.json`, loaded with
        `kix.interface`).
      '';
    };

    reservedNamespaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "kube-system" ];
      description = ''
        Namespaces this cluster claims without rendering into them, such as
        those the Kubernetes distribution creates. No consumer may use them.
      '';
    };

    secretsRecipient = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "age1...";
      description = ''
        The age public key that decrypts SOPS files where this cluster is
        deployed. Consumers find it in their interface and encrypt to it.
      '';
    };

    interfaces = lib.mkOption {
      type = lib.types.attrsOf lib.types.raw;
      default = { };
      description = ''
        Interface files this cluster is built against, keyed by the platform
        cluster's name. Set by `kix.interface`; cluster modules read the
        parsed file here, for example `config.interfaces.prod.secrets`.
      '';
    };

    # Each hook is a function `ctx -> result` or `{ priority ? 1000; fn; }`,
    # executed by ascending priority and then by name. Hook return values are
    # shape-checked and unknown keys fail at the call site.
    hooks = {
      workloadInterceptors = lib.mkOption {
        type = lib.types.attrsOf lib.types.raw;
        default = { };
        description = ''
          Named workload interceptors, run inside scope.mkDeployment/
          mkStatefulSet/mkDaemonSet/mkJob/mkHelmWorkload BEFORE
          builtins.toFile seals the workload.
          fn :: ctx -> { requires ? [ ]; resources ? [ ]; warnings ? [ ]; }
          `requires` is spliced into the workload pre-seal (earlier-wave
          guarantee); `resources` ride the `_injectedResources` sideband
          into the instance's part resources. Interceptors read the raw
          workload input and outer-fixpoint data only. They must never
          force the resource under construction. Resource emission goes
          through ctx.emit (sealing capability only), not the authoring
          scope.
        '';
      };
      instanceProcessors = lib.mkOption {
        type = lib.types.attrsOf lib.types.raw;
        default = { };
        description = ''
          Named per-instance processors, run after the instance's parts
          fixpoint settles.
          fn :: ctx -> { resources ? [ ]; warnings ? [ ]; }
          Returned resources join the instance's owned resource set and its
          PackageInstance inverse deps. Resource emission goes through
          ctx.emit.
        '';
      };
      clusterProcessors = lib.mkOption {
        type = lib.types.attrsOf lib.types.raw;
        default = { };
        description = ''
          Named cluster-level processors, run during cluster aggregation.
          fn :: ctx -> { resources ? [ ]; checks ? [ ]; warnings ? [ ]; }
          Returned resources join the cluster resource set and become the
          Activation CR's extraDeps in hook execution order. That order is
          content-addressed into the manifest set, so priorities are part
          of the output contract. A check is any lazy value that throws its
          own error message on failure; all checks are forced before the
          cluster result is returned.
        '';
      };
    };
  };
}

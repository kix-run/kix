# lib/modules.nix — NixOS module options for kix cluster definitions.
#
# Provides the option declarations used by buildCluster's evalModules.
# Each cluster is composed of modules that set these options.
# See v2_discussions/20_module_system_design.md for design rationale.

{ lib, ... }:
{
  imports = [ ./plugins/netpol/module.nix ];

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

    # The public domain, as opposed to `clusterDomain` above, which is the
    # in-cluster DNS suffix. kix reads this in three places (kix.expose's
    # host derivation, the monitoring module's Grafana root URL, and
    # vaultwarden), so kix declares it. It used to be declared by each
    # consumer instead, which made a forgotten declaration into a silent
    # `null` at every read site rather than an error at the one that matters.
    cluster.domain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "example.com";
      description = ''
        Base public domain for services this cluster exposes. `kix.expose`
        derives a host as `<instance>.<domain>` when the instance sets no
        explicit `ingress.host`. Null means no host is derived, and
        `kix.expose` produces no Ingress or HTTPRoute.
      '';
    };

    instances = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.attrsOf (
          lib.types.submodule {
            options = {
              package = lib.mkOption {
                type = lib.types.raw;
                description = ''
                  The package function. types.raw avoids recursive merge
                  processing that would break lib.fix in package evaluation.
                  Two modules declaring the same (ns, instance) is caught
                  by the submodule merge at the instance level.
                '';
              };
              aliases = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = ''
                  DI resolution keys for this instance, in addition to the
                  instance name itself.  When non-empty, *replaces* the
                  package's `meta.defaultAliases`; when empty (the default),
                  the package defaults apply.

                  For multi-instance disambiguation prefer `deps.<argName>
                  = ref.<ns>.<inst>` at the consumer site — aliases are
                  not the right tool for that case.  See BEST-PRACTICES
                  §8.4.
                '';
              };
              config = lib.mkOption {
                type = lib.types.deferredModule;
                default = { };
                description = ''
                  Instance configuration. Multiple modules can contribute
                  config to the same instance — they merge via deferredModule.
                  Use mkDefault/mkForce for priority control.
                '';
              };
              deps = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = { };
                description = ''
                  Explicit DI overrides. Keys are package function arg names.
                  Collision = error (two modules setting same dep for same
                  instance must be resolved explicitly).
                '';
              };
              partsOverlays = lib.mkOption {
                type = lib.types.listOf lib.types.anything;
                default = [ ];
                description = ''
                  Parts overlay functions (scope: self: base: attrset).
                  Applied in order after package evaluation. Multiple modules
                  contribute overlays — they concatenate.
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
                  Additional dependency edges for the instance's PackageInstance
                  marker. Used to inject ordering constraints that aren't
                  captured by store-path context (e.g. an import depending on
                  a managed instance's root resource).
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
                  as extraDeps on the import's marker — establishing the
                  dependency chain: workload → import marker → CNPs → enforcer.
                '';
              };
              optional = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = ''
                  Dormant instance — included in DI resolution but only deployed
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
          };
        }
      );
      default = { };
    };

    globalPartsOverlays = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
      description = ''
        Parts overlay functions applied to ALL instances. Signature:
        scope → self → base → attrset. The overlay decides per-instance
        whether to act by inspecting base.
      '';
    };

    global = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = ''
        Cluster-wide configuration values. Packages read these via
        _kixOptions defaults that reference them.
      '';
    };

    k8sVersion = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Target Kubernetes version (e.g. "1.30"). Used by package meta
        compatibility checks (meta.k8s.minVersion / maxVersion).
      '';
    };

    # --- Cluster target model (v2_discussions/127) ---
    # The target description splits into:
    #   cluster.roles         — binding modes for environment-owned roles
    #   cluster.capabilities  — substrate axioms (facts below the compilation
    #                           boundary; three-valued: null = unknown)
    # Role-backed capability bools (cni, networkPolicyAPI, loadBalancer,
    # persistentStorage, ...) are gone: the compiler derives role providers
    # from `meta.roles` + platform imports (see eval/roles.nix).

    cluster.provider = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Kubernetes distribution or provider (e.g. "k3s", "kind", "kubeadm",
        "eks", "talos"). The vendor field: carried for display/telemetry only.
        Nothing in the compiler may branch on it — branch on cluster.roles,
        cluster.capabilities, or resolved role providers instead.
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
        operator's escape hatch — it wins over the CRD declaration and
        also covers builder-less CRs (helm-rendered, raw kind strings).
        Shape: `{ "stackgres.io/SGCluster" = { endpoint = "terminate" |
        "conduct"; podSelector = cr: { ... }; }; }`. "terminate" means the
        kind's controller dials the endpoints embedded in the resource —
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
                - null: unknown — relying consumers warn.
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
                "kindnet", "flannel"). Informational only — never branched on.
              '';
            };
          };
        }
      );
      default = { };
      description = ''
        Binding modes for environment-provided roles. Keys must be registry
        roles (kix/lib/eval/roles.nix). Managed packages never declare
        binding modes — a managed instance is strong by nature; modes exist
        only for the environment's claim on a role.
      '';
    };

    cluster.capabilities = {

      # --- Topology ---

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

      # --- Compute ---

      gpu = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Whether GPU scheduling (nvidia.com/gpu) is available. null = unknown.";
      };

      # --- Security ---

      privilegedContainers = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = ''
          Whether pods can run privileged, use hostNetwork, hostPID, etc.
          False on GKE Autopilot (hard platform restriction) and effectively
          false on OpenShift (SCC restricted by default). null = unknown —
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
    };

    # --- Maintenance-mode marker ---
    # Operator-declared "the cluster is in a planned maintenance window" flag.
    # No-op for now — surfaced through `cluster.out.maintenance` so future
    # Alertmanager routing (silence non-actionable pages) and the operator
    # UI can read it. See v2_discussions/105 §A6 / B7.

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
              ends. Informational — kix does not auto-clear the flag.
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
        description = "Pod network CIDR (e.g. '10.244.0.0/16').";
      };
      serviceCidr = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Service network CIDR (e.g. '10.96.0.0/16').";
      };
      dnsUpstream = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Upstream DNS resolvers (for CoreDNS forwarding, cert-manager DNS01, etc).";
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

    # --- Scorecard rule system ---
    # Declarative policy framework with multi-level evaluation and
    # configurable severity. See v2_discussions/60_scorecard_rules_design.md.

    scorecard = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Enable scorecard rule evaluation during cluster build.";
          };
          rules = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = { };
            description = ''
              Rule definitions. Nested attrset: { category.ruleName = rule; }.
              Each rule has: description, level, severity, check, and optional
              tags and appliesTo fields.
            '';
          };
          ruleDefaults = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = { };
            description = ''
              Cluster-wide rule defaults. Currently supports:
              severity = "warning"|"error"|"info" — default severity for rules
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
              Annotation domains consumed by something outside kix — a cloud
              control plane, org-convention metadata. Exempted from the
              architecture.annotationDomainOwnership lint alongside the
              reserved Kubernetes domains and domains declared by in-cluster
              packages via meta.annotationDomains (v2_discussions/128).
            '';
          };
        };
      };
      default = { };
      description = "Scorecard policy evaluation. See v2_discussions/60_scorecard_rules_design.md.";
    };

    # Each hook is a function `ctx -> result` or `{ priority ? 1000; fn; }`.
    # Execution order is (priority ascending, then name) — declare a priority
    # instead of encoding order into hook names. Results are shape-checked;
    # unknown keys throw at the call site.
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
          workload input and outer-fixpoint data only — they must never
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
          Activation CR's extraDeps in hook execution order — that order is
          content-addressed into the manifest set, so priorities are part
          of the output contract. A check is any lazy value that throws its
          own error message on failure; all checks are forced before the
          cluster result is returned.
        '';
      };
    };
  };
}

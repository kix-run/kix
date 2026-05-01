# lib/modules.nix — NixOS module options for kix cluster definitions.
#
# Provides the option declarations used by buildCluster's evalModules.
# Each cluster is composed of modules that set these options.
# See v2_discussions/20_module_system_design.md for design rationale.

{ lib, ... }:
{
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
                description = "Additional DI resolution keys (beyond the instance name).";
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

    # --- Cluster hardware profile ---
    # Describes the cluster's physical/provider reality and pre-existing
    # capabilities. Packages query capabilities for conditional logic;
    # the flavor system sets defaults via mkDefault.
    # See v2_discussions/45_cluster_hardware_profile.md for design rationale.

    cluster.provider = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Kubernetes distribution or provider (e.g. "k3s", "kind", "kubeadm",
        "eks", "talos"). Informational — packages should query
        cluster.capabilities, not branch on provider names.
      '';
    };

    cluster.capabilities = {

      # --- Topology ---

      multiNode = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether the cluster has multiple schedulable nodes. When false,
          pod anti-affinity and topology spread constraints are meaningless.
        '';
      };

      availabilityZones = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Known availability zones. Empty = single-zone or unknown.";
      };

      nodeAutoscaling = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether the cluster has built-in node autoscaling (cloud autoscaler,
          Karpenter, GKE Autopilot). When true, cluster.nodes is a snapshot
          and the actual node count may vary.
        '';
      };

      managedControlPlane = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether the control plane is managed by a provider (EKS, GKE, AKS).
          When true, kube-system components like CoreDNS/etcd are not user-managed,
          and deploying replacements will conflict.
        '';
      };

      # --- Networking ---

      loadBalancer = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether Services of type LoadBalancer can obtain an external IP.
          Requires a LoadBalancer controller (cloud provider, MetalLB, etc.).
        '';
      };

      # TODO: CNI could become a DI dep — packages that need specific CNI
      # features (e.g. Cilium's eBPF, Calico's BGP) could take the CNI as
      # a dep and query its capabilities via out.*.
      cni = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          CNI plugin name (e.g. 'cilium', 'calico', 'flannel', 'aws-vpc-cni',
          'gke-native', 'azure-cni', 'ovn-kubernetes', 'canal', 'kindnet').
          null = unknown or not yet installed.
        '';
      };

      # TODO: Should be derived from the CNI DI dep once CNI becomes DI.
      # The CNI provider would expose out.networkPolicyAPI.
      networkPolicyAPI = lib.mkOption {
        type = lib.types.enum [
          "k8s"
          "cilium"
          "calico"
          "none"
        ];
        default = "none";
        description = ''
          Which network policy API is enforced. "none" means NetworkPolicy
          resources are accepted but not enforced (e.g. flannel, kindnet).
        '';
      };

      # TODO: Will be replaced by DI. Ingress controller should be a DI dep
      # with alias "ingressController", exposing out.ingressClassName. Packages
      # that create Ingress resources take it as a dep. This capability remains
      # as informational metadata for the flavor but is not checked at build time.
      ingressController = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Built-in ingress controller, if any (e.g. "traefik", "gce", "openshift-router").
          null = bring your own.
        '';
      };

      # --- Storage ---

      # TODO: Storage is handled via DI (storageClasses dep). This capability
      # is informational only — used for warnings (e.g. "PVC data is ephemeral
      # on kind"), not build errors. The actual storage provisioner presence is
      # verified through DI resolution of storageClasses.
      persistentStorage = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether PVC data survives cluster restarts. False for kind/ephemeral
          clusters where volumes are backed by container filesystems.
        '';
      };

      # TODO: Could become a DI property — the storage provider import could
      # expose out.accessModes = ["ReadWriteOnce" "ReadWriteMany"] and PVC
      # packages validate against it at build time.
      rwxStorage = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether ReadWriteMany PVCs are supported (NFS, EFS, Longhorn, etc.).";
      };

      # TODO: Could become DI — a snapshot controller provider with alias
      # "volumeSnapshots" that packages creating VolumeSnapshot resources
      # take as a dep. Similar to how CRD operators work via mkCRDRef.
      volumeSnapshots = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether VolumeSnapshot CRDs and a snapshot controller are available.
          Requires CSI driver with snapshot support.
        '';
      };

      # --- Compute ---

      gpu = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether GPU scheduling (nvidia.com/gpu) is available.";
      };

      # --- Security ---

      privilegedContainers = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether pods can run privileged, use hostNetwork, hostPID, etc.
          False on GKE Autopilot (hard platform restriction) and effectively
          false on OpenShift (SCC restricted by default).
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
        type = lib.types.bool;
        default = true;
        description = ''
          Whether DaemonSets can be deployed. False on GKE Autopilot where
          the platform manages all node-level daemons.
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
        };
      };
      default = { };
      description = "Scorecard policy evaluation. See v2_discussions/60_scorecard_rules_design.md.";
    };

    networkPolicy = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Generate CiliumNetworkPolicies from DI graph.";
          };
          defaultDeny = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Generate deny-all CiliumNetworkPolicy per namespace.";
          };
          directions = lib.mkOption {
            type = lib.types.enum [
              "ingress"
              "egress"
              "both"
            ];
            default = "both";
            description = "Which policy directions to generate.";
          };
          platformIntents = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = { };
            description = ''
              Platform connectivity intents for non-kix-managed pods (e.g.
              CoreDNS, local-path-provisioner in kind). Each intent declares
              enforcer-agnostic connectivity requirements; the enforcer
              materializes them into native policy CRs. Set by flavors.
              See v2_discussions/92_declarative_network_policy_intents.md.
            '';
          };
        };
      };
      default = { };
      description = ''
        CiliumNetworkPolicy generation from DI graph. See v2_discussions/37
        and v2_discussions/83. The enforcer that CNPs depend on is looked up
        automatically via `meta.provides ∋ "network-policy-enforcer"` (see
        `kix/packages/cilium`) — no explicit wiring is required, but an
        enforcer instance MUST be declared when `enable = true`. kix throws
        at cluster eval time if no enforcer is resolved: without the
        store-path edge to cilium, CNPs would race the operator at apply
        time. For externally-managed cilium (k3s with cilium helm-installed,
        kind with bootstrap-installed cilium, RKE2's bundled cilium, etc.)
        use `packages."cilium".external`, which emits only the CNP CRD ref
        marker without deploying cilium itself.
      '';
    };
  };
}

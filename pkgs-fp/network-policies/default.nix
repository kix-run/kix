# Network Policies package — fixpoint pattern.
#
# Source: direct translation of raw K8s CiliumNetworkPolicy /
# CiliumClusterwideNetworkPolicy resources (no Helm chart).
#
# This package codifies the cluster's network segmentation policy using
# Cilium's CRDs. The policies enforce:
#   1. DNS egress for all pods (global-dns)
#   2. Kubernetes API server ingress (kubernetes-api-access)
#   3. Ingress-nginx accessibility (global-access-to-ingress-nginx)
#   4. Internal namespace mesh (internal-system-traffic, one per namespace)
#   5. Nginx full cluster access (ingress-nginx-can-access-pods)
#   6. Optional: KubeVirt API/CDI ingress, JuiceFS-to-MinIO, DNS exporter
#
# Design decisions:
#   - CiliumClusterwideNetworkPolicy is used for policies that must apply
#     across all namespaces (DNS, API access, ingress-nginx global).
#     These are cluster-scoped CRDs → namespace = null.
#   - CiliumNetworkPolicy is namespace-scoped. The per-namespace
#     internal-system-traffic policies are generated via lib.listToAttrs +
#     map from the internalNamespaces list.
#   - Optional policies (kubevirt, juicefs, dns-exporter) are always
#     defined in the fixpoint but only pulled into the closure via
#     lib.optional in the main's withRequires. This follows the fixpoint
#     pattern: no mkIf, gate via requires.
#   - These are Cilium CRDs (apiVersion = "cilium.io/v2"), so kubeconform
#     won't have schemas for them — that's expected (ignore-missing-schemas).
#   - main = the global-dns policy, which is the most fundamental policy
#     (without DNS nothing works). All other policies are pulled in via
#     withRequires.

{ k8s, lib }:

k8s.mkPackage
  (
    {
      # --- Package arguments ---
      #
      # internalNamespaces: the set of namespaces that should be able to
      # freely communicate with each other and with the host/kube-apiserver.
      # This is the "trusted internal mesh". Add a namespace here when its
      # workloads need unrestricted access to other internal services.
      internalNamespaces ? [
        "default"
        "kube-system"
        "openebs-system"
        "harbor-system"
        "nginx-system"
        "stackgres-system"
        "minio-system"
        "monitoring-system"
        "velero-system"
      ],

      # Feature gates for optional policies. Each controls a group of
      # CiliumNetworkPolicies that only make sense when the corresponding
      # workload is deployed in the cluster.
      enableKubevirtPolicies ? true,
      enableJuicefsPolicies ? true,
      enableDnsExporterPolicy ? true,

      # Cluster-wide labels merged into every resource. Injected by the
      # cluster definition (e.g., environment=prod, team=platform).
      clusterLabels ? { },

      # Instance name — used in app.kubernetes.io/instance label.
      instance ? "release-name",
    }:
    self:
    let
      # --- Labels ---
      # selectorLabels: identity labels for this package.
      # allLabels: superset used on every resource (includes managed-by).
      selectorLabels = {
        "app.kubernetes.io/instance" = instance;
        "app.kubernetes.io/name" = "network-policies";
      };

      allLabels =
        clusterLabels
        // selectorLabels
        // {
          "app.kubernetes.io/managed-by" = "kix";
        };

      # --- Helpers ---

      # Shorthand for Cilium CRD apiVersion — used by every resource.
      ciliumApi = "cilium.io/v2";

      # Helper to build an "all pods" endpoint selector (empty = match all).
      # Cilium uses an empty endpointSelector ({}) to mean "all pods in the
      # policy's scope" (namespace for CiliumNetworkPolicy, cluster-wide for
      # CiliumClusterwideNetworkPolicy).
      allEndpoints = {
        matchLabels = { };
      };

    in
    {

      # ══════════════════════════════════════════════════════════════════
      # Cluster-wide policies (CiliumClusterwideNetworkPolicy)
      # These are cluster-scoped CRDs → namespace = null.
      # ══════════════════════════════════════════════════════════════════

      # ── 1. global-dns ─────────────────────────────────────────────────
      #
      # The most fundamental network policy: every pod in the cluster must
      # be able to resolve DNS. Without this, nothing works. This policy:
      #   - Allows all pods to egress to kube-dns on UDP/53
      #   - Allows kube-dns to receive ingress from all pods on UDP/53
      #
      # This is the `main` resource because DNS is the foundation of all
      # cluster networking — if DNS is blocked, every other policy is moot.

      global-dns = k8s.mkResource {
        apiVersion = ciliumApi;
        kind = "CiliumClusterwideNetworkPolicy";
        name = "global-dns";
        namespace = null;
        labels = allLabels;
        spec = {
          endpointSelector = allEndpoints;
          egress = [
            {
              toEndpoints = [
                {
                  matchLabels = {
                    "k8s:io.kubernetes.pod.namespace" = "kube-system";
                    "k8s:k8s-app" = "kube-dns";
                  };
                }
              ];
              toPorts = [
                {
                  ports = [
                    {
                      port = "53";
                      protocol = "UDP";
                    }
                  ];
                }
              ];
            }
          ];
          ingress = [
            {
              fromEndpoints = [
                allEndpoints
              ];
              toPorts = [
                {
                  ports = [
                    {
                      port = "53";
                      protocol = "UDP";
                    }
                  ];
                }
              ];
            }
          ];
        };
      };

      # ── 2. kubernetes-api-access ──────────────────────────────────────
      #
      # Protects the Kubernetes API server. Only allows ingress from
      # specific Cilium identity sources (remote-node, health, host) on
      # the standard API ports (6443, 443). The nodeSelector targets
      # control-plane nodes (master role label).

      kubernetes-api-access = k8s.mkResource {
        apiVersion = ciliumApi;
        kind = "CiliumClusterwideNetworkPolicy";
        name = "kubernetes-api-access";
        namespace = null;
        labels = allLabels;
        spec = {
          # Target only control-plane nodes.
          nodeSelector = {
            matchLabels = {
              "node-role.kubernetes.io/master" = "true";
            };
          };
          ingress = [
            {
              fromEntities = [
                "remote-node"
                "health"
                "host"
              ];
              toPorts = [
                {
                  ports = [
                    {
                      port = "6443";
                      protocol = "TCP";
                    }
                    {
                      port = "443";
                      protocol = "TCP";
                    }
                  ];
                }
              ];
            }
          ];
        };
      };

      # ── 3. global-access-to-ingress-nginx ─────────────────────────────
      #
      # Ingress-nginx is the front door of the cluster. All pods need to
      # be able to reach it (for internal redirects, webhooks calling back
      # through the ingress, etc.), and ingress-nginx needs to reach all
      # pods (to proxy traffic to backends).
      #
      # This is intentionally broad — ingress-nginx's own more specific
      # policies (ingress-nginx-can-access-pods below) further refine its
      # access. This policy just ensures the basic connectivity exists.

      global-access-to-ingress-nginx = k8s.mkResource {
        apiVersion = ciliumApi;
        kind = "CiliumClusterwideNetworkPolicy";
        name = "global-access-to-ingress-nginx";
        namespace = null;
        labels = allLabels;
        spec = {
          endpointSelector = allEndpoints;
          egress = [
            {
              toEndpoints = [
                {
                  matchLabels = {
                    "k8s:io.kubernetes.pod.namespace" = "nginx-system";
                    "k8s:app.kubernetes.io/name" = "ingress-nginx";
                  };
                }
              ];
            }
          ];
          ingress = [
            {
              fromEndpoints = [
                {
                  matchLabels = {
                    "k8s:io.kubernetes.pod.namespace" = "nginx-system";
                    "k8s:app.kubernetes.io/name" = "ingress-nginx";
                  };
                }
              ];
            }
          ];
        };
      };

      # ══════════════════════════════════════════════════════════════════
      # Per-namespace policies (CiliumNetworkPolicy)
      # ══════════════════════════════════════════════════════════════════

      # ── 4. internal-system-traffic (one per namespace) ────────────────
      #
      # Creates a CiliumNetworkPolicy in each internal namespace that
      # allows free ingress/egress between all internal namespaces, plus
      # communication with the host and kube-apiserver entities.
      #
      # This forms the "trusted internal mesh" — namespaces listed in
      # internalNamespaces can talk freely to each other. This is the
      # pragmatic approach: rather than defining fine-grained per-service
      # policies for internal infrastructure, we trust the internal
      # namespace boundary.
      #
      # Each policy allows:
      #   - Ingress from: all internal namespaces + host + kube-apiserver
      #   - Egress to: all internal namespaces + host + kube-apiserver
      #
      # We use lib.listToAttrs + map to generate one resource per
      # namespace from the internalNamespaces list. The attribute name
      # in the fixpoint is "internal-traffic-<namespace>" so each is
      # individually addressable via self.

    }
    // (lib.listToAttrs (
      map (
        ns:
        lib.nameValuePair "internal-traffic-${ns}" (
          k8s.mkResource {
            apiVersion = ciliumApi;
            kind = "CiliumNetworkPolicy";
            name = "internal-system-traffic-${ns}";
            namespace = ns;
            labels = allLabels;
            spec = {
              endpointSelector = allEndpoints;
              ingress = [
                {
                  fromEndpoints = map (fromNs: {
                    matchLabels = {
                      "k8s:io.kubernetes.pod.namespace" = fromNs;
                    };
                  }) internalNamespaces;
                }
                {
                  fromEntities = [
                    "host"
                    "kube-apiserver"
                  ];
                }
              ];
              egress = [
                {
                  toEndpoints = map (toNs: {
                    matchLabels = {
                      "k8s:io.kubernetes.pod.namespace" = toNs;
                    };
                  }) internalNamespaces;
                }
                {
                  toEntities = [
                    "host"
                    "kube-apiserver"
                  ];
                }
              ];
            };
          }
        )
      ) internalNamespaces
    ))
    // {

      # ── 5. ingress-nginx-can-access-pods ──────────────────────────────
      #
      # Gives nginx pods in nginx-system full cluster egress and ingress.
      # This is necessary because ingress-nginx needs to proxy to ANY
      # backend service in any namespace. The global-access-to-ingress-nginx
      # policy above handles the "pods can reach nginx" direction; this
      # policy handles the "nginx can reach pods" direction from nginx's
      # own namespace perspective.
      #
      # Uses Cilium entities "cluster" and "world" for broad access —
      # ingress-nginx by definition needs to talk to external clients
      # and any internal service.

      ingress-nginx-can-access-pods = k8s.mkResource {
        apiVersion = ciliumApi;
        kind = "CiliumNetworkPolicy";
        name = "ingress-nginx-can-access-pods";
        namespace = "nginx-system";
        labels = allLabels;
        spec = {
          endpointSelector = {
            matchLabels = {
              "app.kubernetes.io/name" = "ingress-nginx";
            };
          };
          egress = [
            {
              toEntities = [
                "cluster"
                "world"
              ];
            }
          ];
          ingress = [
            {
              fromEntities = [
                "cluster"
                "world"
              ];
            }
          ];
        };
      };

      # ══════════════════════════════════════════════════════════════════
      # Optional policies — gated via lib.optional in main's withRequires
      # ══════════════════════════════════════════════════════════════════

      # ── 6. virt-api-ingress (KubeVirt) ────────────────────────────────
      #
      # KubeVirt's virt-api is a webhook server that the Kubernetes API
      # server calls for VM-related admission webhooks. Without this
      # policy, the API server can't reach virt-api and all VM operations
      # fail with webhook timeouts.

      virt-api-ingress = k8s.mkResource {
        apiVersion = ciliumApi;
        kind = "CiliumNetworkPolicy";
        name = "virt-api-ingress";
        namespace = "kubevirt";
        labels = allLabels;
        spec = {
          endpointSelector = {
            matchLabels = {
              "kubevirt.io" = "virt-api";
            };
          };
          ingress = [
            {
              fromEntities = [
                "host"
                "remote-node"
                "kube-apiserver"
              ];
              toPorts = [
                {
                  ports = [
                    {
                      port = "443";
                      protocol = "TCP";
                    }
                    {
                      port = "8443";
                      protocol = "TCP";
                    }
                  ];
                }
              ];
            }
          ];
        };
      };

      # ── 7. cdi-apiserver-ingress (CDI / KubeVirt) ─────────────────────
      #
      # CDI (Containerized Data Importer) is KubeVirt's companion for
      # importing VM disk images. Its API server also serves webhooks
      # that the K8s API server needs to reach.

      cdi-apiserver-ingress = k8s.mkResource {
        apiVersion = ciliumApi;
        kind = "CiliumNetworkPolicy";
        name = "cdi-apiserver-ingress";
        namespace = "cdi";
        labels = allLabels;
        spec = {
          endpointSelector = {
            matchLabels = {
              "cdi.kubevirt.io" = "cdi-apiserver";
            };
          };
          ingress = [
            {
              fromEntities = [
                "host"
                "remote-node"
                "kube-apiserver"
              ];
              toPorts = [
                {
                  ports = [
                    {
                      port = "443";
                      protocol = "TCP";
                    }
                    {
                      port = "8443";
                      protocol = "TCP";
                    }
                  ];
                }
              ];
            }
          ];
        };
      };

      # ── 8. juicefs-to-minio ───────────────────────────────────────────
      #
      # JuiceFS needs to reach MinIO (S3-compatible object storage) for
      # its data backend. This policy allows pods in juicefs-system to
      # egress to minio-system on the MinIO API port (9000) and console
      # port (9001).

      juicefs-to-minio = k8s.mkResource {
        apiVersion = ciliumApi;
        kind = "CiliumNetworkPolicy";
        name = "juicefs-to-minio";
        namespace = "juicefs-system";
        labels = allLabels;
        spec = {
          endpointSelector = allEndpoints;
          egress = [
            {
              toEndpoints = [
                {
                  matchLabels = {
                    "k8s:io.kubernetes.pod.namespace" = "minio-system";
                  };
                }
              ];
              toPorts = [
                {
                  ports = [
                    {
                      port = "9000";
                      protocol = "TCP";
                    }
                    {
                      port = "9001";
                      protocol = "TCP";
                    }
                  ];
                }
              ];
            }
          ];
        };
      };

      # ── 9. dns-exporter-external-dns ──────────────────────────────────
      #
      # The DNS exporter in monitoring-system needs to make external DNS
      # queries to check domain resolution. This policy allows it to
      # egress to the world on UDP/53 and TCP/53 (TCP for large responses
      # or zone transfers).

      dns-exporter-external-dns = k8s.mkResource {
        apiVersion = ciliumApi;
        kind = "CiliumNetworkPolicy";
        name = "dns-exporter-external-dns";
        namespace = "monitoring-system";
        labels = allLabels;
        spec = {
          endpointSelector = {
            matchLabels = {
              "app.kubernetes.io/name" = "dns-exporter";
            };
          };
          egress = [
            {
              toEntities = [ "world" ];
              toPorts = [
                {
                  ports = [
                    {
                      port = "53";
                      protocol = "UDP";
                    }
                    {
                      port = "53";
                      protocol = "TCP";
                    }
                  ];
                }
              ];
            }
          ];
        };
      };

      # ══════════════════════════════════════════════════════════════════
      # Main: the public interface
      # ══════════════════════════════════════════════════════════════════
      #
      # main = the global-dns policy because DNS is the foundation of all
      # cluster networking. All other policies are pulled in via
      # withRequires. Optional policies are gated by their respective
      # feature flags using lib.optional.
      #
      # The per-namespace internal-traffic policies are collected from the
      # fixpoint using map over internalNamespaces to look up each
      # "internal-traffic-<ns>" attribute from self.

      main = k8s.withRequires (
        [
          self.kubernetes-api-access
          self.global-access-to-ingress-nginx
          self.ingress-nginx-can-access-pods
        ]
        # Per-namespace internal-system-traffic policies — one per namespace.
        ++ map (ns: self.${"internal-traffic-${ns}"}) internalNamespaces
        # Optional policy groups, gated by feature flags.
        ++ lib.optional enableKubevirtPolicies self.virt-api-ingress
        ++ lib.optional enableKubevirtPolicies self.cdi-apiserver-ingress
        ++ lib.optional enableJuicefsPolicies self.juicefs-to-minio
        ++ lib.optional enableDnsExporterPolicy self.dns-exporter-external-dns
      ) self.global-dns;

    }
  )
  {
    # Default arguments — empty clusterLabels / standard instance name.
    # No namespace default because this package creates resources across
    # many namespaces (each resource specifies its own).
  }

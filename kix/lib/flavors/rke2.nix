# RKE2 flavor.
#
# RKE2 installs Canal (Flannel with Calico NetworkPolicy enforcement) by
# default, along with CoreDNS, metrics-server, and `rke2-snapshot-controller`.
# No default StorageClass or LoadBalancer is included.
#
# `cluster.flavor.rke2.cni` must match the `cni` list in RKE2's server config.
# `canal`, `calico`, and `flannel` bind `cni` exclusively. `cilium` exposes the
# bundled chart as `kube-system/platform-cilium` so a `cilium` instance in
# `kube-system` can configure it through the `kube-system/rke2-cilium`
# HelmChartConfig. `none` leaves the `cni` role `absent` for a managed CNI.
#
# When `networkPolicy.enable = true`, this flavor declares platform network
# policy intents for RKE2's bundled charts in `kube-system` (`rancher/rke2`
# `charts/chart_versions.yaml`) so default-deny policies in `kube-system` do
# not block them.

{
  config,
  lib,
  kix,
  ...
}:
let
  platformDns = import ./platform-dns.nix {
    inherit kix;
    inherit (config) clusterDomain;
  };
  inherit (import ../core/error.nix { inherit lib; }) fail;
  cni = config.cluster.flavor.rke2.cni;
  primaries = builtins.filter (c: c != "multus") cni;
  multusCount = builtins.length cni - builtins.length primaries;
  validCni =
    builtins.length primaries == 1
    && (builtins.elem "none" cni -> cni == [ "none" ])
    && multusCount <= 1
    && (multusCount == 1 -> builtins.head cni == "multus");
  primary =
    if validCni then
      builtins.head primaries
    else
      fail {
        clusterOption = "cluster.flavor.rke2.cni";
        message = "cluster.flavor.rke2.cni = ${builtins.toJSON cni} is not a valid RKE2 cni list.";
        fix = "Give one primary CNI (canal, calico, cilium, flannel), optionally preceded by multus, or [ \"none\" ].";
      };

  apiserver = {
    to = "apiserver";
  };
  tcp = port: {
    inherit port;
    protocol = "TCP";
  };
  inKubeSystem =
    podSelector: intent:
    {
      namespace = "kube-system";
      inherit podSelector;
    }
    // intent;

  # Non-bootstrap charts whose `helm-install` Jobs run on the pod network
  # rather than the host network.
  nonBootstrapCharts = [
    "rke2-gateway-api-crd"
    "rke2-ingress-nginx"
    "rke2-metrics-server"
    "rke2-multus"
    "rke2-multus-crd"
    "rke2-runtimeclasses"
    "rke2-security-responder"
    "rke2-snapshot-controller"
    "rke2-snapshot-controller-crd"
    "rke2-traefik"
    "rke2-traefik-crd"
  ];
in
{
  options.cluster.flavor.rke2.cni = lib.mkOption {
    type = lib.types.listOf (
      lib.types.enum [
        "multus"
        "canal"
        "calico"
        "cilium"
        "flannel"
        "none"
      ]
    );
    default = [ "canal" ];
    description = ''
      The `cni` list of RKE2's server config. Kix cannot read it, so it must
      match. Kix reads it to bind the cni role: canal, calico, and flannel
      are exclusive; cilium is shadowable and declares the import
      kube-system/platform-cilium, naming RKE2's HelmChartConfig
      kube-system/rke2-cilium, so a `cilium` instance configures RKE2's
      bundled Cilium; none leaves the role vacant for a managed CNI. multus
      may precede the primary CNI.
    '';
  };

  config = {
    cluster.provider = lib.mkDefault "rke2";

    # Default `cluster-cidr` in RKE2.
    cluster.network.podCidr = lib.mkDefault "10.42.0.0/16";

    cluster.roles = {
      cni = lib.mkMerge [
        (lib.mkIf
          (builtins.elem primary [
            "canal"
            "calico"
            "flannel"
          ])
          {
            binding = lib.mkDefault "exclusive";
            provider = lib.mkDefault primary;
          }
        )
        (lib.mkIf (primary == "cilium") {
          binding = lib.mkDefault "shadowable";
          provider = lib.mkDefault "cilium (rke2-cilium chart)";
        })
        (lib.mkIf (primary == "none") {
          binding = lib.mkDefault "absent";
        })
      ];
      dns.binding = lib.mkDefault "shadowable";
      storageClasses.binding = lib.mkDefault "absent";
      loadBalancer.binding = lib.mkDefault "absent";
      # Override to "absent" when `rke2-snapshot-controller` and
      # `rke2-snapshot-controller-crd` are disabled in the RKE2 server config.
      snapshotController = {
        binding = lib.mkDefault "exclusive";
        provider = lib.mkDefault "rke2-snapshot-controller";
      };
      # Override to "absent" when `rke2-metrics-server` is disabled in the RKE2
      # server config.
      metricsApi = {
        binding = lib.mkDefault "exclusive";
        provider = lib.mkDefault "rke2-metrics-server";
      };
      # Leave `registryMirror` unset by default because RKE2 only enables its
      # embedded Spegel mirror when `embedded-registry: true` is configured.
    };

    # RKE2 uses the k3s agent containerd layout under `/var/lib/rancher/rke2`
    # and leaves `discard_unpacked_layers` false.
    cluster.containerd = {
      socket = lib.mkDefault "/run/k3s/containerd/containerd.sock";
      registryConfigPath = lib.mkDefault "/var/lib/rancher/rke2/agent/etc/containerd/certs.d";
      contentPath = lib.mkDefault "/var/lib/rancher/rke2/agent/containerd/io.containerd.content.v1.content";
      discardUnpackedLayers = lib.mkDefault false;
    };

    cluster.capabilities = {
      managedControlPlane = lib.mkDefault false;
      nodeAutoscaling = lib.mkDefault false;
      privilegedContainers = lib.mkDefault true;
      daemonSets = lib.mkDefault true;
    };

    instances.kube-system = {
      platform-dns = platformDns {
        name = "rke2-coredns-rke2-coredns";
        namespace = "kube-system";
      };

      # Expose `out.helmChartConfig` so the `cilium` package can configure
      # RKE2's bundled Cilium chart. Keep this import non-optional because the
      # `cilium` package consumes it via an optional dependency, which does not
      # activate optional imports.
      platform-cilium = lib.mkIf (primary == "cilium") {
        package = kix.mkImport {
          roles = [ "cni" ];
          out.helmChartConfig = {
            name = "rke2-cilium";
            namespace = "kube-system";
          };
        };
      };

      platform-snapshot-controller = {
        package = kix.mkImport {
          roles = [ "snapshotController" ];
          crds = [
            {
              group = "snapshot.storage.k8s.io";
              kind = "VolumeSnapshotClass";
              plural = "volumesnapshotclasses";
              version = "v1";
              crdScope = "Cluster";
            }
            {
              group = "snapshot.storage.k8s.io";
              kind = "VolumeSnapshotContent";
              plural = "volumesnapshotcontents";
              version = "v1";
              crdScope = "Cluster";
            }
            {
              group = "snapshot.storage.k8s.io";
              kind = "VolumeSnapshot";
              plural = "volumesnapshots";
              version = "v1";
              crdScope = "Namespaced";
            }
          ];
        };
      };
    };

    networkPolicy.platformIntents = lib.mkIf config.networkPolicy.enable (
      {
        # Declare CoreDNS intents at the flavor level rather than on
        # `platform-dns` because `platform-dns` is optional and may remain
        # inactive while `kube-system` default-deny is active.
        rke2-coredns-egress = inKubeSystem { "k8s-app" = "kube-dns"; } {
          egress = [
            apiserver
            {
              to = "world";
              ports = [
                {
                  port = 53;
                  protocol = "UDP";
                }
                (tcp 53)
                (tcp 443)
              ];
            }
          ];
        };
        rke2-coredns-ingress = inKubeSystem { "k8s-app" = "kube-dns"; } {
          ingress = [
            {
              from = "all-pods";
              ports = [
                {
                  port = 53;
                  protocol = "UDP";
                }
                (tcp 53)
              ];
            }
          ];
        };

        rke2-coredns-autoscaler-egress = inKubeSystem { "k8s-app" = "kube-dns-autoscaler"; } {
          egress = [ apiserver ];
        };

        # The `apiserver` egress target also permits `host` and `remote-node`
        # identities on all ports, covering kubelet scraping on port 10250.
        rke2-metrics-server-egress = inKubeSystem { app = "rke2-metrics-server"; } {
          egress = [ apiserver ];
        };
        # `all-pods` maps to Cilium's `cluster` entity, which includes the
        # host-networked API server calling metrics-server.
        rke2-metrics-server-ingress = inKubeSystem { app = "rke2-metrics-server"; } {
          ingress = [
            {
              from = "all-pods";
              ports = [ (tcp 10250) ];
            }
          ];
        };

        rke2-snapshot-controller-egress =
          inKubeSystem { "app.kubernetes.io/name" = "rke2-snapshot-controller"; }
            {
              egress = [ apiserver ];
            };

        rke2-ingress-nginx-controller-egress =
          inKubeSystem
            {
              "app.kubernetes.io/name" = "rke2-ingress-nginx";
              "app.kubernetes.io/component" = "controller";
            }
            {
              egress = [
                apiserver
                # Proxies to backends on any port in any namespace.
                { to = "all-pods"; }
              ];
            };
        rke2-ingress-nginx-controller-ingress =
          inKubeSystem
            {
              "app.kubernetes.io/name" = "rke2-ingress-nginx";
              "app.kubernetes.io/component" = "controller";
            }
            {
              ingress = [
                {
                  from = "world";
                  ports = [
                    (tcp 80)
                    (tcp 443)
                  ];
                }
                {
                  from = "all-pods";
                  ports = [
                    (tcp 80)
                    (tcp 443)
                    # The validating webhook, called by the API server.
                    (tcp 8443)
                  ];
                }
              ];
            };
        rke2-ingress-nginx-admission-egress =
          inKubeSystem
            {
              "app.kubernetes.io/name" = "rke2-ingress-nginx";
              "app.kubernetes.io/component" = "admission-webhook";
            }
            {
              egress = [ apiserver ];
            };

        rke2-traefik-egress = inKubeSystem { "app.kubernetes.io/name" = "rke2-traefik"; } {
          egress = [
            apiserver
            # Proxies to backends on any port in any namespace.
            { to = "all-pods"; }
          ];
        };
        rke2-traefik-ingress = inKubeSystem { "app.kubernetes.io/name" = "rke2-traefik"; } {
          ingress = [
            {
              from = "world";
              ports = [
                (tcp 8000)
                (tcp 8443)
              ];
            }
            {
              from = "all-pods";
              ports = [
                (tcp 8000)
                (tcp 8443)
              ];
            }
          ];
        };

        # Reports the RKE2 version to security-responder.version.rke2.io.
        rke2-security-responder-egress =
          inKubeSystem { "app.kubernetes.io/name" = "rke2-security-responder"; }
            {
              egress = [
                { to = "dns"; }
                {
                  to = "world";
                  ports = [ (tcp 443) ];
                }
              ];
            };
      }
      // lib.listToAttrs (
        map (chart: {
          name = "helm-install-${chart}-egress";
          value = inKubeSystem { "helmcharts.helm.cattle.io/chart" = chart; } {
            egress = [ apiserver ];
          };
        }) nonBootstrapCharts
      )
    );
  };
}

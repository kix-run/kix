# RKE2 flavor.
#
# Designed for security-conscious environments. RKE2 installs Canal
# (Flannel + Calico NetworkPolicy enforcement) by default, CIS benchmark
# hardened. No default StorageClass or LoadBalancer is provided; install
# Longhorn, MetalLB, etc.
#
# The cni role follows cluster.flavor.rke2.cni, which must match the `cni`
# list of RKE2's server config. canal, calico, and flannel own the role
# exclusively. With cilium, RKE2 installs its bundled Cilium chart, the
# flavour declares it as the platform import kube-system/platform-cilium,
# and a `cilium` instance in kube-system configures it through the
# HelmChartConfig kube-system/rke2-cilium that the import names. With none,
# the role is vacant for a managed CNI.
#
# Platform intents: when networkPolicy.enable = true, declares connectivity
# for the pods RKE2's bundled charts run in kube-system, so the
# kube-system default-deny policy does not cut them off. Labels and ports
# come from the rke2-charts releases that RKE2 1.33 and the newest RKE2
# ship (rancher/rke2 charts/chart_versions.yaml). An intent whose selector
# matches no pod selects nothing, so components a cluster disables are
# harmless.
#
# cluster.network.podCidr defaults to RKE2's cluster-cidr, 10.42.0.0/16.
#
# Platform imports: DNS (coredns), the VolumeSnapshot API
# (rke2-snapshot-controller), and Cilium when cni names it. No default
# storage.

{
  config,
  lib,
  kix,
  ...
}:
let
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
      throw "kix: cluster.flavor.rke2.cni = ${builtins.toJSON cni} is not a valid RKE2 cni list: it takes one primary CNI (canal, calico, cilium, flannel), optionally preceded by multus, or [ \"none\" ].";

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

  # Charts RKE2 installs without `bootstrap: true`. helm-controller runs their
  # helm-install Jobs on the pod network (bootstrap charts' Jobs use the host
  # network), labelled with the chart name.
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

    # RKE2's default cluster-cidr.
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
      storageClasses.binding = lib.mkDefault "absent"; # no default StorageClass
      loadBalancer.binding = lib.mkDefault "absent";
      # RKE2 installs the snapshot CRDs and controller (the
      # rke2-snapshot-controller and rke2-snapshot-controller-crd charts). A
      # cluster that disables both charts sets the binding to "absent" and
      # runs a snapshot-controller instance.
      snapshotController = {
        binding = lib.mkDefault "exclusive";
        provider = lib.mkDefault "rke2-snapshot-controller";
      };
      # RKE2 installs metrics-server (the rke2-metrics-server chart). A
      # cluster that disables the chart sets the binding to "absent" and runs
      # a metrics-server instance.
      metricsApi = {
        binding = lib.mkDefault "exclusive";
        provider = lib.mkDefault "rke2-metrics-server";
      };
      # registryMirror stays unknown: RKE2 embeds Spegel but runs it only
      # with `embedded-registry: true` in the server config. A cluster that
      # turns it on sets the binding to "exclusive", so a spegel instance is
      # refused.
    };

    # RKE2's agent is k3s's (pkg/agent/config in k3s) with the data
    # directory /var/lib/rancher/rke2. Its containerd config does not set
    # discard_unpacked_layers, which containerd defaults to false.
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

    # Platform-provided imports.
    instances.kube-system = {
      platform-dns = {
        package = kix.mkImport {
          kind = "Deployment";
          apiVersion = "apps/v1";
          roles = [ "dns" ];
          out = {
            name = "coredns";
            fqdn = "kube-dns.kube-system.svc.${config.clusterDomain}";
          };
        };
        optional = true;
      };

      # The `cilium` package reads out.helmChartConfig to write its values
      # into RKE2's bundled chart. Not optional: the package takes it as an
      # optional dependency, which never activates an optional import.
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
        # In the flavour rather than on the platform-dns import: the import
        # is optional and stays inactive until a required dependency demands
        # DNS, but kube-system's default-deny policy applies either way.
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

        # The apiserver rule also admits the `host` and `remote-node`
        # identities on every port, which covers the kubelets metrics-server
        # scrapes on 10250
        # (housekeeping/2026-10-01-apiserver-egress-rule-allows-every-host-port.md).
        rke2-metrics-server-egress = inKubeSystem { app = "rke2-metrics-server"; } {
          egress = [ apiserver ];
        };
        # The `all-pods` source is Cilium's `cluster` entity, which includes
        # the host-networked API server that calls metrics-server.
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

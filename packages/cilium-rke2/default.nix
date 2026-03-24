# Cilium HelmChartConfig — configures RKE2's bundled Cilium via HelmChartConfig.
#
# This package does NOT deploy Cilium itself (RKE2 bundles it). It generates
# the HelmChartConfig resource that configures Cilium's Helm values.
#
# Exposes out.nodePortReliable — false when the config combination (DSR +
# BPF masquerade + loopback IPs in nodePort.addresses) is known to cause
# unreliable NodePort from pods to remote nodes.
#
# main = HelmChartConfig/rke2-cilium

{
  scope,
  lib,
}:

let
  # IP math for computing nodePort addresses from cluster topology
  ipToInt =
    ip:
    let
      parts = map lib.strings.toInt (lib.splitString "." ip);
    in
    builtins.elemAt parts 0 * 16777216
    + builtins.elemAt parts 1 * 65536
    + builtins.elemAt parts 2 * 256
    + builtins.elemAt parts 3;

  intToIp =
    n:
    let
      a = n / 16777216;
      b = (n - a * 16777216) / 65536;
      c = (n - a * 16777216 - b * 65536) / 256;
      d = n - a * 16777216 - b * 65536 - c * 256;
    in
    "${toString a}.${toString b}.${toString c}.${toString d}";

  splitCidr =
    cidr:
    let
      parts = lib.splitString "/" cidr;
      address = builtins.elemAt parts 0;
      prefix = lib.strings.toInt (builtins.elemAt parts 1);
      addrInt = ipToInt address;
      pow2 = n: if n == 0 then 1 else 2 * (pow2 (n - 1));
      maskBits = if prefix == 0 then 0 else (pow2 32) - (pow2 (32 - prefix));
    in
    {
      inherit address prefix;
      networkInt = lib.bitAnd addrInt maskBits;
    };

  addressFromCidr = cidr: offset: intToIp ((splitCidr cidr).networkInt + offset);

in
{
  options = {
    # --- Cluster topology (set by cluster definition) ---
    clusterNodes = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      description = "Cluster node topology: { hostname = { role, ip, hostNumber, loopbackCidr?, ... }; }";
    };

    internalCidr = lib.mkOption {
      type = lib.types.str;
      description = "Internal /14 CIDR (e.g. 10.44.0.0/14). Pod and service CIDRs are derived from this.";
    };

    # --- Cilium config knobs ---
    loadBalancer = {
      mode = lib.mkOption {
        type = lib.types.enum [
          "snat"
          "dsr"
          "hybrid"
        ];
        default = "snat";
        description = "Load balancer mode. DSR has known issues with loopback IPs + BPF masquerade.";
      };
      dsrDispatch = lib.mkOption {
        type = lib.types.enum [
          "opt"
          "geneve"
          "ipip"
        ];
        default = "opt";
        description = "DSR dispatch method (only used when mode=dsr).";
      };
    };

    bpf = {
      masquerade = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Use BPF-based masquerading instead of iptables.";
      };
      lbExternalClusterIP = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
    };

    mtu = lib.mkOption {
      type = lib.types.int;
      default = 1400;
    };

    devices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra devices beyond the defaults (lo, eth0, eth1, vswitch, failoverip, cilium_bgp).";
    };

    policyAuditMode = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Log dropped packets but don't enforce (safe for testing).";
    };

    encryptionEnabled = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };

    hubble = {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
      metrics = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "policy:sourceContext=app|workload-name|pod|reserved-identity;destinationContext=app|workload-name|pod|dns|reserved-identity;labelsContext=source_namespace,destination_namespace"
          "dns:query;ignoreAAAA"
          "drop:sourceContext=app|workload-name|pod|reserved-identity;destinationContext=app|workload-name|pod|dns|reserved-identity;labelsContext=source_namespace,destination_namespace,traffic_direction"
          "flow:sourceContext=app|workload-name|pod|reserved-identity;destinationContext=app|workload-name|pod|dns|reserved-identity;labelsContext=source_namespace,destination_namespace,traffic_direction"
          "flows-to-world:any-drop=true;labelsContext=source_namespace,destination_namespace,traffic_direction"
          "httpV2:exemplars=true;labelsContext=source_namespace,destination_namespace,traffic_direction"
          "tcp"
          "port-distribution"
          "icmp"
        ];
      };
    };

    bgpControlPlane = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };

    operatorReplicas = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "Cilium operator replicas. Null = auto (min(2, nodeCount)).";
    };

    autoRolloutRestart = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };

    podCidrMaskSize = lib.mkOption {
      type = lib.types.int;
      default = 22;
      description = "Per-node pod CIDR mask size. Cilium allocates /N slices from the cluster pod CIDR.";
    };
  };

  build =
    {
      self,
      config,
      clusterConfig,
    }:
    let
      # Derived CIDRs from the /14 internal CIDR
      internalParsed = splitCidr config.internalCidr;
      block = 65536;
      clusterCidr = "${intToIp (internalParsed.networkInt + 1 * block)}/16";
      serviceCidr = "${intToIp (internalParsed.networkInt + 2 * block)}/16";

      # Cluster topology
      servers = lib.filterAttrs (_: n: n.role == "server") config.clusterNodes;
      nodeCount = builtins.length (builtins.attrNames config.clusterNodes);

      # NodePort addresses: public IPs + loopback IPs
      publicIps = lib.mapAttrsToList (_: n: "${n.ip}/32") servers;
      serversWithLoopback = lib.filterAttrs (_: n: n ? loopbackCidr) servers;
      loopbackIps = lib.mapAttrsToList (
        _: n: "${addressFromCidr n.loopbackCidr (n.hostNumber + 1)}/32"
      ) serversWithLoopback;
      nodePortAddresses = publicIps ++ loopbackIps;
      hasLoopbackNodePort = loopbackIps != [ ];

      # NodePort reliability flag
      # DSR + BPF masquerade + loopback IPs is a known-unreliable combination:
      # - Cilium docs warn against node IP on loopback with BPF masquerade
      # - DSR opt dispatch adds IPv4 options that some network fabric may drop
      # - Pod-to-remote-NodePort via loopback shows rotating failures
      nodePortReliable =
        !(config.loadBalancer.mode == "dsr" && config.bpf.masquerade && hasLoopbackNodePort);

      operatorReplicas =
        if config.operatorReplicas != null then
          config.operatorReplicas
        else
          lib.min 2 (if nodeCount > 0 then nodeCount else 1);

      allDevices = [
        "lo"
        "eth0"
        "eth1"
        "vswitch"
        "failoverip"
        "cilium_bgp"
      ]
      ++ config.devices;

      # Build the Helm values attrset
      helmValues = {
        policyEnforcementMode = "always";
        policyAuditMode = config.policyAuditMode;
        kubeProxyReplacement = true;
        routingMode = "native";
        ipv4NativeRoutingCIDR = config.internalCidr;
        enableIPv4Masquerade = true;
        autoDirectNodeRoutes = false;

        loadBalancer = {
          inherit (config.loadBalancer) mode;
        }
        // lib.optionalAttrs (config.loadBalancer.mode == "dsr") {
          inherit (config.loadBalancer) dsrDispatch;
        };

        externalIPs.enabled = true;

        # HelmChartConfig is cluster-wide — all Cilium agents read the same value.
        # 127.0.0.1 works on all RKE2 nodes: servers have the API server locally,
        # agents have RKE2's built-in client-side load balancer on localhost.
        k8sServiceHost = "127.0.0.1";
        k8sServicePort = 6443;
        kubeConfigPath = "/etc/rancher/rke2/rke2.yaml";

        MTU = config.mtu;
        devices = allDevices;
        extraConfig.direct-routing-device = "lo";

        bpf = {
          inherit (config.bpf) masquerade lbExternalClusterIP;
        };

        socketLB.hostNamespaceOnly = true;
        rollOutCiliumPods = config.autoRolloutRestart;

        ipam = {
          mode = "cluster-pool";
          operator.clusterPoolIPv4PodCIDRList = [ clusterCidr ];
          operator.clusterPoolIPv4MaskSize = config.podCidrMaskSize;
        };

        prometheus.enabled = true;
        operator.prometheus.enabled = false;
        operator.replicas = operatorReplicas;

        encryption = {
          enabled = config.encryptionEnabled;
          type = "wireguard";
        };

        nodePort = {
          enabled = true;
          addresses = nodePortAddresses;
        };
      }
      // lib.optionalAttrs config.hubble.enabled {
        hubble = {
          enabled = true;
          metrics = {
            enableOpenMetrics = true;
            serviceMonitor = {
              enabled = true;
              interval = "30s";
            };
            dashboards.enabled = true;
            enabled = config.hubble.metrics;
          };
          relay.enabled = true;
          ui.enabled = true;
        };
      }
      // lib.optionalAttrs config.bgpControlPlane {
        bgpControlPlane.enabled = true;
      };

    in
    {
      # HelmChartConfig is a namespaced resource (must be in kube-system).
      helmChartConfig = scope.mkResource {
        apiVersion = "helm.cattle.io/v1";
        kind = "HelmChartConfig";
        name = "rke2-cilium";
        spec.valuesContent = builtins.toJSON helmValues;
        outputs = {
          inherit nodePortReliable;
          inherit clusterCidr serviceCidr;
        };
      };

      main = self.helmChartConfig;
    };
}

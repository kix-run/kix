      instances.kube-system.cilium = {
        package = packages.cilium;
        config.values = {
          # Keep Kind's kube-proxy and use the pod CIDR from kind-cilium.yaml.
          kubeProxyReplacement = false;
          ipam.operator.clusterPoolIPv4PodCIDRList = [ "10.244.0.0/16" ];

          prometheus.enabled = false;
        };
      };
      instances.gateway-system.gateway.config.proxySpec.provider = {
        type = "Kubernetes";
        kubernetes.envoyService.type = "NodePort";
      };
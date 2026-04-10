# Test cluster: monitoring via kube-prometheus-stack Helm chart.
#
# Minimal cluster for structural comparison against the native monitoring stack.
# Build: nix build .#cluster-monitoring-helm -o result-monitoring-helm

{ kix, packages }:

kix.buildCluster {
  name = "monitoring-helm";
  specialArgs = { inherit packages kix; };
  modules = [
    kix.flavors.kind

    {
      instances.monitoring-system = {
        kube-prometheus-stack = {
          aliases = [
            "prometheus"
            "monitoring"
          ];

          # Expose CRD builders (the old partsOverlays pattern)
          partsOverlays = [
            (
              scope: self: base:
              let
                smRef = scope.mkCRDRef {
                  group = "monitoring.coreos.com";
                  kind = "ServiceMonitor";
                  plural = "servicemonitors";
                };
                pmRef = scope.mkCRDRef {
                  group = "monitoring.coreos.com";
                  kind = "PodMonitor";
                  plural = "podmonitors";
                };
                prRef = scope.mkCRDRef {
                  group = "monitoring.coreos.com";
                  kind = "PrometheusRule";
                  plural = "prometheusrules";
                };
              in
              {
                root = base.root // {
                  out = (base.root.out or { }) // {
                    mkServiceMonitor = smRef.out.mkCR;
                    mkPodMonitor = pmRef.out.mkCR;
                    mkPrometheusRule = prRef.out.mkCR;
                  };
                };
              }
            )
          ];

          package = packages.kube-prometheus-stack;
        };
      };
    }
  ];
}

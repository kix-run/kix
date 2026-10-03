# OpenShift flavor.
#
# Significant security posture: SCC (Security Context Constraints) enforce
# restricted-v2 by default, so containers run as random non-root UIDs.
# Images that hardcode USER root will fail without explicit SCC grants.
#
# Uses OVN-Kubernetes CNI (environment-owned, exclusive), HAProxy-based
# Router (not Ingress) for external access, and cri-o (not containerd) as
# container runtime.
#
# On cloud providers: LoadBalancer and persistent storage work via cloud
# CSI. Override the role bindings for cloud installs. On bare metal
# (this preset's default): both roles vacant.
#
# Platform imports: DNS (coredns, managed by OpenShift).

{
  config,
  lib,
  kix,
  ...
}:
{
  cluster.provider = lib.mkDefault "openshift";

  cluster.roles = {
    cni = {
      binding = lib.mkDefault "exclusive";
      provider = lib.mkDefault "ovn-kubernetes";
    };
    dns.binding = lib.mkDefault "shadowable";
    storageClasses.binding = lib.mkDefault "absent"; # cloud installs override
    loadBalancer.binding = lib.mkDefault "absent"; # cloud installs override
    # The cluster monitoring stack in openshift-monitoring serves metrics.k8s.io.
    metricsApi = {
      binding = lib.mkDefault "exclusive";
      provider = lib.mkDefault "openshift-monitoring";
    };
  };

  cluster.capabilities = {
    managedControlPlane = lib.mkDefault false;
    nodeAutoscaling = lib.mkDefault false;
    daemonSets = lib.mkDefault true;

    # OpenShift's defining characteristic: restricted security by default
    privilegedContainers = lib.mkDefault false;
    podSecurityEnforcement = lib.mkDefault "restricted"; # SCC restricted-v2
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
          fqdn = "dns-default.openshift-dns.svc.${config.clusterDomain}";
        };
      };
      optional = true;
    };
  };
}

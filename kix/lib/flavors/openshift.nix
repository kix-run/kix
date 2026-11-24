# OpenShift flavor.
#
# OpenShift enforces the `restricted-v2` Security Context Constraint (SCC) by
# default, running containers with arbitrary non-root UIDs. It ships
# OVN-Kubernetes CNI (exclusive), CoreDNS, and `openshift-monitoring` for
# `metrics.k8s.io`. Storage and LoadBalancer roles default to `absent` for
# bare-metal installs and can be overridden on cloud installs.

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
in
{
  cluster.provider = lib.mkDefault "openshift";

  cluster.roles = {
    cni = {
      binding = lib.mkDefault "exclusive";
      provider = lib.mkDefault "ovn-kubernetes";
    };
    dns.binding = lib.mkDefault "shadowable";
    storageClasses.binding = lib.mkDefault "absent"; # override on cloud installs
    loadBalancer.binding = lib.mkDefault "absent"; # override on cloud installs
    metricsApi = {
      binding = lib.mkDefault "exclusive";
      provider = lib.mkDefault "openshift-monitoring";
    };
  };

  cluster.capabilities = {
    managedControlPlane = lib.mkDefault false;
    nodeAutoscaling = lib.mkDefault false;
    daemonSets = lib.mkDefault true;
    privilegedContainers = lib.mkDefault false;
    podSecurityEnforcement = lib.mkDefault "restricted"; # SCC restricted-v2
  };

  instances.kube-system = {
    platform-dns = platformDns {
      name = "dns-default";
      namespace = "openshift-dns";
    };
  };
}

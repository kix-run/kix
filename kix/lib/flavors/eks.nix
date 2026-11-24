# Amazon EKS flavor.
#
# EKS provides a managed control plane, `aws-vpc-cni` (exclusive), CoreDNS,
# and cloud load balancing via the in-tree controller or the AWS Load Balancer
# Controller add-on (shadowable).
#
# EKS does not create a usable default StorageClass out of the box (the EBS CSI
# driver is a separate add-on), so `storageClasses` is `absent` and clusters
# declare their own storage class or import.

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
  cluster.provider = lib.mkDefault "eks";

  cluster.roles = {
    cni = {
      binding = lib.mkDefault "exclusive";
      provider = lib.mkDefault "aws-vpc-cni";
    };
    dns.binding = lib.mkDefault "shadowable";
    storageClasses.binding = lib.mkDefault "absent";
    # EKS does not install metrics-server by default.
    metricsApi.binding = lib.mkDefault "absent";
    loadBalancer = {
      binding = lib.mkDefault "shadowable";
      provider = lib.mkDefault "aws-cloud-provider";
    };
  };

  # Amazon Linux 2023 nodes enable `discard_unpacked_layers` by default.
  # Override this to false when a `nodeadm` config disables it.
  cluster.containerd.discardUnpackedLayers = lib.mkDefault true;

  cluster.capabilities = {
    managedControlPlane = lib.mkDefault true;
    nodeAutoscaling = lib.mkDefault false; # requires Karpenter or cluster-autoscaler
    privilegedContainers = lib.mkDefault true;
    daemonSets = lib.mkDefault true;
  };

  instances.kube-system = {
    platform-dns = platformDns {
      name = "kube-dns";
      namespace = "kube-system";
    };
  };
}

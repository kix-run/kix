# Flavor: EKS — Amazon Elastic Kubernetes Service.
#
# Managed control plane. aws-vpc-cni gives pods real VPC IPs.
# LoadBalancer works via in-tree cloud provider (CLBs) or the
# AWS Load Balancer Controller addon (NLB/ALB).
# EBS CSI driver addon provides persistent storage.
# No ingress controller — bring your own.

{ lib, ... }:
{
  cluster.provider = lib.mkDefault "eks";

  cluster.capabilities = {
    managedControlPlane = lib.mkDefault true;
    loadBalancer = lib.mkDefault true;
    cni = lib.mkDefault "aws-vpc-cni";
    networkPolicyAPI = lib.mkDefault "k8s"; # aws-vpc-cni supports k8s NetworkPolicy since 1.14+
    persistentStorage = lib.mkDefault true; # EBS CSI
    volumeSnapshots = lib.mkDefault false; # requires manual snapshot-controller install
    nodeAutoscaling = lib.mkDefault false; # Karpenter / cluster-autoscaler must be installed
  };
}

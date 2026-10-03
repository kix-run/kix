# Amazon EKS flavor.
#
# Managed control plane. aws-vpc-cni gives pods real VPC IPs, and the cni
# role is environment-owned (exclusive). LoadBalancer works via the in-tree
# cloud provider (CLBs) or the AWS Load Balancer Controller addon (NLB/ALB),
# so the role is shadowable. No ingress controller is included.
#
# Storage: EKS creates no StorageClass a cluster can rely on. The EBS CSI
# driver is an add-on (https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html),
# no gp3 class exists until somebody creates one, and EKS Auto Mode creates
# none. The storageClasses role is therefore vacant: a cluster declares its
# class as a managed instance or as its own import.
#
# Platform imports: DNS (coredns, managed by EKS).

{
  config,
  lib,
  kix,
  ...
}:
{
  cluster.provider = lib.mkDefault "eks";

  cluster.roles = {
    cni = {
      binding = lib.mkDefault "exclusive";
      provider = lib.mkDefault "aws-vpc-cni";
    };
    dns.binding = lib.mkDefault "shadowable";
    storageClasses.binding = lib.mkDefault "absent";
    # EKS does not deploy metrics-server; it is an optional community add-on.
    metricsApi.binding = lib.mkDefault "absent";
    loadBalancer = {
      binding = lib.mkDefault "shadowable";
      provider = lib.mkDefault "aws-cloud-provider";
    };
  };

  cluster.capabilities = {
    managedControlPlane = lib.mkDefault true;
    nodeAutoscaling = lib.mkDefault false; # Karpenter / cluster-autoscaler must be installed
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
  };
}

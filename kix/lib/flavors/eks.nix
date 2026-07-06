# Flavor: EKS — Amazon Elastic Kubernetes Service.
#
# Managed control plane. aws-vpc-cni gives pods real VPC IPs — the cni
# role is environment-owned (exclusive). LoadBalancer works via the in-tree
# cloud provider (CLBs) or the AWS Load Balancer Controller addon (NLB/ALB),
# so the role is shadowable. EBS CSI driver addon provides persistent
# storage (RWO only — RWX needs EFS). No ingress controller — bring your own.
#
# Platform imports: DNS (coredns, managed by EKS), storage (gp3 via EBS CSI).

{ lib, kix, ... }:
{
  cluster.provider = lib.mkDefault "eks";

  cluster.roles = {
    cni = {
      binding = lib.mkDefault "exclusive";
      provider = lib.mkDefault "aws-vpc-cni";
    };
    dns.binding = lib.mkDefault "shadowable";
    storageClasses.binding = lib.mkDefault "shadowable";
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
          fqdn = "kube-dns.kube-system.svc.cluster.local";
        };
      };
      optional = true;
    };

    platform-storage = {
      package = kix.mkImport {
        roles = [ "storageClasses" ];
        out = {
          storageClassName = "gp3";
        };
      };
      optional = true;
    };
  };
}

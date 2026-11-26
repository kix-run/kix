# Amazon EKS flavor.
#
# EKS provides a managed control plane, `aws-vpc-cni` (exclusive), CoreDNS,
# and cloud load balancing (shadowable). The EKS-run service controller builds
# a classic load balancer for a `LoadBalancer` Service. The AWS Load Balancer
# Controller is not an EKS add-on (only EKS Auto Mode includes it), so a
# cluster that wants it installs it with Helm.
#
# EKS creates a `gp2` StorageClass (`kubernetes.io/aws-ebs`,
# `WaitForFirstConsumer`) but marks no class as the default, and it has no
# `gp3` class. With the EBS CSI driver add-on installed, a claim on `gp2`
# binds. `storageClasses` is `absent`, so clusters create their own class, or
# import `gp2` and name it in the claim.
#
# The platform also has an `efs.csi.aws.com` CSIDriver object without an EFS
# driver, and an APIService `v1.metrics.eks.amazonaws.com` that is not
# `metrics.k8s.io`. Neither shows that EFS or the metrics API is available.
#
# EKS gives pods AWS identities through IAM roles for service accounts (IRSA)
# by default, or through EKS Pod Identity when
# `cluster.flavor.eks.cloudIdentity = "pod-identity"`. The pod identity
# webhook reads `eks.amazonaws.com` annotations either way.

{
  config,
  lib,
  kix,
  ...
}:
let
  platformDns = import ./platform-dns.nix {
    inherit lib kix;
    inherit (config) clusterDomain;
  };
  platformCloudIdentity = import ./cloud-identity.nix { inherit kix; };
  cloudIdentityMechanisms = import ../vocab/cloud-identity-mechanisms.nix { inherit lib; };
  mechanisms = {
    irsa = cloudIdentityMechanisms.irsa { };
    pod-identity = cloudIdentityMechanisms.eksPodIdentity { };
  };
in
{
  options.cluster.flavor.eks.cloudIdentity = lib.mkOption {
    type = lib.types.enum (builtins.attrNames mechanisms);
    default = "irsa";
    description = ''
      How pods on this EKS cluster assume AWS IAM roles from
      `kix.cloudIdentity.aws { roleArn = "..."; }`. `"irsa"` (IAM roles for
      service accounts) writes `eks.amazonaws.com/role-arn` on the
      ServiceAccount. `"pod-identity"` (EKS Pod Identity) omits that
      annotation; install the EKS Pod Identity Agent add-on and create an EKS
      Pod Identity association in AWS to link the ServiceAccount to the role.
      Both modes add `checksum/cloud-identity` to pod templates so changing the
      role restarts pods.
    '';
  };

  config = {
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

      cloud-identity = platformCloudIdentity {
        mechanism = mechanisms.${config.cluster.flavor.eks.cloudIdentity};
        annotationDomains = [ "eks.amazonaws.com" ];
      };
    };
  };
}

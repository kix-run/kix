# Amazon EKS flavor.
#
# EKS provides a managed control plane, `aws-vpc-cni` (exclusive), CoreDNS,
# and cloud load balancing via the in-tree controller or the AWS Load Balancer
# Controller add-on (shadowable).
#
# EKS does not create a usable default StorageClass out of the box (the EBS CSI
# driver is a separate add-on), so `storageClasses` is `absent` and clusters
# declare their own storage class or import.
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
      ServiceAccount. An EKS Pod Identity association on the same
      ServiceAccount overrides IRSA. `"pod-identity"` (EKS Pod Identity) omits
      that annotation; install the EKS Pod Identity Agent add-on and create an
      EKS Pod Identity association in AWS linking the ServiceAccount to
      `roleArn`. Kix cannot create or inspect AWS associations, so pods receive
      whichever role the association specifies. Run `kix list resources` to see
      each ServiceAccount and its `roleArn`. Both modes add
      `checksum/cloud-identity` to pod templates so changing `roleArn` restarts
      pods, and `kix deploy` verifies that new pods receive the expected AWS
      identity environment variables.
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

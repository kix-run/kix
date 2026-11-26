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
#
# The VPC CNI enforces the standard Kubernetes NetworkPolicy only after
# network policy is turned on in the add-on's configuration, which Kix cannot
# read. `cluster.flavor.eks.networkPolicy = "vpc-cni"` says it is on, and
# declares the `platform-network-policy` import that writes NetworkPolicy
# objects.

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
  platformNetworkPolicy = import ./platform-network-policy.nix {
    inherit lib kix;
    inherit (config.cluster) network;
  };
  inherit (import ../core/error.nix { inherit lib; }) fail;
  vpcCni = config.cluster.flavor.eks.networkPolicy == "vpc-cni";
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

  options.cluster.flavor.eks.networkPolicy = lib.mkOption {
    type = lib.types.enum [
      "none"
      "vpc-cni"
    ];
    default = "none";
    description = ''
      Whether network policy enforcement is enabled on this EKS cluster. Set
      `"vpc-cni"` after enabling network policy in the Amazon VPC CNI add-on
      (`enableNetworkPolicy` in the add-on configuration); Kix then emits
      standard `NetworkPolicy` objects when `networkPolicy.enable = true`.
      The default `"none"` matches a new EKS cluster where enforcement is off,
      and fails the build if `networkPolicy.enable = true`. Kix cannot inspect
      live add-on settings, so update this option whenever you change the
      add-on configuration.
    '';
  };

  config = {
    cluster.provider = lib.mkDefault "eks";
    # The cloud runs and upgrades the pods in kube-system, so Kix writes no
    # default deny there.
    networkPolicy.platformNamespaces = lib.mkDefault [ "kube-system" ];

    cluster.roles = {
      cni = {
        binding = lib.mkDefault "exclusive";
        provider = lib.mkDefault "aws-vpc-cni";
      };
      dns.binding = lib.mkDefault "shadowable";
      network-policy-enforcer = lib.mkIf vpcCni {
        binding = lib.mkDefault "exclusive";
        provider = lib.mkDefault "Amazon VPC CNI";
      };
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

      # How the VPC CNI matches an ipBlock, each tested on a live EKS
      # cluster: against pod and node addresses, and for an egress peer,
      # against the Service address and Service port before translation. In
      # its default `standard` mode, a new pod runs for about a second
      # before its policy applies.
      platform-network-policy = lib.mkIf vpcCni (platformNetworkPolicy {
        provider = "Amazon VPC CNI";
        ipBlockSelectsPods = true;
        ipBlockSelectsNodes = true;
        ipBlockSeesServiceAddress = true;
        podStartsBeforePolicy = true;
      });
    };

    hooks.clusterProcessors.eks-network-policy = _: {
      checks = [
        (
          if (config.networkPolicy.enable or false) && !vpcCni then
            fail {
              clusterOption = "cluster.flavor.eks.networkPolicy";
              message = "Network policy generation is enabled (`networkPolicy.enable = true`), but `cluster.flavor.eks.networkPolicy` is `\"none\"`. By default, Amazon EKS does not enforce `NetworkPolicy` objects, so Kix stopped the build to avoid generating policies that have no effect.";
              fix = "Enable network policy in the Amazon VPC CNI add-on (set `enableNetworkPolicy` to \"true\" in the add-on configuration) and set `cluster.flavor.eks.networkPolicy = \"vpc-cni\";`, or set `networkPolicy.enable = false;`.";
            }
          else
            null
        )
      ];
    };
  };
}

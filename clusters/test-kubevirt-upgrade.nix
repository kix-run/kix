# clusters/test-kubevirt-upgrade.nix: KubeVirt under Cilium default-deny on a
# one-node kind cluster, for testing a KubeVirt version change.
#
# A `vms` package builds VirtualMachine `halted`, with runStrategy Halted and
# no disks. It needs neither /dev/kvm nor CDI, so the cluster runs on any
# host. The upgrade test deploys the old package, deploys the new one over
# it, and checks that the KubeVirt resource reaches phase Deployed at the new
# version, that every operand pod runs the new images, and that `halted`
# survives and stays Stopped. No virtual machine boots here. That needs
# clusters/test-virtualization.nix and a host with /dev/kvm.
#
# Bring up: kind create cluster --name <name> --kubeconfig <file> --config <config>
#           where the config sets networking.disableDefaultCNI = true
# Deploy:   kix deploy kubevirt-upgrade --context kind-<name> -y

{ kix, packages }:

let
  vmsPackage =
    { scope, ... }:
    {
      meta = {
        description = "A stopped VirtualMachine that a KubeVirt upgrade must keep";
        owner = "platform";
      };
      build =
        { self, kubevirt, ... }:
        {
          halted = kubevirt.out.mkVirtualMachine scope {
            name = "halted";
            spec = {
              runStrategy = "Halted";
              template.spec.domain = {
                devices = { };
                resources.requests.memory = "64Mi";
              };
            };
          };
          root.resource = self.halted;
        };
    };
in
kix.buildCluster {
  name = "kubevirt-upgrade";
  modules = [
    kix.flavors.kind

    {
      cluster.availability.default = "none";
      # kind runs with disableDefaultCNI, so the managed cilium instance
      # fills the vacant CNI role.
      cluster.roles.cni = {
        binding = "absent";
        provider = null;
      };
      networkPolicy.enable = true;

      namespaces = {
        kubevirt = { };
        vms = { };
      };

      instances = {
        kube-system.cilium.package = packages.experimental.cilium;
        kubevirt.kubevirt.package = packages.experimental.kubevirt;
        vms.vms.package = vmsPackage;
      };
    }
  ];
}

# clusters/test-kubevirt-upgrade.nix: KubeVirt alone on a one-node kind
# cluster under Cilium default-deny, for testing a KubeVirt version change.
#
# A `vm-demo` package builds two virtual machines: `demo`, running from a
# container disk, and `halted`, with runStrategy Halted and no disks. A
# deploy of a new KubeVirt version upgrades the operands under both, and
# the deploy finishes once `demo` is Running and `halted` is Stopped.
#
# Virtual machines run under emulation, so the cluster works on a host
# without /dev/kvm. clusters/test-virtualization.nix covers KubeVirt with
# CDI, three nodes, and KVM.
#
# Bring up: kind create cluster --name <name> --kubeconfig <file> --config <config>
#           where the config sets networking.disableDefaultCNI = true
# Deploy:   kix deploy kubevirt-upgrade --context kind-<name> -y
{ kix, packages }:

let
  vmDemoPackage =
    { scope, lib, ... }:
    {
      meta = {
        description = "Virtual machines for the KubeVirt upgrade kind run";
        owner = "platform";
      };
      build =
        { self, kubevirt, ... }:
        {
          demo = kubevirt.out.mkVirtualMachine scope {
            name = "demo";
            spec = {
              runStrategy = "Always";
              template.spec = {
                domain = {
                  # The VM needs no network. KubeVirt's default bridge
                  # binding finds no gateway route on a pod under Cilium.
                  devices.autoattachPodInterface = false;
                  # QEMU without KVM refuses the default host-passthrough
                  # CPU on arm64.
                  cpu.model = "max";
                  devices.disks = [
                    {
                      name = "disk";
                      disk.bus = "virtio";
                    }
                  ];
                  resources.requests.memory = "128Mi";
                };
                volumes = [
                  {
                    name = "disk";
                    # The v1.9.1 demo image, by digest.
                    containerDisk.image = "quay.io/kubevirt/cirros-container-disk-demo@sha256:ebdb8d8b9b480f6ee7664ed3fdde8428767664f507d98f94090edeff04d7ebf2";
                  }
                ];
              };
            };
          };

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

          root = {
            resource = self.demo;
            requires = [ self.halted ];
          };
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
        vm-demo = { };
      };
      instances = {
        kube-system.cilium.package = packages.experimental.cilium;
        kubevirt.kubevirt = {
          package = packages.experimental.kubevirt;
          # kind nodes here have no /dev/kvm.
          config.extraSpec.configuration.developerConfiguration.useEmulation = true;
        };
        vm-demo.vm-demo.package = vmDemoPackage;
      };
    }
  ];
}

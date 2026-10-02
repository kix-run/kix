# clusters/test-virtualization.nix: KubeVirt and CDI end to end on a
# three-node kind cluster, under Cilium default-deny.
#
# A `vm-demo` package takes both as dependencies and builds:
#   - VirtualMachine `demo`, running, whose disk is a DataVolume template
#     that imports a registry image through an importer pod;
#   - a blank DataVolume `scratch`, built with cdi.out.mkDataVolume, which
#     completes on kind's WaitForFirstConsumer class without a consumer;
#   - VirtualMachine `halted`, with runStrategy Halted and no disks;
#   - the importer pods' policy from cdi.out.mkImporterPolicy.
# The deploy finishes once `demo` is Running, `scratch` is Succeeded, and
# `halted` is Stopped.
#
# kind nodes pass /dev/kvm through from the host, so the VMs run without
# emulation. On a host without it, set
# `extraSpec.configuration.developerConfiguration.useEmulation = true` on the
# kubevirt instance.
#
# Build:  nix build .#cluster-virtualization --extra-experimental-features pipe-operators
# Deploy: scripts/kind-virtualization.sh

{ kix, packages }:

let
  vmDemoPackage =
    { scope, lib, ... }:
    {
      meta = {
        description = "Virtual machines and DataVolumes for the virtualization kind run";
        owner = "platform";
      };
      build =
        {
          self,
          kubevirt,
          cdi,
          ...
        }:
        {
          demo = kubevirt.out.mkVirtualMachine scope {
            name = "demo";
            spec = {
              runStrategy = "Always";
              dataVolumeTemplates = [
                {
                  metadata.name = "demo-disk";
                  spec = {
                    source.registry = {
                      url = "docker://quay.io/kubevirt/cirros-container-disk-demo:v1.5.0@sha256:b3173a795eddc0c8f6923bb197928b7c0876aade4daf85d0558dfae65f403fe2";
                      pullMethod = "pod";
                    };
                    storage.resources.requests.storage = "1Gi";
                  };
                }
              ];
              template.spec = {
                domain = {
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
                    dataVolume.name = "demo-disk";
                  }
                ];
              };
            };
          };

          scratch = cdi.out.mkDataVolume scope {
            name = "scratch";
            spec = {
              source.blank = { };
              storage.resources.requests.storage = "64Mi";
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

          # The importer pulls the demo image from quay.io and its CDN.
          importer = cdi.out.mkImporterPolicy scope {
            egress = [
              {
                to = "world";
                ports = [
                  {
                    port = 443;
                    protocol = "TCP";
                  }
                ];
              }
            ];
          };

          root = {
            resource = self.demo;
            requires = [
              self.scratch
              self.halted
            ]
            ++ lib.optional (self.importer != null) self.importer;
          };
        };
    };
in
kix.buildCluster {
  name = "virtualization";
  modules = [
    kix.flavors.kind

    {
      cluster.capabilities.multiNode = true;
      # kind runs with the default CNI disabled (scripts/kind-virtualization.sh);
      # the managed cilium instance fills the vacant role.
      cluster.roles.cni = {
        binding = "absent";
        provider = null;
      };
      networkPolicy.enable = true;

      namespaces = {
        kubevirt = { };
        cdi = { };
        vm-demo = { };
      };

      instances = {
        kube-system.cilium = {
          package = packages.cilium;
          config.values = {
            kubeProxyReplacement = false;
            prometheus.enabled = false;
            ipam.operator.clusterPoolIPv4PodCIDRList = [ "10.244.0.0/16" ];
          };
        };
        kubevirt.kubevirt = {
          package = packages.kubevirt;
          availability = "node";
        };
        cdi.cdi.package = packages.cdi;
        vm-demo.vm-demo.package = vmDemoPackage;
      };
    }
  ];
}

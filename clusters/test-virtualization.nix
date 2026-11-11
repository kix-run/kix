# clusters/test-virtualization.nix: KubeVirt and CDI end to end on a
# three-node kind cluster, under Cilium default-deny.
#
# A `vm-demo` package takes both as dependencies and builds:
#   - VirtualMachine `demo`, running, whose disk is a DataVolume template
#     that imports a registry image through an importer pod;
#   - a blank DataVolume `scratch`, built with cdi.out.mkDataVolume, which
#     completes on kind's WaitForFirstConsumer class without a consumer;
#   - VirtualMachine `halted`, with runStrategy Halted and no disks;
#   - the importer pods' policy from cdi.out.mkImporterPolicy, and the
#     cloner pods' policy from cdi.out.mkClonerPolicy.
# A `vm-clone` package in its own namespace clones `scratch` into DataVolume
# `scratch-copy`. kind's local-path provisioner cannot clone, so CDI copies
# the data through a cloner pod in vm-demo and an upload server pod in
# vm-clone, which cdi.out.mkUploadServerPolicy admits.
# The deploy finishes once `demo` is Running, `scratch` and `scratch-copy`
# are Succeeded, and `halted` is Stopped.
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
                      # The importer refuses a reference with both a tag and a digest,
                      # so the image is named by digest alone (the v1.5.0 tag).
                      url = "docker://quay.io/kubevirt/cirros-container-disk-demo@sha256:b3173a795eddc0c8f6923bb197928b7c0876aade4daf85d0558dfae65f403fe2";
                      pullMethod = "pod";
                    };
                    storage = {
                      # CDI has no StorageProfile defaults for kind's
                      # rancher.io/local-path provisioner.
                      accessModes = [ "ReadWriteOnce" ];
                      resources.requests.storage = "1Gi";
                    };
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
              storage = {
                accessModes = [ "ReadWriteOnce" ];
                resources.requests.storage = "64Mi";
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

          cloner = cdi.out.mkClonerPolicy scope { targetNamespaces = [ "vm-clone" ]; };

          root = {
            resource = self.demo;
            requires = [
              self.scratch
              self.halted
            ]
            ++ builtins.filter (p: p != null) [
              self.importer
              self.cloner
            ];
            out.scratch = {
              name = self.scratch.out.name;
              namespace = scope.namespaceName;
            };
          };
        };
    };

  vmClonePackage =
    { scope, lib, ... }:
    {
      meta = {
        description = "A DataVolume cloned from another namespace for the virtualization kind run";
        owner = "platform";
      };
      build =
        {
          self,
          cdi,
          source,
          ...
        }:
        {
          copy = cdi.out.mkDataVolume scope {
            name = "scratch-copy";
            spec = {
              source.pvc = source.out.scratch;
              storage = {
                accessModes = [ "ReadWriteOnce" ];
                resources.requests.storage = "64Mi";
              };
            };
          };

          uploadServer = cdi.out.mkUploadServerPolicy scope {
            cloneSourceNamespaces = [ source.out.scratch.namespace ];
          };

          root = {
            resource = self.copy;
            requires = lib.optional (self.uploadServer != null) self.uploadServer;
          };
        };
    };
in
kix.buildCluster {
  name = "virtualization";
  modules = [
    kix.flavors.kind

    (
      { ref, ... }:
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
          vm-clone = { };
        };

        instances = {
          kube-system.cilium.package = packages.experimental.cilium;
          kubevirt.kubevirt = {
            package = packages.experimental.kubevirt;
            availability = "node";
          };
          cdi.cdi.package = packages.experimental.cdi;
          vm-demo.vm-demo.package = vmDemoPackage;
          vm-clone.vm-clone = {
            package = vmClonePackage;
            deps.source = ref.vm-demo.vm-demo;
          };
        };
      }
    )
  ];
}

# Tests for the spegel package and the registryMirror role: the refusals
# of nodes that cannot serve (one node, containerd discarding unpacked
# layers), the exclusive binding of flavours that embed Spegel, one
# instance per cluster, the owned registry flags, and the containerd paths
# taken from the cluster definition.

{
  lib,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  ...
}:

let
  spegelPackage = import ../../../packages/spegel;
  kindFlavor = import ../../flavors/kind.nix;
  k3sFlavor = import ../../flavors/k3s.nix;
  rke2Flavor = import ../../flavors/rke2.nix;
  talosFlavor = import ../../flavors/talos.nix;

  # Nodes Spegel can serve on, as a cluster that turned off the discard
  # declares them.
  servable = {
    cluster.capabilities.multiNode = true;
    cluster.containerd.discardUnpackedLayers = false;
  };

  cluster =
    {
      flavor ? kindFlavor,
      module ? servable,
      instances ? {
        spegel.spegel.package = spegelPackage;
      },
    }:
    mkCluster [
      flavor
      { inherit instances; }
      module
    ];

  withArgs = extraArgs: {
    spegel.spegel = {
      package = spegelPackage;
      config = { inherit extraArgs; };
    };
  };

  builds = c: !(evalFails c);

  check =
    label: cases:
    let
      wrong = lib.attrNames (lib.filterAttrs (_: c: builds c.cluster != c.builds) cases);
    in
    wrong == [ ] || throw "${label}: these cases did not behave: ${toString wrong}";
in
{
  # kind's defaults (one node, discard on) are refused; each fact alone is
  # refused; both set right builds, and both unknown builds with warnings.
  spegel-node-prerequisites = check "spegel node prerequisites" {
    kind-defaults = {
      cluster = cluster { module = { }; };
      builds = false;
    };
    discarding = {
      cluster = cluster {
        module = servable // {
          cluster.containerd.discardUnpackedLayers = true;
        };
      };
      builds = false;
    };
    single-node = {
      cluster = cluster {
        module = servable // {
          cluster.capabilities.multiNode = false;
        };
      };
      builds = false;
    };
    servable = {
      cluster = cluster { };
      builds = true;
    };
    unknown = {
      cluster = cluster {
        module = {
          cluster.capabilities.multiNode = lib.mkForce null;
          cluster.containerd.discardUnpackedLayers = lib.mkForce null;
        };
      };
      builds = true;
    };
  };

  # k3s and RKE2 embed Spegel and bind registryMirror exclusive; with the
  # binding absent the same instance builds.
  spegel-embedded-refuses-managed = check "spegel under an exclusive binding" {
    k3s = {
      cluster = cluster { flavor = k3sFlavor; };
      builds = false;
    };
    k3s-absent = {
      cluster = cluster {
        flavor = k3sFlavor;
        module = servable // {
          cluster.roles.registryMirror.binding = lib.mkForce "absent";
        };
      };
      builds = true;
    };
    rke2 = {
      cluster = cluster { flavor = rke2Flavor; };
      builds = false;
    };
    rke2-absent = {
      cluster = cluster {
        flavor = rke2Flavor;
        module = servable // {
          cluster.roles.registryMirror.binding = lib.mkForce "absent";
        };
      };
      builds = true;
    };
  };

  # The role admits one instance per cluster.
  spegel-second-instance = check "two spegel instances" {
    one = {
      cluster = cluster { };
      builds = true;
    };
    two = {
      cluster = cluster {
        instances = {
          spegel.spegel.package = spegelPackage;
          other.spegel.package = spegelPackage;
        };
      };
      builds = false;
    };
  };

  # extraArgs may not move the ports or the containerd paths; other flags
  # pass through.
  spegel-owned-flags = check "spegel extraArgs" {
    registry-addr = {
      cluster = cluster { instances = withArgs [ "--registry-addr=:6000" ]; };
      builds = false;
    };
    containerd-sock = {
      cluster = cluster {
        instances = withArgs [ "--containerd-sock=/run/k3s/containerd/containerd.sock" ];
      };
      builds = false;
    };
    mirrored-registries = {
      cluster = cluster {
        instances = withArgs [
          "--mirrored-registries"
          "https://docker.io"
        ];
      };
      builds = false;
    };
    registry-filters = {
      cluster = cluster { instances = withArgs [ "--registry-filters=:latest$" ]; };
      builds = true;
    };
  };

  # The init container writes to, and the pod mounts, the flavour's
  # registry config directory (Talos keeps it under /etc/cri/conf.d/hosts).
  spegel-containerd-paths-from-cluster =
    let
      ds = byName "spegel" (
        ofKind "DaemonSet" (
          manifests (cluster {
            flavor = talosFlavor;
          })
        )
      );
      spec = ds.spec.template.spec;
      init = builtins.head spec.initContainers;
      volume = lib.findFirst (v: v.name == "containerd-config") null spec.volumes;
    in
    (
      builtins.elem "--containerd-registry-config-path=/etc/cri/conf.d/hosts" init.args
      && volume.hostPath.path == "/etc/cri/conf.d/hosts"
    )
    || throw "spegel on Talos did not use /etc/cri/conf.d/hosts: ${builtins.toJSON init.args}";
}

# Storage DI

Persistent storage uses first-class PVC instances wired through dependency injection.

## The dependency chain

`app -> PVC -> StorageClass`

```nix
# Cluster definition:
instances = {
  kube-system = {
    storage-classes = {
      package = packages.storage-classes;   # claims the storageClasses role; the role name is the alias
      config.classes.local-path = {
        provisioner = "rancher.io/local-path";
        volumeBindingMode = "WaitForFirstConsumer";
      };
    };
  };
  my-app = {
    storage = {
      package = packages."persistent-volume-claim";
      config = {
        size = "500Gi";
        accessModes = [ "ReadWriteOnce" ];
      };
    };
    app = {
      package = packages.my-app;
      # storage resolves via DI to the PVC instance above
    };
  };
};
```

`size` is required on a PVC instance; other spec fields go in `config.extraSpec`. With two or more classes and none annotated default, a claim that names no class fails the build, so set its `config.storageClassName`.

## Consuming package

```nix
{ scope, lib, kix }:
# ...
build = { self, config, scope, storage, ... }: {  # storage is a hard dep (build arg)
  dataMount = kix.mount.pvc storage { mountPath = "/data"; };

  deployment =
    { name = "my-app"; spec = { ... }; }
    |> kix.withMounts [ self.dataMount ]
    |> scope.mkDeployment;
};
```

`kix.mount.pvc` + `kix.withMounts` is preferred over manual volume/volumeMount wiring. It auto-derives the volume name, handles null resources, and keeps mount logic separate from the deployment spec.

**Manual approach (for complex cases):**

```nix
volumes = [{ name = "data"; persistentVolumeClaim.claimName = storage.out.name; }];
containers = [{ volumeMounts = [{ name = "data"; mountPath = "/data"; }]; }];
```

## Why PVCs are top-level instances

- The cluster operator configures storage (size, class, backup) at the cluster level.
- PVCs outlive apps: removing or upgrading the app doesn't touch storage.
- Cross-namespace safety: the claim package declares `meta.scope = "namespace"`, so resolution never binds a claim in another namespace, and an explicit `deps.storage = ref.<ns>.<claim>` across namespaces fails the build.
- Visible in the cluster definition, so there is no hidden state.

## CSI driver packages

A driver package (`zfs-localpv`) renders its StorageClasses with
`kix.types.storageClass` and `kix.storage.mkClasses` and publishes the
class consumers get through `out.storageClassName`. It does not claim
the `storageClasses` role: that role is the cluster's default provider,
and a driver that is present is not always the default. A consumer wires
the driver with `deps.storageClasses = ref.<namespace>.<instance>`; a
cluster that wants the driver as everyone's default sets the instance's
`aliases = [ "storageClasses" "zfsLocalPv" ]`, keeping the package's own
alias so its one-instance check still applies. A driver's
VolumeSnapshotClasses are an option of `kix.types.volumeSnapshotClass`
values, built with `kix.storage.mkSnapshotClasses` from an optional
`snapshotController ? null` dependency. Its assertions include
`kix.storage.snapshotClassProblems`, which refuses classes when nothing
provides the role, more than one default class, and the keys `root` and
`meta`, which Kix does not render as parts. Node plugin tolerations are
`kix.types.toleration` values, checked with `kix.tolerations.problems`
and rendered with `kix.tolerations.render`.

`mayastor` follows the same shape and adds etcd: the etcd class comes
from `deps.storageClasses` or `etcd.storage.storageClassName`, never from
one of Mayastor's own classes. An instance aliased `storageClasses` must
wire `deps.storageClasses` explicitly, or the dependency resolves to
itself.

# Storage DI

Persistent storage uses first-class PVC instances, not config-based `existingClaim` strings.

## The dependency chain

`app -> PVC -> StorageClass`

```nix
# Cluster definition:
instances = {
  kube-system = {
    storage-classes = {
      package = packages.storage-classes;
      aliases = [ "storageClasses" ];
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

## Consuming package

```nix
{ scope, lib, kix }:
# ...
build = { self, config, clusterConfig, storage }: {  # storage is a hard dep (build arg)
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

## Why PVCs are instances, not internal resources

- The cluster operator owns storage (size, class, backup) — not the app
- PVCs outlive apps — removing/upgrading the app doesn't touch storage
- Cross-namespace safety: `meta.scope = "namespace"` prevents mounting PVCs across namespaces (build-time error)
- Visible in the cluster definition — no hidden state

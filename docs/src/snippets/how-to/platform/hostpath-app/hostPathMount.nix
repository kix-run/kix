      cacheMount = kix.mount.hostPath {
        name = "cache";
        hostPath = "/var/lib/example-cache";
        mountPath = "/var/cache/app";
        type = "DirectoryOrCreate";
      };
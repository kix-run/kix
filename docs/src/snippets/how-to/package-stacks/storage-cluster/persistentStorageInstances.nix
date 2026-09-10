      instances.storage-example.storage = {
        package = packages."persistent-volume-claim";
        config = {
          size = "5Gi";
          accessModes = [ "ReadWriteOnce" ];
        };
      };

      instances.storage-example.worker = {
        package = storageApp;
      };
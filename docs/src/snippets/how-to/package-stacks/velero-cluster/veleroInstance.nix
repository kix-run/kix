      instances.velero-system.velero = {
        package = packages.velero;
        config = {
          credentials.secretName = "velero-credentials";

          backupStorageLocation = {
            provider = "velero.io/aws";
            bucket = "example-cluster-backups";
            config = {
              region = "eu-central-1";
              s3ForcePathStyle = "false";
            };
          };

          schedules.daily = {
            schedule = "0 2 * * *";
            template = {
              includedNamespaces = [ "applications" ];
              ttl = "720h0m0s";
              defaultVolumesToFsBackup = true;
            };
          };
        };
      };
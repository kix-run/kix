# clusters/test-eramba.nix — Eramba CE + MySQL, on a cluster whose platform
# services are managed elsewhere.
#
# Mirrors the shape of a real deployment onto an existing cluster: the
# ingress controller, cert-manager issuers and StorageClasses are all
# reconciled by other tooling, so they enter kix as `kix.mkImport` markers
# rather than managed instances. That keeps kix.expose working (it resolves
# `ingressNginx` / `clusterIssuer` via DI) without kix claiming ownership of
# anything it did not install.
#
# Build:  nix build .#cluster-eramba --extra-experimental-features pipe-operators

{ kix, packages }:

kix.buildCluster {
  name = "test-eramba";
  modules = [
    {
      availablePackages = packages;

      # Platform services owned outside kix. `optional = true` keeps them out
      # of the activation graph — they deploy nothing, they only carry the
      # `out` values consumers resolve through DI.
      instances.kube-system = {
        platform-storage = {
          package = kix.mkImport {
            out.storageClassName = "standard";
          };
          aliases = [ "storageClasses" ];
          optional = true;
        };

        platform-ingress = {
          package = kix.mkImport {
            out.ingressClassName = "nginx";
          };
          aliases = [ "ingressNginx" ];
          optional = true;
        };

        platform-cluster-issuer = {
          package = kix.mkImport {
            out.withCert =
              args:
              args
              // {
                annotations = (args.annotations or { }) // {
                  "cert-manager.io/cluster-issuer" = "letsencrypt-production";
                };
              };
          };
          aliases = [ "clusterIssuer" ];
          optional = true;
        };
      };

      instances.eramba = {
        eramba = {
          package = packages.eramba;
          config = {
            ingress.host = "grc.example.com";
            # Dev only — real deployments use securitySaltSource (SOPS).
            securitySalt = "dev-salt-not-for-production-use-sops";
          };
        };

        # Attachments + logs. Two PVCs in one namespace, so each claims a
        # distinct alias: persistent-volume-claim's default alias is
        # `storage`, and two instances answering to it would make phase-1
        # DI resolution ambiguous.
        eramba-data = {
          package = packages.persistent-volume-claim;
          aliases = [ "storage" ];
          config.size = "20Gi";
        };

        eramba-backups = {
          package = packages.persistent-volume-claim;
          aliases = [ "backupStorage" ];
          config.size = "20Gi";
        };

        eramba-mysql = {
          package = packages.mysql;
          config = {
            database = "eramba";
            user = "eramba";
            password = "eramba-dev-password";
            rootPassword = "eramba-dev-root-password";

            backup.enabled = true;

            # Upstream's mysql/conf.d/custom.cnf, verbatim minus the empty
            # [mysql] section and the [client] bind-address (meaningless for
            # a client). Not optional: without max_allowed_packet large
            # imports fail, and Eramba's schema is rejected under
            # innodb_strict_mode.
            myCnf = ''
              [mysqld]
              disable-log-bin
              max_allowed_packet=128M
              sql_mode=NO_ENGINE_SUBSTITUTION
              innodb_strict_mode=0
              innodb_lock_wait_timeout=200
              innodb_stats_on_metadata=OFF
              binlog_row_image=MINIMAL
              sync_binlog=1
              local_infile=OFF
              source_verify_checksum=ON
              relay_log_purge=1
              replica_sql_verify_checksum=1
              skip-name-resolve
              slow_query_log=1
              slow_query_log_file=/tmp/mysql-slow.log
              log_bin_trust_function_creators=OFF
              log_bin=OFF
              bind-address=0.0.0.0

              [mysqldump]
              quick
              quote-names
              max_allowed_packet=128M
            '';

            # Upstream grants this from a docker-entrypoint-initdb.d script.
            # Eramba's system-health check reads the server's process list.
            initSql = ''
              GRANT PROCESS ON *.* TO 'eramba'@'%';
            '';
          };
        };
      };
    }
  ];
}

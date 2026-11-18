# clusters/test-firezone.nix: Firezone VPN on a per-app StackGres database,
# under Cilium default-deny.
#
# The application database is a stackgres-database on a one-instance
# stackgres-cluster, which receives the pgcrypto, btree_gist, and citext
# extensions the package requests. Every credential is a test value; a real
# cluster gives each secret a SOPS `source` or a `secret-ref`.
#
# Build:  kix build test-firezone
# Deploy: kix deploy test-firezone --context <kind context> --timeout 20m
#         on a kind cluster created with `disableDefaultCNI: true`. The
#         first start runs the migrations.

{ kix, packages }:

kix.buildCluster {
  name = "test-firezone";
  modules = [
    kix.flavors.kind
    {
      availablePackages = packages;
      networkPolicy.enable = true;

      # kind runs with the default CNI disabled, so the managed cilium
      # instance fills the cni role.
      cluster.roles.cni = {
        binding = "absent";
        provider = null;
      };
      instances.kube-system.cilium.package = packages.experimental.cilium;

      instances.stackgres-system.stackgres-operator.package = packages.experimental.stackgres-operator;

      instances.vpn = {
        firezone = {
          package = packages.experimental.firezone;
          config = {
            domain = "vpn.example.com";
            admin.email = "admin@example.com";
          };
        };
        firezone-pg = {
          package = packages.experimental.stackgres-cluster;
          aliases = [ "postgres" ];
          # kind has one node and the pods anti-affine, so a second
          # instance never schedules.
          config.instances = 1;
        };
        firezone-db = {
          package = packages.experimental.stackgres-database;
        };
        firezone-db-password = {
          package = packages.secret;
          aliases = [ "password" ];
          # Dev-only value; it protects nothing.
          config = {
            source = ./dev-secrets/firezone-db.sops.yaml;
            keys = [ "password" ];
          };
        };
        firezone-secrets = {
          package = packages.secret;
          aliases = [ "applicationSecrets" ];
          config.stringData = {
            GUARDIAN_SECRET_KEY = "F7UV+h8tWfNUxvRi9kFGi9sl1Z0Nr54eT1LMLsMXQBusGBLShbOSwklpwqfzR95x";
            SECRET_KEY_BASE = "LO/lLsn+KMdpxKAxIxLTkZluLLsbDSo3E2t40wiUc4tB9q53fQyEJwGssJbVY8/nG5jK3g9qzb8C4LzkIhMHNg==";
            DATABASE_ENCRYPTION_KEY = "xLWlQWJORGLJu0EJtFTcMP7HZEDPuzwVSvyYk1ZsDio=";
            LIVE_VIEW_SIGNING_SALT = "+aJluUZfW2w7a+ZT5T7AgBQjUEMIgLCh";
            COOKIE_SIGNING_SALT = "Es+Z0agcHALnzhFbfD3lLV3T9UXw11wR";
            COOKIE_ENCRYPTION_SALT = "ZnivDUnTQ6CsdeFg5ihE0SFgVX6wA9A9";
          };
        };
        firezone-admin = {
          package = packages.secret;
          aliases = [ "adminPassword" ];
          config.stringData.password = "changeme";
        };
        firezone-wireguard = {
          package = packages.secret;
          aliases = [ "wireguardKey" ];
          # Test value only: a WireGuard private key generated for this
          # file and used nowhere else.
          config.stringData.private_key = "zB/31yt/rXjj6nzRCB+ApJfijeJAFrTqiVsEAftOPX8=";
        };
      };
    }
  ];
}

# clusters/test-harbor.nix — Harbor smoke test.
#
# Harbor with every dep wired: a StackGres postgres plus a per-app database,
# valkey, a registry PVC, ingress-nginx, a self-signed ClusterIssuer (TLS on
# the Ingress) and the prometheus operator (ServiceMonitors + PrometheusRule).
# Network policy and the full scorecard rule set are on so the package is
# held to the same bar ludo holds its packages to.
#
# Build:  nix build .#cluster-harbor --extra-experimental-features pipe-operators

{ kix, packages }:

kix.buildCluster {
  name = "test-harbor";
  specialArgs = { inherit packages kix; };
  modules = [
    kix.flavors.kind

    (
      {
        lib,
        kix,
        packages,
        ...
      }:
      {
        availablePackages = packages;
        cluster.domain = "harbor.test";
        networkPolicy.enable = true;
        # The full built-in rule set at its own severities, with no
        # override, is the default now, and clusters/flake.nix raises the
        # cap to error: a rule that disagrees with what the builders
        # produce fails this build. cilium's host network and privileged
        # mount are declared in its own meta.unsafe, not downgraded here.

        # kind runs with the default CNI disabled (see the deploy scripts
        # under demo/), so the managed cilium instance fills the cni role,
        # the same way the ludo kind variants do.
        cluster.roles.cni = {
          binding = "absent";
          provider = null;
        };
        instances.kube-system.cilium = {
          package = packages.cilium;
        };

        instances.ingress-system.ingress-nginx = {
          package = packages."ingress-nginx";
        };

        instances.cert-manager.cluster-issuers = {
          package = packages."cluster-issuers";
          config = {
            mainIssuer = "selfsigned";
            issuers = lib.mkForce {
              selfsigned = {
                kind = "selfSigned";
              };
            };
          };
        };

        instances.monitoring.prometheus-operator = {
          package = packages."prometheus-operator";
        };

        instances.stackgres-system.stackgres-operator = {
          package = packages."stackgres-operator";
        };

        instances.harbor = {
          harbor = {
            package = packages.harbor;
            # The smoke test reaches the Ingress through
            # `kubectl port-forward -n ingress-system svc/ingress-nginx 8443:443`,
            # and registry clients follow the token realm core hands them, so
            # the public URL has to carry that port.
            config.externalURL = "https://harbor.harbor.test:8443";
            # Dev-only values. The key and hash below were generated for this
            # fixture and protect nothing.
            config.secrets.values = {
              adminPassword = "Harbor12345";
              secretKey = "0123456789abcdef";
              coreSecret = "dev-core-secret";
              jobserviceSecret = "dev-jobservice-secret";
              csrfKey = "0123456789abcdef0123456789abcdef";
              registryHttpSecret = "dev-registry-http-secret";
              registryPassword = "dev-registry-password";
              # htpasswd -nbB harbor_registry_user dev-registry-password
              registryHtpasswd = "harbor_registry_user:\$2y\$05\$61w4.J6uFUkXoKBcFsDMwuLAC/ssV6YAkUO.cS1bTMY/xuU.sVzXq";
              tokenPrivateKey = ''
                -----BEGIN RSA PRIVATE KEY-----
                MIIEogIBAAKCAQEAvlnT71GdrFpAHsV+YUh13GO1NdI5mxR0dg/7oF/eCrMmGZht
                8X1oSah39VnfbU6DyxC3LaJbe9IfcnAGIRuPOaCCkUA9C94P2kWkAQFVVwHVhdsE
                +fk/YRjtrlYxvWs56AOo9UPk/iSVLQsss1DHr6gTXFjzBTka78VPzyxNPkEllbNT
                RyXMH0whz5ZY2m3pzYiefZqdzHykYk0TDD4GnhhvOD4V7NKb2+dIWIbV5soexyR3
                kcLh0aVK75mlAnB2CxZZSwBNTE3hpWNOhyWay132G4vUiFrskKUZ9x7YLbdaNHiC
                Ai7+M6B3ro0lUOcCdQpfj2czUHLgvFNeaNHjLwIDAQABAoIBAFrXK5lObdzOxULq
                JUHv/q9KtjQVO4CS5nFhd0g1+BVLIaedYvqYSqi8SWNBnKrhiWvjckfI77fLs049
                v+8U4+kwfJ8s9PUw6IfWLEp+hGedbHUQ7PMOy/xelS9Z2yr2fRAIjx1dZW8Trk1s
                w8xfhKyDnZm4qWGYuw4qL8hC8CoAwl8LbCykYqIQ2a+2Qqk7fKl2XC5SRpKz2Msd
                4oK1kHe2toBopMZa3AdFWMPdSO9iqqzIVOIhDZ6O7s3CNLvhzESfhH2SGLlwrUZ6
                TjS7WRt7VZ8YSvQUNJwR0eSs6katSrtM/+603SRIHtso9R0g5FkqaQx7OqtoaAFo
                WAwCZYECgYEA4O9sQa3SFXlYPyCAAvqgktyEkgnkShfYtg0VvNru4AiVVEco7tkm
                pER21j1yNCwz/v6MUM1loOdbVwq9iEoRmwpf1/AbkKvRAsCpwbqvfiyWhLXr9JtM
                apWCdKxid1a0D+3WiRa18wC1uwt+LrKMxOP8Z3prkc67SrPi967S4vECgYEA2KOt
                KSv34a6qe5QkXJ97TvpKGbTYocjJ8nd5S8a0ZFKYwvEW8ZYt7a+4vK3n94EQbUCy
                EYfostLPKekbm95De6RR+2dYt/Ligi21F3azWs30c9UoF51wIpJ52dppfL0FLXWN
                atwtJuNhGg1ehWqr0YFZYrpJ68YewcriMj1+6B8CgYBrRsTCrju7shu8P6vNv+pF
                IJa5b65JCAZ7DNKJN4Elp/JQN3/2Keqb/WsP0k5dQ5eozY3uG4eUrcKKSL0L+wda
                giAjxIfg/5C3V1ue4YJBEtLWiEz4Y/iV/KgzLOPpNpi54BypVQOB2ZzSkDCl5NHu
                NS1zzJbw+z+n6RMePWqmgQKBgF10vo60WQsSvpjxH36VjixT7QOJ8KpaZEQlJj56
                Sfe9agku2CcAEnAnDhrXKuqq0ttOvYKyjsAWESiTV0W2bIY6LOO3gZ5ZOT3PWf/1
                RQo3Lu2JVvJZCLbhWY+RmVAmesVRoOAoe5H7JTiH6+7CRbzrgBQHKTx9C2eujkX+
                IXEhAoGAVlRV3c29la5iN4W2qtPbU+jQe3nYvTwOe/ISZ+W2UEDVjbMLgfzemdpL
                pzIQIprUYAlTtXS7rirCiePnqzcezXOobi0IUqsqHMp+vq8lazNvwRRPXBDAkb6f
                mrvD/ESbKXlhvyWs5bhDZXs5ivWLOV0cI7R+K9YZCt7Ox1BQ1uc=
                -----END RSA PRIVATE KEY-----
              '';
            };
          };
          harbor-registry = {
            package = packages."persistent-volume-claim";
            aliases = [ "storage" ];
            config.size = "200Gi";
          };
          harbor-valkey = {
            package = packages.valkey;
            config = {
              sentinel.enabled = false;
              replicaCount = 1;
              auth.password = "dev-valkey-password";
            };
          };
          harbor-pg = {
            package = packages."stackgres-cluster";
            aliases = [ "postgres" ];
            # kind has one node and the pods anti-affine, so a second
            # instance never schedules.
            config.instances = 1;
          };
          harbor-db = {
            package = packages."stackgres-database";
            aliases = [ "database" ];
            config = {
              database = "registry";
              user = "harbor";
              password = "dev-harbor-db-password";
            };
          };
        };
      }
    )
  ];
}

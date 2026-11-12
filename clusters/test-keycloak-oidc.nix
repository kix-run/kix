# clusters/test-keycloak-oidc.nix: Grafana, Harbor, and Immich signing users
# in through Keycloak, under Cilium default deny.
#
# Each application's namespace holds an `oidc-client` instance named `oidc`,
# which names Keycloak with `deps.oidcProvider = ref.auth.keycloak`, sets the
# realm, and reads the client id and secret from a `secret` aliased
# `oidcClient` beside it. The application takes it as its `oidc`
# dependency. The
# realm `main` and the three clients are not created by Kix: create them in
# Keycloak's admin console with the redirect URIs each package header names
# before signing in.
#
# Grafana dials Keycloak's token and userinfo endpoints at the Service
# address, so its egress to Keycloak is derived. Harbor and Immich must
# discover the issuer at Keycloak's public URL, `https://keycloak.localhost`,
# which a pod cannot reach here: the name is not known to resolve to the
# ingress inside the cluster, and the self-signed certificate is trusted by
# neither (no Harbor `caBundle` is wired, and Immich takes none). Their
# OIDC wiring is evaluated here, not signed into. Their headers say what
# network path the request needs.
#
# Build:  nix build ./clusters#cluster-keycloak-oidc --extra-experimental-features pipe-operators

{ kix, packages }:

kix.buildCluster {
  name = "test-keycloak-oidc";
  modules = [
    kix.flavors.kind
    (
      { ref, ... }:
      {
        availablePackages = packages // {
          inherit (packages.experimental) cert-manager cluster-issuer;
        };
        networkPolicy.enable = true;
        # `*.localhost` resolves to loopback, so the port-forwarded Ingress
        # needs no /etc/hosts entry.
        cluster.domain = "localhost";

        # kind runs with the default CNI disabled, so the managed cilium
        # instance fills the cni role.
        cluster.roles.cni = {
          binding = "absent";
          provider = null;
        };
        instances.kube-system.cilium.package = packages.experimental.cilium;

        instances.ingress-system.ingress-nginx.package = packages.experimental.ingress-nginx;
        # cert-manager runs once per cluster, so it is declared in a
        # namespace of its own rather than added beside the issuer.
        instances.cert-manager.cert-manager.package = packages.experimental.cert-manager;
        instances.cert-manager.selfsigned = {
          package = packages.experimental.cluster-issuer;
          config.spec.selfSigned = { };
        };
        instances.stackgres-system.stackgres-operator.package = packages.experimental.stackgres-operator;

        instances.auth = {
          keycloak.package = packages.experimental.keycloak;
          keycloak-pg = {
            package = packages.experimental.stackgres-cluster;
            aliases = [ "postgres" ];
            # kind has one node and the pods anti-affine, so a second
            # instance never schedules.
            config.instances = 1;
          };
          keycloak-db = {
            package = packages.experimental.stackgres-database;
          };
          keycloak-db-password = {
            package = packages.secret;
            aliases = [ "password" ];
            # Dev-only value; it protects nothing.
            config = {
              source = ./dev-secrets/keycloak-db.sops.yaml;
              hash = "sha256-rgn6JZpWdY4hK9Cs6xIUUsG71gsVbab0Da/CZ0N4kRA=";
              keys = [ "password" ];
            };
          };
          # Test values only.
          keycloak-admin = {
            package = packages.secret;
            aliases = [ "bootstrapAdmin" ];
            config.stringData = {
              username = "admin";
              password = "dev-keycloak-admin-password";
            };
          };
        };

        instances.monitoring = {
          grafana = {
            package = packages.grafana;
            config = {
              ingress.host = "grafana.localhost";
              oidc.autoLogin = true;
              settings."auth.generic_oauth".role_attribute_path =
                "contains(realm_access.roles[*], 'grafana-admin') && 'Admin' || 'Viewer'";
            };
          };
          # Test values only.
          grafana-admin = {
            package = packages.secret;
            aliases = [ "grafanaAdmin" ];
            config.stringData = {
              admin-user = "admin";
              admin-password = "dev-grafana-admin-password";
            };
          };
          oidc = {
            package = packages.experimental.oidc-client;
            deps.oidcProvider = ref.auth.keycloak;
            config.realm = "main";
          };
          grafana-oidc = {
            package = packages.secret;
            aliases = [ "oidcClient" ];
            config.stringData = {
              clientId = "grafana";
              clientSecret = "dev-grafana-client-secret";
            };
          };
        };

        instances.harbor = {
          harbor = {
            package = packages.harbor;
            config.oidc = {
              groupsClaim = "groups";
              adminGroup = "harbor-admins";
            };
            config.core.settings.oidc_auto_onboard = true;
          };
          # Test values only.
          oidc = {
            package = packages.experimental.oidc-client;
            deps.oidcProvider = ref.auth.keycloak;
            config.realm = "main";
          };
          harbor-oidc = {
            package = packages.secret;
            aliases = [ "oidcClient" ];
            config.stringData = {
              clientId = "harbor";
              clientSecret = "dev-harbor-client-secret";
            };
          };
          # Dev-only values. The key below was generated for clusters/test-harbor.nix
          # and protects nothing.
          harbor-secrets = {
            package = packages.secret;
            aliases = [ "harborSecrets" ];
            config.stringData = {
              adminPassword = "Harbor12345";
              secretKey = "0123456789abcdef";
              coreSecret = "dev-core-secret";
              jobserviceSecret = "dev-jobservice-secret";
              csrfKey = "0123456789abcdef0123456789abcdef";
              registryHttpSecret = "dev-registry-http-secret";
              registryPassword = "dev-registry-password";
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
            package = packages.persistent-volume-claim;
            aliases = [ "storage" ];
            config.size = "10Gi";
          };
          harbor-valkey-password = {
            package = packages.secret;
            aliases = [ "valkeyPassword" ];
            config.stringData.password = "dev-valkey-password";
          };
          harbor-valkey = {
            package = packages.valkey;
            config.sentinel.enabled = false;
          };
          harbor-pg = {
            package = packages.experimental.stackgres-cluster;
            aliases = [ "postgres" ];
            config.instances = 1;
          };
          harbor-db = {
            package = packages.experimental.stackgres-database;
            aliases = [ "database" ];
            config = {
              database = "registry";
              user = "harbor";
            };
          };
          harbor-db-password = {
            package = packages.secret;
            aliases = [ "password" ];
            config = {
              source = ./dev-secrets/harbor-db.sops.yaml;
              hash = "sha256-nxxYCF5UR6Dn+PHqSeQFUVpn08f6zKlS+H/TYsfgu6Q=";
              keys = [ "password" ];
            };
          };
        };

        instances.photos = {
          immich = {
            package = packages.experimental.immich;
            config.oidc.autoLogin = true;
          };
          # Test values only.
          oidc = {
            package = packages.experimental.oidc-client;
            deps.oidcProvider = ref.auth.keycloak;
            config.realm = "main";
          };
          immich-oidc = {
            package = packages.secret;
            aliases = [ "oidcClient" ];
            config.stringData = {
              clientId = "immich";
              clientSecret = "dev-immich-client-secret";
            };
          };
          library = {
            package = packages.persistent-volume-claim;
            aliases = [ "storage" ];
            config.size = "50Gi";
          };
          immich-pg = {
            package = packages.experimental.stackgres-cluster;
            aliases = [ "postgres" ];
            config.instances = 1;
          };
          immich-db = {
            package = packages.experimental.stackgres-database;
            aliases = [ "database" ];
            config = {
              database = "immich";
              user = "immich";
            };
          };
          immich-db-password = {
            package = packages.secret;
            aliases = [ "password" ];
            config = {
              source = ./dev-secrets/immich-oidc-db.sops.yaml;
              hash = "sha256-FLPsEp1yreYLSH/vE0eaQZWcLTzXswoNR+/lMsrP6EA=";
              keys = [ "password" ];
            };
          };
          valkey = {
            package = packages.valkey;
            config.sentinel.enabled = false;
          };
          valkey-password = {
            package = packages.secret;
            aliases = [ "valkeyPassword" ];
            config.stringData.password = "dev-valkey-password";
          };
        };
      }
    )
  ];
}

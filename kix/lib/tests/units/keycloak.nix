# Tests for kix/packages/keycloak: the variables and flags the package owns,
# the public URL and the issuer URLs, the database sslmode, the
# bootstrapAdmin key check, the metrics toggle and the prometheus
# dependency, the alert rules and what they are gated on, and the JGroups
# peer policy. Keycloak runs in namespace `auth`
# with a database stub and a `secret` bootstrap administrator.
# Nothing routes to the instance, so the URL comes from env.KC_HOSTNAME.

{
  lib,
  eval,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  prometheusStub,
  netpolOn,
  alertRulesOf,
  allSelect,
  ...
}:

let
  keycloakPackage = import ../../../packages/keycloak;
  secretPackage = import ../../../packages/secret;

  # A `database` provider with stackgres-database's out shape. `tls` is
  # published only when it is not "absent".
  databasePackage =
    tls:
    { ... }:
    {
      meta = {
        version = "test";
        description = "database stub";
        owner = "test";
        defaultAliases = [ "database" ];
      };
      build =
        { self, scope, ... }:
        {
          credentials = scope.mkSecret {
            name = "db-credentials";
            keys = [
              "username"
              "password"
            ];
            stringData = {
              username = "keycloak";
              password = "pw";
            };
          };
          root = {
            resource = self.credentials;
            out = {
              host = "db.auth.svc";
              port = "5432";
              database = "keycloak";
              credentials = self.credentials;
            }
            // lib.optionalAttrs (tls != "absent") { inherit tls; };
          };
        };
    };

  url = "https://auth.example.com";

  clusterWith =
    {
      config ? { },
      env ? {
        KC_HOSTNAME = url;
      },
      adminData ? {
        username = "admin";
        password = "pw";
      },
      prometheus ? false,
      availability ? null,
      netpol ? false,
      dbTls ? "absent",
      smtp ? null,
    }:
    mkCluster [
      {
        instances.auth = {
          keycloak = {
            package = keycloakPackage;
          }
          // lib.optionalAttrs (availability != null) { inherit availability; }
          // {
            config = config // {
              env = env // (config.env or { });
            };
          };
          keycloak-db.package = databasePackage dbTls;
          keycloak-admin = {
            package = secretPackage;
            aliases = [ "bootstrapAdmin" ];
            config.stringData = adminData;
          };
        };
      }
      (lib.optionalAttrs prometheus {
        instances.monitoring.prometheus.package = prometheusStub;
      })
      (lib.optionalAttrs (availability != null) {
        cluster.capabilities.multiNode = true;
      })
      (lib.optionalAttrs netpol netpolOn)
      (lib.optionalAttrs (smtp != null) {
        instances.mail.smtp.package = eval.mkImport { out = smtp; };
      })
    ];

  deploymentOf = cluster: byName "keycloak" (ofKind "Deployment" (manifests cluster));
  containerOf = cluster: builtins.head (deploymentOf cluster).spec.template.spec.containers;
  envOf =
    cluster:
    builtins.listToAttrs (
      map (e: {
        inherit (e) name;
        value = e.value or e.valueFrom;
      }) (containerOf cluster).env
    );
  servicePortsOf =
    cluster: map (p: p.name) (byName "keycloak" (ofKind "Service" (manifests cluster))).spec.ports;
  hasServiceMonitor = cluster: ofKind "ServiceMonitor" (manifests cluster) != [ ];
  outOf = cluster: cluster.instances.auth.keycloak.out;
  peerPolicyOf =
    cluster: byName "keycloak-jgroups" (ofKind "CiliumNetworkPolicy" (manifests cluster));
in
{
  # The default instance evaluates; it is the positive control for every
  # refusal below. KC_HOSTNAME comes from env without a trailing slash, and
  # the bootstrap secret adds no checksum annotation.
  keycloak-defaults =
    let
      c = clusterWith {
        env.KC_HOSTNAME = "${url}/";
      };
      e = envOf c;
    in
    (
      e.KC_HOSTNAME == url
      && e.KC_DB == "postgres"
      && e.KC_DB_URL_HOST == "db.auth.svc"
      && e.KC_DB_URL_PORT == "5432"
      && e.KC_CACHE_STACK == "jdbc-ping"
      && e.KC_CACHE_EMBEDDED_NETWORK_BIND_ADDRESS.fieldRef.fieldPath == "status.podIP"
      && e.KC_METRICS_ENABLED == "true"
      && (containerOf c).args == [ "start" ]
      && (deploymentOf c).spec.strategy.type == "Recreate"
      && !((deploymentOf c).spec.template.metadata.annotations or { } ? "checksum/bootstrap-admin")
    )
    || throw "keycloak defaults: env ${builtins.toJSON e}";

  # out.url is KC_HOSTNAME and out.issuerUrl appends the realm path; a
  # realm name with a slash throws.
  keycloak-out-issuer =
    let
      out = outOf (clusterWith { });
    in
    (
      out.url == url
      && out.issuerUrl "master" == "${url}/realms/master"
      && !(builtins.tryEval (out.issuerUrl "a/b")).success
      && !(builtins.tryEval (out.issuerUrl "")).success
    )
    || throw "keycloak out: url ${out.url}";

  # Without a route, KC_HOSTNAME must come from env, and it must be a URL
  # with a scheme.
  keycloak-hostname-required = evalFails (clusterWith {
    env = { };
  });
  keycloak-hostname-needs-scheme = evalFails (clusterWith {
    env.KC_HOSTNAME = "auth.example.com";
  });
  keycloak-hostname-null-refused = evalFails (clusterWith {
    env.KC_HOSTNAME = null;
  });

  # Every variable the package owns throws when env sets it, also to null.
  keycloak-owned-env-refused =
    let
      accepted =
        builtins.filter
          (
            name:
            !(evalFails (clusterWith {
              config.env.${name} = "x";
            }))
          )
          [
            "KC_DB"
            "KC_DB_URL"
            "KC_DB_URL_HOST"
            "KC_DB_PASSWORD"
            "KC_BOOTSTRAP_ADMIN_USERNAME"
            "KC_BOOTSTRAP_ADMIN_PASSWORD"
            "KC_HTTP_ENABLED"
            "KC_HTTP_PORT"
            "KC_HTTP_MANAGEMENT_PORT"
            "KC_HTTP_RELATIVE_PATH"
            "KC_HTTP_MANAGEMENT_RELATIVE_PATH"
            "KC_HTTP_MANAGEMENT_HEALTH_ENABLED"
            "KC_HTTP_MANAGEMENT_SCHEME"
            "KC_HEALTH_ENABLED"
            "KC_PROXY_HEADERS"
            "KC_CACHE"
            "KC_CACHE_STACK"
            "KC_CACHE_EMBEDDED_NETWORK_BIND_ADDRESS"
            "KC_CACHE_EMBEDDED_NETWORK_BIND_PORT"
            "KC_CACHE_EMBEDDED_NETWORK_EXTERNAL_PORT"
            "KC_CACHE_EMBEDDED_NETWORK_EXTERNAL_ADDRESS"
            "KC_CACHE_CONFIG_FILE"
            "KC_METRICS_ENABLED"
          ];
    in
    (
      accepted == [ ]
      && evalFails (clusterWith {
        config.env.KC_DB_URL_HOST = null;
      })
      &&
        (envOf (clusterWith {
          config.env.KC_LOG_LEVEL = "debug";
        })).KC_LOG_LEVEL == "debug"
    )
    || throw "keycloak env accepted owned names: ${builtins.toJSON accepted}";

  # extraArgs refuses every spelling of an owned option, `--optimized`, and
  # `--hostname`, and passes other options after `start`.
  keycloak-owned-args-refused =
    let
      accepted =
        builtins.filter
          (
            arg:
            !(evalFails (clusterWith {
              config.extraArgs = [ arg ];
            }))
          )
          [
            "--db-password=x"
            "--db"
            "--db-url=jdbc:postgresql://x/y"
            "--cache-stack=kubernetes"
            "--cache-embedded-network-bind-port=7900"
            "--cache-config-file=cache.xml"
            "--http-relative-path=/auth"
            "--optimized"
            "--hostname=https://x.example.com"
          ];
      args =
        (containerOf (clusterWith {
          config.extraArgs = [ "--log-level=INFO" ];
        })).args;
    in
    (
      accepted == [ ]
      &&
        args == [
          "start"
          "--log-level=INFO"
        ]
    )
    || throw "keycloak extraArgs: accepted ${builtins.toJSON accepted}, args ${builtins.toJSON args}";

  # The database's out.tls = true sets and owns sslmode=require. false,
  # null, and an absent field leave the driver default and let env set
  # KC_DB_URL_PROPERTIES.
  keycloak-db-sslmode =
    let
      props =
        dbTls:
        (envOf (clusterWith {
          inherit dbTls;
        })).KC_DB_URL_PROPERTIES or null;
      withEnv =
        dbTls:
        clusterWith {
          inherit dbTls;
          config.env.KC_DB_URL_PROPERTIES = "?sslmode=verify-full";
        };
    in
    (
      props true == "?sslmode=require"
      && props false == null
      && props null == null
      && props "absent" == null
      && evalFails (withEnv true)
      && (envOf (withEnv false)).KC_DB_URL_PROPERTIES == "?sslmode=verify-full"
      && (envOf (withEnv null)).KC_DB_URL_PROPERTIES == "?sslmode=verify-full"
    )
    || throw "keycloak sslmode: tls=true gives ${builtins.toJSON (props true)}";

  # A bootstrapAdmin secret without the key `password` fails the build.
  keycloak-bootstrap-admin-checked = evalFails (clusterWith {
    adminData.username = "admin";
  });

  # Adding a prometheus dependency adds the Service port and the
  # ServiceMonitor and leaves the pod template unchanged; metrics.enabled =
  # false removes KC_METRICS_ENABLED and refuses it in env.
  keycloak-metrics =
    let
      plain = clusterWith { };
      scraped = clusterWith { prometheus = true; };
      off = clusterWith {
        prometheus = true;
        config.metrics.enabled = false;
      };
    in
    (
      servicePortsOf plain == [ "http" ]
      && !(hasServiceMonitor plain)
      &&
        servicePortsOf scraped == [
          "http"
          "metrics"
        ]
      && hasServiceMonitor scraped
      && (deploymentOf plain).spec.template == (deploymentOf scraped).spec.template
      && !((envOf off) ? KC_METRICS_ENABLED)
      && servicePortsOf off == [ "http" ]
      && !(hasServiceMonitor off)
      && evalFails (clusterWith {
        config.metrics.enabled = false;
        config.env.KC_METRICS_ENABLED = "true";
      })
    )
    || throw "keycloak metrics: plain ${builtins.toJSON (servicePortsOf plain)} scraped ${builtins.toJSON (servicePortsOf scraped)}";

  # The rules select the instance's Service and need a prometheus
  # dependency and metrics.enabled.
  keycloak-alerts =
    let
      rulesOf = cluster: alertRulesOf "PrometheusRule" "keycloak" (manifests cluster);
      rules = rulesOf (clusterWith {
        prometheus = true;
      });
    in
    (
      allSelect ''namespace="auth",service="keycloak"'' rules
      &&
        builtins.attrNames rules == [
          "KeycloakDatabasePoolExhausted"
          "KeycloakDown"
        ]
      && rulesOf (clusterWith { }) == null
      &&
        rulesOf (clusterWith {
          prometheus = true;
          config.metrics.enabled = false;
        }) == null
    )
    || throw "keycloak alerts: ${builtins.toJSON (builtins.attrNames rules)}";

  # With more than one replica, the policy keycloak-jgroups selects the
  # Deployment's pods (instance label included) and admits ingress from and
  # egress to the same selector, in namespace auth, on 7800 and 57800 only.
  # One replica renders no policy.
  keycloak-peer-policy-selects-instance =
    let
      c = clusterWith {
        availability = "node";
        netpol = true;
      };
      single = clusterWith {
        availability = "none";
        netpol = true;
      };
      selector = (deploymentOf c).spec.selector.matchLabels;
      spec = (peerPolicyOf c).spec;
      ingress = builtins.head spec.ingress;
      egress = builtins.head spec.egress;
      ports = [
        {
          port = 7800;
          protocol = "TCP";
        }
        {
          port = 57800;
          protocol = "TCP";
        }
      ];
    in
    (
      (deploymentOf c).spec.replicas == 2
      && selector."app.kubernetes.io/instance" == "keycloak"
      && spec.matchLabels == selector
      && builtins.length spec.ingress == 1
      && ingress.stubRule == "caller-ingress"
      && ingress.callerSelector == selector
      && ingress.callerNamespace == "auth"
      && ingress.ports == ports
      && builtins.length spec.egress == 1
      && egress.stubRule == "service-egress"
      && egress.selector == selector
      && egress.namespace == "auth"
      && egress.ports == ports
      && (deploymentOf single).spec.replicas == 1
      && peerPolicyOf single == null
    )
    || throw "keycloak peer policy: ${builtins.toJSON (peerPolicyOf c)}";

  # An smtp dependency outside the cluster opens egress to its port; one
  # inside the cluster, or none, adds no policy. The realm keeps the
  # sender, so the server needs no `from`.
  keycloak-mail-egress =
    let
      server = {
        host = "smtp.example.org";
        port = "465";
        tls = "implicit";
      };
      policyOf =
        smtp:
        lib.findFirst (r: r.metadata.name == "keycloak-mail-egress") null (
          manifests (clusterWith {
            netpol = true;
            inherit smtp;
          })
        );
    in
    (
      policyOf server != null
      && policyOf null == null
      && policyOf (server // { external = false; }) == null
      && lib.hasInfix "465" (builtins.toJSON (policyOf server))
    )
    || throw "keycloak mail egress: ${builtins.toJSON (policyOf server)}";
}

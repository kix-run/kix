# keycloak: Keycloak, an identity and access management server (OpenID
# Connect, OAuth 2.0, and SAML), with its database on PostgreSQL.
#
# Installs a Deployment, a Service on port 8080, and a route through
# `kix.expose` when the cluster has an ingress controller or a gateway and
# the instance has a host (`ingress.host`, or the cluster's
# `cluster.domain`). Keycloak keeps realms, users, clients, and sessions
# that must survive a restart in the database, so the pods are stateless.
#
# Dependencies:
#   database (required)        a PostgreSQL database and role with
#                              `out.{host,port,database}` and
#                              `out.credentials` (keys `username` and
#                              `password`), such as stackgres-database.
#                              When `out.tls` is true, the package sets
#                              `KC_DB_URL_PROPERTIES` to
#                              `?sslmode=require`. When it is false, null,
#                              or absent, the JDBC driver's default sslmode
#                              `prefer` applies, and `env` may set
#                              `KC_DB_URL_PROPERTIES`.
#   bootstrapAdmin (required)  a secret with keys `username` and
#                              `password`. Keycloak creates this temporary
#                              administrator in the master realm only when
#                              the master realm does not exist yet, on the
#                              first start against an empty database.
#                              Keycloak reads the secret only then, and a
#                              changed secret does not restart the pods or
#                              rotate that administrator; manage
#                              administrators in Keycloak itself.
#   prometheus (optional)      adds the management port to the Service as
#                              `metrics` and a ServiceMonitor. Keycloak
#                              serves metrics on the management port (9000)
#                              while `metrics.enabled` is true, with or
#                              without this dependency, so adding a
#                              Prometheus does not restart Keycloak.
#   ingressNginx or gateway, clusterIssuer (optional)
#                              the route from `kix.expose`.
#   smtp (optional)            a mail server honouring kix.contracts.smtp.
#                              Keycloak keeps mail settings in each realm,
#                              so enter the server, sender, and login in
#                              the realm's Email tab. The dependency opens
#                              egress to the server's port when it is
#                              outside the cluster.
#
# Minimal instances, with a stackgres-cluster `postgres` elsewhere
# (`clusters/test-keycloak.nix` evaluates this shape with `stringData`):
#
#   instances.auth = {
#     keycloak = {
#       package = packages.experimental.keycloak;
#       config.ingress.host = "auth.example.com";
#     };
#     keycloak-db.package = packages.experimental.stackgres-database;
#     keycloak-db-password = {
#       package = packages.secret;
#       aliases = [ "password" ];
#       config = { source = ./secrets/keycloak-db.yaml; keys = [ "password" ]; };
#     };
#     keycloak-admin = {
#       package = packages.secret;
#       aliases = [ "bootstrapAdmin" ];
#       config.source = ./secrets/keycloak-admin.sops.yaml;
#       config.keys = [ "username" "password" ];
#     };
#   };
#
# Public URL: `KC_HOSTNAME` is the route's URL. Keycloak's `start` command
# refuses to run without a hostname, so evaluation fails when Kix derives no
# URL and `env.KC_HOSTNAME` is unset. When TLS terminates outside Kix (for
# example behind cloudflared), set `env.KC_HOSTNAME` to the public URL,
# including the scheme. `KC_PROXY_HEADERS = "xforwarded"` makes Keycloak
# trust the X-Forwarded-* headers of the proxy in front of it. A client that
# reaches port 8080 without that proxy can set those headers itself.
#
# Realms, clients, and users are not managed by this package. Create them in
# the admin console or the admin REST API at `out.url`, logged in as the
# bootstrap administrator, and replace that temporary administrator with a
# permanent one.
#
# Replicas follow the cluster's availability level (one at `none`, two
# above); the instance's `availability` overrides
# it. The pods form one Infinispan cluster through Keycloak's default
# `jdbc-ping` stack: each pod records its address in the database and dials
# its peers on ports 7800 (JGroups) and 57800 (failure detection). Keycloak
# secures that traffic with mutual TLS, from a certificate it generates and
# stores in the database. With more than one replica, the policy
# `<instance>-jgroups` admits both ports between the instance's own pods.
#
# Every rollout stops all pods before starting new ones (`Recreate`).
# Keycloak's update-compatibility guide lists the changes that need every
# old pod stopped first, including a new minor release (its first pod
# migrates the schema) and a changed cache option. Evaluation cannot tell
# which kind of change a deploy carries, so a deploy makes Keycloak
# unavailable until a new pod is ready.
#
# Each instance needs its own database. Two instances on one database share
# realms and the JGroups discovery table, and nothing in the build refuses
# that wiring.
#
# Keycloak runs `start` without `--optimized`: the stock image is built for
# other build-time options (database vendor, health, metrics), so every
# start re-runs Keycloak's build step before it serves. The startup probe
# and the progress deadline allow 15 minutes, which also covers the first
# start's schema creation.
#
# Network policy covers the database, the route, the scrape, the peers,
# and the mail server of the `smtp` dependency. Identity brokering and user
# federation (LDAP) dial servers outside the cluster that differ per
# instance, and the package declares no egress to them. Under default deny,
# add a NetworkPolicy or a CiliumNetworkPolicy that selects this instance's
# pods and allows that egress.
#
# `out`, checked by `kix.contracts.experimental.oidcProvider`:
#   url          the public URL, `KC_HOSTNAME`.
#   issuerUrl    a function from a realm name to that realm's OpenID
#                Connect issuer, `<url>/realms/<realm>`.
#   endpoints    a function from a realm name to `{ authorizationUrl;
#                tokenUrl; userinfoUrl; }`. The authorization URL is
#                public, for the browser. The token and userinfo URLs are
#                the Service's in-cluster address, so an application that
#                dials them gets derived egress to Keycloak. They are plain
#                HTTP (port 8080), so the client secret crosses the pod
#                network unencrypted.
# Applications (grafana, harbor, immich) sign in through an `oidc-client`
# instance in their namespace, which takes this instance as its
# `oidcProvider` dependency with a realm and the client's secret; each
# application's header names the redirect URI to register. The package
# answers no alias by default, because two Keycloak instances answering one
# would fail every such client in the cluster. Wire it with
# `deps.oidcProvider = ref.<ns>.<instance>`, or give the one instance
# `aliases = [ "oidcProvider" ]`.
#
# Alerts: with a prometheus dependency and `metrics.enabled`, a
# PrometheusRule `<instance>-alerts` selects the Service's series.
#   KeycloakDown (critical)                   no replica answers a scrape,
#                                             so no login succeeds.
#   KeycloakDatabasePoolExhausted (warning)   threads on a pod keep waiting
#                                             for a database connection.
# A database outage keeps the management port answering but fails the
# readiness probe, so it shows as KubeDeploymentReplicasMismatch from
# prometheus-default-rules, beside the database's own alerts. Server-error
# and latency objectives (`http_server_requests_seconds`) are left to the
# site. Failed logins need `KC_EVENT_METRICS_USER_ENABLED` in `env`, and
# the site alerts on `keycloak_user_events_total`. Keycloak marks its
# `vendor_jgroups_*` clustering metrics as unfit for alerting, so a split
# cache cluster has no alert.
#
# Escape hatches: `env` for Keycloak options (`KC_*`), `extraArgs` for
# options of `kc.sh start`, and the instance's `partsOverlays` for probes,
# resources, and placement.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  release = "26.8.0";
  name = scope.instanceName;
  who = "keycloak ${scope.namespaceName}/${name}";

  # Covers the build step that `start` runs on every boot and the first
  # start's schema creation.
  startupSeconds = 900;

  httpPort = 8080;
  managementPort = 9000;
  jgroupsPort = 7800;
  # Keycloak's failure detection listens on the JGroups port plus 50000.
  jgroupsFdPort = 57800;
  jgroupsPorts = [
    jgroupsPort
    jgroupsFdPort
  ];

  # `kc.sh` reads each option from KC_<OPTION> or --<option>, so the flag
  # spellings of the owned variables come from their names.
  flagOf = var: "--" + lib.toLower (lib.replaceStrings [ "_" ] [ "-" ] (lib.removePrefix "KC_" var));

  validUrl = u: builtins.isString u && builtins.match "https?://[^/]+(/.*)?" u != null;
in
{
  meta = {
    version = release;
    description = "Keycloak, an identity and access management server, with its database on PostgreSQL";
    owner = "platform";
  };

  deps.database.assertions = dep: kix.contracts.postgresDatabase.assertions who dep;

  options = {
    image = kix.options.image {
      repository = "quay.io/keycloak/keycloak";
      tag = release;
      digest = "sha256:b0f60d489d51c5d113390bdf5461d4c06e6051be026c05549f2e1e10ec352bcc";
    };
    # Upstream's sizing guide starts at 1250 MB of memory per pod. The JVM
    # takes 70% of the memory limit as heap (JAVA_OPTS_KC_HEAP in kc.sh).
    resources = kix.options.resources {
      requests = {
        cpu = "500m";
        memory = "1250Mi";
      };
      limits = {
        cpu = "2";
        memory = "2Gi";
      };
    };
    env = kix.options.env // {
      description = "Extra environment variables for Keycloak options the package does not set (`KC_*`): a string, a `fieldRef` source, or a `secretKeyRef` source naming a Secret managed outside Kix with `kix.untrackedRef`. The database, bootstrapAdmin, ports, proxy, health, metrics, and cache variables are set by the package. `KC_HOSTNAME` replaces the routed URL and must be a URL with a scheme.";
    };
    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--log-level=INFO,org.keycloak.events:DEBUG" ];
      description = "Extra arguments to `kc.sh start`. Options the package sets through environment variables, `--optimized`, and `--hostname` are refused.";
    };
    ingress = kix.options.ingress;
    metrics = kix.options.monitor;
  };

  build = [
    (
      {
        self,
        config,
        scope,
        kix,
        database,
        bootstrapAdmin,
        prometheus ? null,
        smtp ? null,
        ...
      }:
      let
        # Keycloak keeps each realm's mail settings, sender and login
        # included, in the realm. The dependency only opens the network
        # path to the server.
        relay = kix.contracts.smtp.helpers.server { inherit who smtp; };
        # Only `metrics.enabled` decides KC_METRICS_ENABLED. Wiring a
        # prometheus dependency changes the Service and the ServiceMonitor
        # but not the pod template, so it does not restart Keycloak.
        metricsOn = config.metrics.enabled;

        replicas = kix.availability.pick availability {
          none = 1;
          pod = 2;
          node = 2;
          zone = 2;
        };
        scraped = metricsOn && prometheus != null;

        admin = kix.contracts.secret.helpers.use {
          inherit who;
          arg = "bootstrapAdmin";
          dep = bootstrapAdmin;
          keys = [
            "username"
            "password"
          ];
        };

        # `out.url` and the issuers derive from this, so a `KC_HOSTNAME`
        # from env must be a literal URL. `kc.sh start` refuses to run
        # without a hostname, so a missing URL fails evaluation.
        hostname =
          if config.env ? KC_HOSTNAME then
            if validUrl config.env.KC_HOSTNAME then
              lib.removeSuffix "/" config.env.KC_HOSTNAME
            else
              scope.fail {
                package = "keycloak";
                option = "env.KC_HOSTNAME";
                message = "env.KC_HOSTNAME must be a URL with a scheme, such as \"https://auth.example.com\"; got ${builtins.toJSON config.env.KC_HOSTNAME}. Keycloak builds its issuer URLs from it.";
              }
          else if self.exposure.urlOrNull != null then
            self.exposure.urlOrNull
          else
            scope.fail {
              package = "keycloak";
              message = "Keycloak needs its public URL, and nothing routes to this instance.";
              fix = "Set ingress.host (or cluster.domain) with an ingress controller or a gateway in the cluster, or set env.KC_HOSTNAME to the URL clients reach, such as \"https://auth.example.com\".";
            };

        # The contract's `tls` is true, false, or null (the provider cannot
        # tell). Only true is acted on: `prefer` would accept a plaintext
        # connection from a server that should speak TLS.
        dbTls = (database.out.tls or null) == true;

        ownedGroups = [
          {
            vars = {
              KC_DB = "postgres";
              KC_DB_URL_HOST = database.out.host;
              KC_DB_URL_PORT = toString database.out.port;
              KC_DB_URL_DATABASE = database.out.database;
              KC_DB_USERNAME = database.out.credentials.out.keyRef "username";
              KC_DB_PASSWORD = database.out.credentials.out.keyRef "password";
            }
            // lib.optionalAttrs dbTls { KC_DB_URL_PROPERTIES = "?sslmode=require"; };
            # KC_DB_URL replaces the host, port, and database above.
            names = [ "KC_DB_URL" ];
            from = "the database dependency";
            fix =
              "Wire a different database instance through deps.database instead."
              + lib.optionalString dbTls " KC_DB_URL_PROPERTIES is set because the database's out.tls is true.";
          }
          {
            vars = {
              KC_BOOTSTRAP_ADMIN_USERNAME = admin.out.keyRef "username";
              KC_BOOTSTRAP_ADMIN_PASSWORD = admin.out.keyRef "password";
            };
            from = "the bootstrapAdmin dependency";
            fix = "Wire a different secret through deps.bootstrapAdmin instead.";
          }
          {
            vars = {
              KC_HTTP_ENABLED = "true";
              KC_HTTP_PORT = toString httpPort;
              KC_HTTP_MANAGEMENT_PORT = toString managementPort;
              # The probes speak plain HTTP. The management port follows the
              # main interface's scheme unless this is set, so HTTPS options
              # in env would otherwise fail every probe.
              KC_HTTP_MANAGEMENT_SCHEME = "http";
              KC_HEALTH_ENABLED = "true";
              KC_PROXY_HEADERS = "xforwarded";
            };
            # The route, the probes, and the issuer URLs assume the root
            # path on both ports. KC_HTTP_MANAGEMENT_HEALTH_ENABLED = false
            # moves the health endpoints to the routed http port.
            names = [
              "KC_HTTP_RELATIVE_PATH"
              "KC_HTTP_MANAGEMENT_RELATIVE_PATH"
              "KC_HTTP_MANAGEMENT_HEALTH_ENABLED"
            ];
            from = "the package, so the Service, the probes, the route, and out.issuerUrl match the container";
            fix = "Remove it from env.";
          }
          {
            vars = {
              KC_CACHE = "ispn";
              KC_CACHE_STACK = "jdbc-ping";
              # JGroups binds to a site-local address by default, which a
              # pod CIDR outside RFC 1918 does not have.
              KC_CACHE_EMBEDDED_NETWORK_BIND_ADDRESS = {
                valueFrom.fieldRef.fieldPath = "status.podIP";
              };
            };
            # The peer policy opens the default JGroups ports between pod
            # IPs. A moved port, an advertised external address, or a
            # custom Infinispan stack would leave the pods unable to reach
            # each other under default deny.
            names = [
              "KC_CACHE_EMBEDDED_NETWORK_BIND_PORT"
              "KC_CACHE_EMBEDDED_NETWORK_EXTERNAL_PORT"
              "KC_CACHE_EMBEDDED_NETWORK_EXTERNAL_ADDRESS"
              "KC_CACHE_CONFIG_FILE"
            ];
            from = "the package, which clusters the replicas through the database (jdbc-ping) on the ports its <instance>-jgroups policy opens";
            fix = "Remove it from env.";
          }
          {
            vars = lib.optionalAttrs metricsOn { KC_METRICS_ENABLED = "true"; };
            names = lib.optional (!metricsOn) "KC_METRICS_ENABLED";
            from = "the metrics.enabled option";
            fix =
              if metricsOn then
                "Remove it from env."
              else
                "Remove it from env, and set metrics.enabled = true to serve metrics.";
          }
        ];

        env = kix.mkEnvVars (
          kix.mergeEnv {
            inherit who;
            owned = ownedGroups;
          } config.env
          // {
            KC_HOSTNAME = hostname;
          }
        );

        ownedFlags = lib.foldl' (
          acc: g:
          acc
          // lib.genAttrs (map flagOf (builtins.attrNames (g.vars or { }) ++ g.names or [ ])) (
            _: "it comes from ${g.from}. Remove it from extraArgs."
          )
        ) { } ownedGroups;

        args = [
          "start"
        ]
        ++ kix.guardArgs {
          inherit who;
          owned = ownedFlags // {
            "--optimized" =
              "Keycloak must run its build step at start, because the stock image is built for other build-time options. Remove it from extraArgs.";
            "--hostname" = "it comes from the route. Set env.KC_HOSTNAME instead.";
          };
        } config.extraArgs;

        realmPath =
          field: realm:
          if builtins.isString realm && builtins.match "[^/?#[:space:]]+" realm != null then
            "/realms/${realm}"
          else
            scope.fail {
              package = "keycloak";
              message = "${field} takes a realm name without '/', '?', '#', or spaces; got ${builtins.toJSON realm}.";
            };

        httpProbe = path: {
          httpGet = {
            inherit path;
            port = "management";
          };
        };
      in
      {
        deployment =
          {
            inherit name;
            spec = {
              inherit replicas;
              # Pods of an older minor release must not run against a
              # schema the new release migrated; see the header.
              strategy.type = "Recreate";
              progressDeadlineSeconds = startupSeconds + 60;
              selector.matchLabels = scope.selectorLabels;
              # A changed database password restarts the pods, which read
              # it once at start. A `secret-ref` has no content hash. The
              # bootstrap secret has no annotation: Keycloak reads it only
              # on the first start, so a restart for it would change nothing.
              template.metadata.annotations = lib.filterAttrs (_: v: v != null) {
                "checksum/database" = database.out.credentials.out.identityHash or null;
              };
              template.spec = {
                automountServiceAccountToken = false;
                # A Service named kc-<x> would inject KC_<X>_SERVICE_HOST
                # and KC_<X>_PORT, which Keycloak reads as options.
                enableServiceLinks = false;
                # Kubernetes default: Keycloak's own shutdown delay and
                # timeout are seconds long.
                terminationGracePeriodSeconds = 30;
                containers = [
                  {
                    name = "keycloak";
                    image = kix.image.ref config.image;
                    imagePullPolicy = config.image.pullPolicy;
                    inherit args env;
                    ports = [
                      (kix.port "http" httpPort)
                      (kix.port "management" managementPort)
                      (kix.port "jgroups" jgroupsPort)
                      (kix.port "jgroups-fd" jgroupsFdPort)
                    ];
                    # /health/started answers 503 until the build step and
                    # the schema migration finish.
                    startupProbe = httpProbe "/health/started" // {
                      periodSeconds = 10;
                      timeoutSeconds = 5;
                      failureThreshold = startupSeconds / 10;
                    };
                    # /health/live does not check the database, so a
                    # database outage does not restart every pod.
                    livenessProbe = httpProbe "/health/live" // {
                      periodSeconds = 10;
                      timeoutSeconds = 5;
                      failureThreshold = 6;
                    };
                    # /health/ready includes the database connection pool
                    # check only while metrics are enabled; Keycloak ties
                    # that check to KC_METRICS_ENABLED.
                    readinessProbe = httpProbe "/health/ready" // {
                      periodSeconds = 5;
                      timeoutSeconds = 3;
                      failureThreshold = 3;
                    };
                    resources = config.resources;
                    # The root filesystem stays writable: `start` without
                    # `--optimized` rewrites /opt/keycloak/lib/quarkus on
                    # every boot. 1000 is the image's `keycloak` user.
                    securityContext = {
                      runAsNonRoot = true;
                      runAsUser = 1000;
                      allowPrivilegeEscalation = false;
                      capabilities.drop = [ "ALL" ];
                    };
                  }
                ];
              };
            };
          }
          |> scope.mkDeployment;

        # The management port joins the Service only when something
        # scrapes it, and the route sends only the http port.
        service =
          self.deployment
          |> kix.service.fromWorkload {
            inherit name;
            ports = [
              {
                name = "http";
                port = httpPort;
                targetPort = "http";
              }
            ]
            ++ lib.optional scraped {
              name = "metrics";
              port = managementPort;
              targetPort = "management";
            };
          }
          |> scope.mkResource;

        # Kix derives peer rules only for a StatefulSet's pods, so this
        # policy admits the JGroups ports between the instance's own pods.
        # The derived policies of the Deployment cover everything else.
        peers =
          if replicas > 1 then
            let
              # Read only when the scope has an enforcer (kix.operandPolicy).
              netpol = scope.networkPolicyEnforcer.netpol;
              selector = self.deployment.out.selector;
              ports = map (port: {
                inherit port;
                protocol = "TCP";
              }) jgroupsPorts;
            in
            kix.operandPolicy {
              inherit scope;
              name = "${name}-jgroups";
              spec = netpol.mkEndpointSelector selector // {
                ingress = [
                  (netpol.mkCallerIngressRule {
                    callerSelector = selector;
                    callerNamespace = scope.namespaceName;
                    inherit ports;
                  })
                ];
                egress = [
                  (netpol.mkServiceEgressRule {
                    inherit selector ports;
                    namespace = scope.namespaceName;
                    sourceNamespace = scope.namespaceName;
                  })
                ];
              };
            }
          else
            null;

        mailEgress = kix.contracts.smtp.helpers.egressPolicy {
          inherit scope;
          smtp = relay;
          name = "${name}-mail-egress";
          selector = self.deployment.out.selector;
        };

        root = {
          resource = self.service;
          requires = builtins.filter (p: p != null) [ self.peers ];
          out = kix.contracts.experimental.oidcProvider.check who {
            url = hostname;
            issuerUrl = realm: "${hostname}${realmPath "out.issuerUrl" realm}";
            # Keycloak computes every URL it issues from KC_HOSTNAME, so a
            # token from the in-cluster address carries the public issuer.
            endpoints =
              realm:
              let
                path = realmPath "out.endpoints" realm;
                internal = self.service.out.url { port = httpPort; };
              in
              {
                authorizationUrl = "${hostname}${path}/protocol/openid-connect/auth";
                tokenUrl = "${internal}${path}/protocol/openid-connect/token";
                userinfoUrl = "${internal}${path}/protocol/openid-connect/userinfo";
              };
          };
        };
      }
    )
    (kix.expose { service = "service"; })
    # DI passes a build function only the arguments its formals name, so
    # the wrapper names every argument kix.monitor reads.
    (
      {
        self,
        config,
        scope,
        lib,
        prometheus ? null,
        ...
      }@args:
      let
        ns = scope.namespaceName;
        # The Service carries the instance name.
        sel = ''namespace="${ns}",service="${name}"'';
      in
      kix.monitor {
        service = "service";
        alerts = {
          KeycloakDown = {
            expr = "sum by (namespace, service) (up{${sel}}) == 0 or absent(up{${sel}})";
            "for" = "10m";
            severity = "critical";
            summary = "Keycloak is down.";
            description = "No replica of Keycloak ${ns}/${name} has answered a scrape for 10 minutes, so nobody can log in to the applications that use it, and their token refreshes fail. Check the pods of the Deployment ${name} in ${ns} and their logs.";
          };
          KeycloakDatabasePoolExhausted = {
            expr = "max by (namespace, service, pod) (agroal_awaiting_count{${sel}}) > 0";
            "for" = "15m";
            severity = "warning";
            summary = "Keycloak requests wait for a database connection.";
            description = "On Keycloak pod {{ $labels.namespace }}/{{ $labels.pod }}, {{ $value | humanize }} threads have waited for a database connection at every check for 15 minutes, so logins and token requests are slow or time out. Check the database's load and slow queries before raising the pool size (`KC_DB_POOL_MAX_SIZE` in env), since more connections can overload the database.";
          };
        };
      } args
    )
  ];
}

# grafana: Grafana, with datasources wired from its dependencies and
# k8s-sidecar containers that load dashboards and datasources from labelled
# ConfigMaps.
#
# Installs a Deployment and its ServiceAccount, a Service on port 80, the
# grafana.ini ConfigMap, a datasources ConfigMap, and, when the cluster has
# an ingress controller or a gateway and the instance sets `ingress.host`, a
# route through `kix.expose`. Without `ingress.host` there is no route, even
# on a cluster with a `cluster.domain`. Grafana's `root_url` is that route's
# URL.
#
# Dependencies:
#   grafanaAdmin (required)      a secret with keys `admin-user` and
#                                `admin-password`, the login of Grafana's
#                                administrator. The sidecars use it to tell
#                                Grafana to reload. A `secret` (SOPS source)
#                                or a `secret-ref`. A change to a `secret`
#                                restarts the pod; a `secret-ref` has no
#                                content Kix can hash, so a new password
#                                takes effect only when the pod restarts.
#   storage (optional)           a claim for /var/lib/grafana (SQLite
#                                database, plugins), such as a
#                                persistent-volume-claim instance. Without
#                                one the data lives in an emptyDir, which a
#                                pod restart empties.
#   prometheusServer (optional)  the default Prometheus datasource, from
#                                `out.serviceUrl`.
#   alertmanager (optional)      an Alertmanager datasource.
#   loki (optional)              a Loki datasource.
#   tempo (optional)             a Tempo datasource, from `out.queryUrl`.
#                                With `loki` also wired, a span links to
#                                the logs of its pod, matched on the
#                                `namespace` and `pod` labels that
#                                loki-logs writes. With `prometheusServer`
#                                also wired, the service graph reads the
#                                series Tempo's metrics generator writes
#                                to that datasource's store when enabled;
#                                without them the graph is empty.
#   prometheus (optional)        the operator whose ServiceMonitor scrapes
#                                Grafana while `metrics.enabled`.
#   oidcProvider, oidcClient (with `oidc.enabled`)
#                                single sign-on; see below.
#
# Minimal instances:
#
#   instances.monitoring-system = {
#     grafana.package = packages.grafana;
#     grafana-admin = {
#       package = packages.secret;
#       aliases = [ "grafanaAdmin" ];
#       config.source = ./secrets/grafana-admin.sops.yaml;
#       config.keys = [ "admin-user" "admin-password" ];
#     };
#   };
#
# clusters/test-monitoring-native.nix evaluates this pair with `stringData`
# in place of the SOPS file.
#
# Each wired datasource has a fixed uid, set by `prometheusDatasource`,
# `alertmanagerDatasource`, `lokiDatasource`, and `tempoDatasource`, so a
# dashboard that names it by uid works on every cluster. `datasources` adds
# more; a name or uid that clashes with a wired one is refused.
#
# The dashboards sidecar watches ConfigMaps labelled `grafana_dashboard: "1"`
# in every namespace; the datasources sidecar watches `grafana_datasource:
# "1"` in Grafana's namespace. Either needs read access to every ConfigMap
# in the cluster (and every Secret with `sidecar.sources.secrets`). With the
# datasources sidecar off, the package mounts its datasources ConfigMap
# directly.
#
# The package turns off Grafana's calls to grafana.com: usage reports,
# update checks, plugin signing-key downloads, plugin preinstalls, and the
# news feed. `settings` turns them back on.
#
# Grafana serves /metrics on its HTTP port without authentication, and the
# route sends every path there, so the metrics (request counts and the
# number of users, dashboards, and datasources) are public at
# <host>/metrics once `ingress.host` is set. To keep them private on a
# routed instance, set `settings.metrics.enabled = false` and
# `metrics.enabled = false`, which also stops the scrape.
#
# Single sign-on: with `oidc.enabled`, Grafana signs users in through
# `auth.generic_oauth` against the `oidcProvider` dependency
# (`kix.contracts.oidcProvider`, such as a keycloak instance) in the realm
# `oidc.realm`. `oidcClient` is a secret with keys `clientId` and
# `clientSecret`, which reach Grafana as GF_AUTH_GENERIC_OAUTH_CLIENT_ID
# and GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET. Register a confidential client
# with the redirect URI `<root_url>/login/generic_oauth`; evaluation fails
# without a `root_url`.
# The package sets the authorization, token, and userinfo URLs from the
# provider's `out.endpoints`, PKCE, `oidc.scopes`, and `oidc.autoLogin`,
# and refuses those keys in `settings` and `env`. Map roles with
# `settings."auth.generic_oauth".role_attribute_path`, a JMESPath over the
# token claims (Keycloak puts realm roles under `realm_access.roles`).
# The browser opens the public authorization URL. Grafana's server dials the
# token and userinfo URLs, which keycloak gives as its Service address, so
# Grafana gets derived egress to Keycloak and needs no route to its public
# URL. clusters/test-keycloak-oidc.nix evaluates this wiring.
#
#   grafana = {
#     package = packages.grafana;
#     config.ingress.host = "grafana.example.com";
#     config.oidc = {
#       enabled = true;
#       realm = "main";
#     };
#     config.settings."auth.generic_oauth".role_attribute_path =
#       "contains(realm_access.roles[*], 'admin') && 'Admin' || 'Viewer'";
#     deps.oidcProvider = ref.auth.keycloak;
#     deps.oidcClient = ref.monitoring-system.grafana-oidc;
#   };
#
# `out`: the Service's `name`, `fqdn`, and `port` (80).
#
# Escape hatches: `settings` for grafana.ini, `env`, `datasources`, and the
# instance's `partsOverlays` for mounts, placement, and the pod's
# securityContext.
#
# Limits: one pod (`availability.max = "none"` on the Deployment). The
# package wires no alerting HA (ha_peers or ha_redis_address), and the
# default SQLite database and data claim take one writer.

{
  scope,
  lib,
  kix,
}:
let
  release = "13.1.1";
  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "grafana ${ns}/${name}";

  httpPort = 3000;

  # Where the image keeps its data, plugins, and provisioning files. The
  # mounts below depend on them, so the package owns them.
  paths = {
    GF_PATHS_DATA = "/var/lib/grafana/";
    GF_PATHS_LOGS = "/var/log/grafana";
    GF_PATHS_PLUGINS = "/var/lib/grafana/plugins";
    GF_PATHS_PROVISIONING = "/etc/grafana/provisioning";
  };

  # The display name and uid of one wired datasource.
  autoDatasourceOption =
    kind: dep: defaultName: defaultUid:
    lib.mkOption {
      type = lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            default = defaultName;
            description = "Display name in the datasource picker.";
          };
          uid = lib.mkOption {
            type = lib.types.str;
            default = defaultUid;
            description = "Stable identifier that dashboards refer to.";
          };
        };
      };
      default = { };
      description = "Name and uid of the ${kind} datasource wired from the `${dep}` dependency.";
    };

  iniValue = lib.types.nullOr (
    lib.types.oneOf [
      lib.types.bool
      lib.types.int
      lib.types.float
      lib.types.str
    ]
  );

  sidecarOptions = kind: label: searchNamespace: {
    enabled = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run the k8s-sidecar container that loads ${kind} from labelled ConfigMaps or Secrets.";
    };
    searchNamespace = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = searchNamespace;
      description = "Namespace the sidecar searches (k8s-sidecar's NAMESPACE): `ALL` or one namespace name. Null leaves NAMESPACE unset, so the sidecar searches Grafana's own namespace.";
    };
    label = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = label;
      description = "Label key that marks a ConfigMap or Secret as holding ${kind}.";
    };
    labelValue = lib.mkOption {
      type = lib.types.str;
      default = "1";
      description = "Value of `label` that the sidecar matches.";
    };
  };
in
{
  meta = {
    version = release;
    description = "Grafana: observability and data visualization";
    owner = "platform";
    defaultAliases = [ "grafana" ];
    k8s.minVersion = "1.25";
    # With `initChownData.enabled`, init-chown-data runs as root to hand the
    # data volume to uid 472. Off by default; the grafana container itself
    # always runs as 472.
    unsafe = [ "run-as-root" ];
  };

  assertions =
    { config, ... }:
    [
      {
        assertion =
          !(config.sidecar.dashboards.enabled || config.sidecar.datasources.enabled)
          || config.sidecar.sources.configMaps
          || config.sidecar.sources.secrets;
        message = "the sidecars are on but `sidecar.sources` turns off both ConfigMaps and Secrets, so they have nothing to read.";
      }
    ];

  options = {
    image = kix.options.image {
      repository = "docker.io/grafana/grafana";
      tag = release;
      digest = "sha256:7cb8c64c4d57a57e734073f3cc94620adb24a0acb929bd80ba9f14017e3a975b";
    };
    resources = kix.options.resources {
      requests = {
        cpu = "100m";
        memory = "128Mi";
      };
      limits = {
        cpu = "1";
        memory = "1Gi";
      };
    };
    settings = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf iniValue);
      default = { };
      example = {
        server.root_url = "https://grafana.example.com";
        "auth.generic_oauth" = {
          enabled = true;
          client_id = "grafana";
        };
      };
      description = ''
        grafana.ini, as sections of keys, merged over the package's. The
        package sets `analytics.reporting_enabled`,
        `analytics.check_for_updates`, `analytics.check_for_plugin_updates`,
        `plugins.public_key_retrieval_disabled`, `plugins.preinstall_disabled`,
        and `news.news_feed_enabled` so that Grafana does not call
        grafana.com, `log.mode = "console"`, the data proxy's timeouts, and
        `server.root_url` from the route. A null value removes a key. The
        package refuses the `paths` section, `server.http_port`, and
        `security.admin_user` and `security.admin_password`, which the
        mounts, the Service, and the grafanaAdmin dependency decide. Take a
        credential from the environment (`env` with a `secretKeyRef`) or
        from a file Grafana reads (`$__file{...}`) rather than writing it
        here: the file lands in a ConfigMap.
      '';
    };
    env = kix.options.env // {
      description = "Extra environment variables for Grafana, such as `GF_<SECTION>_<KEY>` settings: a string, a `fieldRef` source, or a `secretKeyRef` source naming a Secret managed outside Kix with `kix.untrackedRef`. The `GF_PATHS_*` variables and the administrator's login, which the grafanaAdmin dependency gives, are refused.";
    };
    sidecar = {
      image = kix.options.image {
        repository = "quay.io/kiwigrid/k8s-sidecar";
        tag = "2.8.1";
        digest = "sha256:abb55b2165c60e8f97e473862c7a3123df6f67d44f592949577c29b8fb2df9d6";
        description = "Image for the k8s-sidecar containers that load dashboards and datasources from labelled ConfigMaps and Secrets.";
      };
      # k8s-sidecar 2.8.1 documents no requests; these hold the two Python
      # watchers on kind.
      resources = kix.options.resources {
        requests = {
          cpu = "50m";
          memory = "50Mi";
        };
        limits = {
          cpu = "100m";
          memory = "100Mi";
        };
        description = "Resources for each k8s-sidecar container.";
      };
      # Reading Secrets means watching every Secret in the cluster, so a
      # Grafana that is broken into exposes all of them.
      sources = {
        configMaps = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "When true, the sidecars load dashboards and datasources from ConfigMaps labelled as `sidecar.dashboards` and `sidecar.datasources` say, within seconds of a change. Grafana gets read access to every ConfigMap in the cluster, whatever `searchNamespace` says.";
        };
        secrets = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "When true, the sidecars also load dashboards and datasources from Secrets with the same labels. Grafana gets read access to every Secret in the cluster, so anyone who breaks into Grafana can read all of them. Turn it on only if a datasource definition has to hold a credential and cannot take it from Grafana's environment.";
        };
      };
      dashboards = sidecarOptions "dashboards" "grafana_dashboard" "ALL";
      datasources = sidecarOptions "datasources" "grafana_datasource" null;
    };
    initChownData = {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Run a root init container that chowns /var/lib/grafana to 472:472
          before Grafana starts. Only for a volume whose driver ignores
          `fsGroup`; everywhere else the pod's `fsGroup` already gives
          Grafana the volume. The container carries DAC_READ_SEARCH as well
          as CHOWN, because Grafana creates directories with mode 0700 and
          root needs it to read inside them on the next start.
        '';
      };
      image = kix.options.image {
        repository = "docker.io/library/busybox";
        tag = "1.38.0";
        digest = "sha256:fd7dc98638c8e305f4dc34e979f1c0fdfdcaeb0fbf8fcff77ae834b6da3d7e6e";
        description = "Image of the init-chown-data container. It runs `chown -R`.";
      };
    };
    # Rename the Prometheus one when VictoriaMetrics answers the alias, so
    # the picker says what it is. Keep the uid, so dashboards still find it.
    # To rename a datasource an existing Grafana already has, also list its
    # old name in `deleteDatasources`.
    prometheusDatasource =
      autoDatasourceOption "Prometheus" "prometheusServer" "Prometheus"
        "prometheus";
    alertmanagerDatasource =
      autoDatasourceOption "Alertmanager" "alertmanager" "Alertmanager"
        "alertmanager";
    lokiDatasource = autoDatasourceOption "Loki" "loki" "Loki" "loki";
    tempoDatasource = autoDatasourceOption "Tempo" "tempo" "Tempo" "tempo";
    datasources = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          freeformType = lib.types.attrsOf lib.types.anything;
          options = {
            name = lib.mkOption {
              type = lib.types.nonEmptyStr;
              description = "Display name in the datasource picker.";
            };
            type = lib.mkOption {
              type = lib.types.nonEmptyStr;
              description = "Datasource plugin id, such as `prometheus`, `loki`, or `postgres`.";
            };
          };
        }
      );
      default = [ ];
      example = [
        {
          name = "Pyroscope";
          type = "grafana-pyroscope-datasource";
          uid = "pyroscope";
          url = "https://pyroscope.example.com";
          access = "proxy";
        }
      ];
      description = "Datasources provisioned after the wired ones, in Grafana's provisioning format. The package does not read their URLs, so under default deny Grafana gets no egress to them; add a policy that allows it. They land in a ConfigMap, so a `secureJsonData` value (and the older `password` and `basicAuthPassword`) must be a reference that Grafana expands, such as `$DS_TOKEN` with `DS_TOKEN` in `env`, or `$__file{<path>}`; a literal is refused.";
    };
    deleteDatasources = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption { type = lib.types.str; };
            orgId = lib.mkOption {
              type = lib.types.int;
              default = 1;
            };
          };
        }
      );
      default = [ ];
      example = [ { name = "Prometheus"; } ];
      description = ''
        Datasources Grafana deletes from its database, by name, before it
        provisions the ones above. Grafana matches a provisioned datasource
        by name, so a renamed one looks new, and adding it fails while the
        old entry still holds its uid ("data source with the same uid
        already exists"). List the old name here to rename one. Deleting a
        name that does not exist does nothing, so the entry can stay.
      '';
    };
    ingress = kix.options.ingress // {
      host = kix.options.ingress.host // {
        description = "Public hostname of Grafana's route. Null means no route: Grafana does not take `<instance>.<cluster.domain>`, because the route also serves its unauthenticated /metrics.";
      };
    };
    metrics = kix.options.monitor;
    oidc = kix.options.oidc {
      scopes = [
        "openid"
        "profile"
        "email"
      ];
      autoLogin = "`auth.generic_oauth.auto_login`";
    };
  };

  deps.oidcProvider.assertions = dep: kix.contracts.oidcProvider.assertions who dep;

  build = [
    (
      {
        self,
        config,
        grafanaAdmin,
        storage ? null,
        prometheusServer ? null,
        alertmanager ? null,
        loki ? null,
        tempo ? null,
        oidcProvider ? null,
        oidcClient ? null,
        ...
      }:
      let
        oidcOn = config.oidc.enabled;
        oidcProviderInfo = kix.contracts.oidcProvider.requireClient {
          inherit who;
          inherit (config) oidc;
          provider = oidcProvider;
          client = oidcClient;
        };
        # Forcing oidcProviderInfo first reports a missing dependency by
        # name rather than as a missing attribute of null.
        oidcCredentials = builtins.seq oidcProviderInfo (
          kix.checkSecretKeys {
            inherit who;
            arg = "oidcClient";
            dep = oidcClient;
            keys = kix.contracts.oidcProvider.clientKeys;
          }
        );

        admin = kix.checkSecretKeys {
          inherit who;
          arg = "grafanaAdmin";
          dep = grafanaAdmin;
          keys = [
            "admin-user"
            "admin-password"
          ];
        };
        adminUser = admin.out.keyRef "admin-user";
        adminPassword = admin.out.keyRef "admin-password";

        sidecarResource =
          if config.sidecar.sources.configMaps && config.sidecar.sources.secrets then
            "both"
          else if config.sidecar.sources.secrets then
            "secret"
          else
            "configmap";

        dashboardsOn = config.sidecar.dashboards.enabled;
        datasourcesOn = config.sidecar.datasources.enabled;

        # Wired datasources from DI.
        wiredDatasources =
          lib.optional (prometheusServer != null) {
            inherit (config.prometheusDatasource) name uid;
            type = "prometheus";
            url =
              prometheusServer.out.serviceUrl
                or (throw "${who}: deps.prometheusServer resolved to an instance without out.serviceUrl, the base URL of the Prometheus HTTP API. Wire a prometheus instance, or set out.serviceUrl in the kix.mkImport that answers prometheusServer.");
            access = "proxy";
            isDefault = true;
            jsonData.httpMethod = "POST";
          }
          ++ lib.optional (alertmanager != null) {
            inherit (config.alertmanagerDatasource) name uid;
            type = "alertmanager";
            url =
              alertmanager.out.serviceUrl
                or (throw "${who}: deps.alertmanager resolved to an instance without out.serviceUrl, the base URL of Alertmanager's API. Wire an alertmanager instance, or set out.serviceUrl in the kix.mkImport that answers alertmanager.");
            access = "proxy";
            jsonData = {
              handleGrafanaManagedAlerts = false;
              implementation = "prometheus";
            };
          }
          ++ lib.optional (loki != null) {
            inherit (config.lokiDatasource) name uid;
            type = "loki";
            url =
              loki.out.serviceUrl
                or (throw "${who}: deps.loki resolved to an instance without out.serviceUrl, the base URL of Loki's HTTP API. Wire a loki instance, or set out.serviceUrl in the kix.mkImport that answers loki.");
            access = "proxy";
          }
          ++ lib.optional (tempo != null) {
            inherit (config.tempoDatasource) name uid;
            type = "tempo";
            url =
              tempo.out.queryUrl
                or (throw "${who}: deps.tempo resolved to an instance without out.queryUrl, the base URL of Tempo's query API. Wire a tempo instance, or set out.queryUrl in the kix.mkImport that answers tempo.");
            access = "proxy";
            jsonData =
              # The service graph queries the series Tempo's metrics
              # generator writes there when enabled; without them the graph
              # is empty.
              lib.optionalAttrs (prometheusServer != null) {
                serviceMap.datasourceUid = config.prometheusDatasource.uid;
              }
              # A span's "Logs for this span" link queries Loki for the
              # trace ID within the span's pod. OpenTelemetry's k8s
              # attributes map to the stream labels loki-logs writes; a span
              # without them gets no link.
              // lib.optionalAttrs (loki != null) {
                tracesToLogsV2 = {
                  datasourceUid = config.lokiDatasource.uid;
                  filterByTraceID = true;
                  tags = [
                    {
                      key = "k8s.namespace.name";
                      value = "namespace";
                    }
                    {
                      key = "k8s.pod.name";
                      value = "pod";
                    }
                  ];
                };
              };
          };

        clashes =
          field:
          let
            wired = map (d: d.${field}) wiredDatasources;
          in
          builtins.filter (v: builtins.elem v wired) (
            builtins.filter (v: v != null) (map (d: d.${field} or null) config.datasources)
          );
        clashing = clashes "name" ++ clashes "uid";

        # The datasources ConfigMap is not secret. Grafana expands $VAR,
        # ${VAR}, $__env{VAR}, and $__file{path} in provisioning files, so a
        # credential is written as one of those references.
        inlineSecrets = lib.concatMap (
          d:
          let
            where = "datasources \"${d.name}\"";
            literal = v: builtins.isString v && !(lib.hasInfix "$" v);
          in
          lib.mapAttrsToList (k: _: "${where} secureJsonData.${k}") (
            lib.filterAttrs (_: literal) (d.secureJsonData or { })
          )
          ++ map (k: "${where} ${k}") (
            builtins.filter (k: literal (d.${k} or null)) [
              "password"
              "basicAuthPassword"
            ]
          )
        ) config.datasources;

        # Only the option description warns that the URLs in
        # config.datasources get no egress under default deny. A candidate
        # for an evaluation error while network policy is on.
        datasources =
          if inlineSecrets != [ ] then
            throw "${who}: ${lib.concatStringsSep ", " inlineSecrets} holds a value written inline, and the datasources ConfigMap would carry it. Write a reference that Grafana expands: $NAME with NAME in `env` from a secretKeyRef, or $__file{<path>} for a mounted file, and put it under secureJsonData."
          else if clashing != [ ] then
            throw "${who}: datasources reuses ${
              lib.concatMapStringsSep ", " (v: "\"${v}\"") clashing
            }, the name or uid of a datasource wired from a dependency. Rename the entry, or change prometheusDatasource, alertmanagerDatasource, lokiDatasource, or tempoDatasource."
          else
            wiredDatasources ++ map (lib.filterAttrs (_: v: v != null)) config.datasources;

        # grafana.ini. Booleans render as `true`/`false`: Grafana reads an
        # empty value as the setting's default, so `toString false` would
        # be lost.
        rootUrl = if self.exposure.via == null then null else self.exposure.url;
        defaultIni = {
          analytics = {
            reporting_enabled = false;
            check_for_updates = false;
            check_for_plugin_updates = false;
          };
          plugins = {
            public_key_retrieval_disabled = true;
            preinstall_disabled = true;
          };
          news.news_feed_enabled = false;
          dataproxy = {
            keep_alive_seconds = 600;
            timeout = 600;
          };
          log.mode = "console";
        }
        // lib.optionalAttrs (rootUrl != null) { server.root_url = rootUrl; }
        // lib.optionalAttrs oidcOn {
          "auth.generic_oauth" =
            let
              e = oidcProviderInfo.endpoints;
            in
            {
              enabled = true;
              auth_url = e.authorizationUrl;
              token_url = e.tokenUrl;
              api_url = e.userinfoUrl;
              scopes = lib.concatStringsSep " " config.oidc.scopes;
              use_pkce = true;
              auto_login = config.oidc.autoLogin;
            };
        };

        # The keys the oidc option and the oidcClient dependency own while
        # oidc.enabled is set. Grafana reads GF_<SECTION>_<KEY> over
        # grafana.ini, so env is locked for them too.
        oidcKeys = [
          "enabled"
          "client_id"
          "client_secret"
          "auth_url"
          "token_url"
          "api_url"
          "scopes"
          "use_pkce"
          "auto_login"
        ];

        ini = lib.mapAttrs (_: lib.filterAttrs (_: v: v != null)) (
          kix.mergeGuarded {
            inherit who;
            what = "settings";
            locked = [
              [ "paths" ]
              [
                "server"
                "http_port"
              ]
              [
                "security"
                "admin_user"
              ]
              [
                "security"
                "admin_password"
              ]
            ]
            ++ lib.optionals oidcOn (
              map (k: [
                "auth.generic_oauth"
                k
              ]) oidcKeys
            );
          } defaultIni config.settings
        );

        # The redirect URI Grafana sends the provider is built from root_url.
        oidcRootUrlCheck =
          if oidcOn && (ini.server.root_url or null) == null then
            throw "${who}: oidc.enabled is true, but Grafana has no root_url, from which it builds the redirect URI <root_url>/login/generic_oauth. Set ingress.host with an ingress controller or a gateway in the cluster, or set settings.server.root_url to the URL users open."
          else
            null;

        renderIniValue = v: if builtins.isBool v then lib.boolToString v else toString v;

        # grafana.ini is line-based: a line break in a value, or `]` in a
        # section name or `=` in a key, would start a new section or key
        # past the locks above.
        hasLineBreak = v: lib.hasInfix "\n" v || lib.hasInfix "\r" v;
        iniProblems = lib.concatLists (
          lib.mapAttrsToList (
            section: keys:
            lib.optional (
              hasLineBreak section || lib.hasInfix "]" section
            ) "section name ${builtins.toJSON section}"
            ++ lib.concatLists (
              lib.mapAttrsToList (
                k: v:
                lib.optional (hasLineBreak k || lib.hasInfix "=" k) "key ${builtins.toJSON "${section}.${k}"}"
                ++ lib.optional (hasLineBreak (renderIniValue v)) "the value of ${section}.${k}"
              ) keys
            )
          ) ini
        );
        iniText =
          if oidcRootUrlCheck != null then
            oidcRootUrlCheck
          else if iniProblems != [ ] then
            throw "${who}: settings: ${lib.concatStringsSep ", " iniProblems} would break a grafana.ini line, so the file would carry sections or keys that settings does not show. Keep values on one line, and leave line breaks and `]` out of section names and line breaks and `=` out of keys."
          else
            lib.concatStringsSep "\n" (
              lib.mapAttrsToList (
                section: keys:
                "[${section}]\n"
                + lib.concatStrings (lib.mapAttrsToList (k: v: "${k} = ${renderIniValue v}\n") keys)
              ) ini
            );

        env = kix.mkEnvVars (
          kix.mergeEnv {
            inherit who;
            owned = [
              {
                vars = paths;
                from = "the package, which mounts the data, plugins, and provisioning directories there";
                fix = "Remove it from env.";
              }
              {
                vars = {
                  GF_SECURITY_ADMIN_USER = adminUser;
                  GF_SECURITY_ADMIN_PASSWORD = adminPassword;
                };
                names = [
                  "GF_SECURITY_ADMIN_USER__FILE"
                  "GF_SECURITY_ADMIN_PASSWORD__FILE"
                ];
                from = "the grafanaAdmin dependency";
                fix = "Wire a different secret through deps.grafanaAdmin instead.";
              }
              {
                vars.GF_SERVER_HTTP_PORT = toString httpPort;
                from = "the package, so the Service and probes match the container";
                fix = "Remove it from env.";
              }
            ]
            ++ lib.optional oidcOn {
              vars = {
                GF_AUTH_GENERIC_OAUTH_CLIENT_ID = oidcCredentials.out.keyRef "clientId";
                GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET = oidcCredentials.out.keyRef "clientSecret";
              };
              names =
                map (k: "GF_AUTH_GENERIC_OAUTH_${lib.toUpper k}") (
                  lib.subtractLists [ "client_id" "client_secret" ] oidcKeys
                )
                ++ [
                  "GF_AUTH_GENERIC_OAUTH_CLIENT_ID__FILE"
                  "GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET__FILE"
                ];
              from = "the oidc option and the oidcClient dependency";
              fix = "Set the oidc option, or wire another secret through deps.oidcClient.";
            };
          } config.env
        );

        securityContext = {
          allowPrivilegeEscalation = false;
          capabilities.drop = [ "ALL" ];
          readOnlyRootFilesystem = true;
          seccompProfile.type = "RuntimeDefault";
        };

        # Only with `initChownData.enabled`; see the option.
        initChownContainer = {
          name = "init-chown-data";
          image = kix.image.ref config.initChownData.image;
          imagePullPolicy = config.initChownData.image.pullPolicy;
          command = [
            "chown"
            "-R"
            "472:472"
            paths.GF_PATHS_DATA
          ];
          resources = {
            requests = {
              cpu = "100m";
              memory = "128Mi";
            };
            limits = {
              cpu = "100m";
              memory = "128Mi";
            };
          };
          # chown writes only to the mounted volume.
          securityContext = {
            runAsNonRoot = false;
            runAsUser = 0;
            readOnlyRootFilesystem = true;
            capabilities = {
              add = [
                "CHOWN"
                "DAC_READ_SEARCH"
              ];
              drop = [ "ALL" ];
            };
            seccompProfile.type = "RuntimeDefault";
          };
          volumeMounts = [
            {
              name = "storage";
              mountPath = paths.GF_PATHS_DATA;
            }
          ];
        };

        # k8s-sidecar serves /healthz on HEALTH_PORT (default 8080): 503 until
        # the first sync completes, and again if the watchers die or the
        # Kubernetes API has not answered for 60s. The sidecars share the pod
        # network, so each needs its own port. On kind, under the 100m CPU
        # limit, a sidecar took longer than 35s to open the port; the
        # startupProbe holds liveness off for up to five minutes.
        sidecar =
          {
            container,
            healthPort,
            folder,
            reloadPath,
            options,
          }:
          let
            healthz = {
              httpGet = {
                path = "/healthz";
                port = healthPort;
              };
            };
          in
          {
            name = container;
            image = kix.image.ref config.sidecar.image;
            imagePullPolicy = config.sidecar.image.pullPolicy;
            env = kix.mkEnvVars {
              FOLDER = folder;
              LABEL = options.label;
              LABEL_VALUE = options.labelValue;
              METHOD = "WATCH";
              NAMESPACE = options.searchNamespace;
              REQ_METHOD = "POST";
              REQ_URL = "http://localhost:${toString httpPort}${reloadPath}";
              REQ_USERNAME = adminUser;
              REQ_PASSWORD = adminPassword;
              RESOURCE = sidecarResource;
              HEALTH_PORT = toString healthPort;
            };
            resources = config.sidecar.resources;
            inherit securityContext;
            volumeMounts = [
              {
                name = container;
                mountPath = folder;
              }
            ];
            startupProbe = healthz // {
              initialDelaySeconds = 5;
              periodSeconds = 5;
              failureThreshold = 60;
            };
            readinessProbe = healthz // {
              initialDelaySeconds = 20;
              periodSeconds = 5;
            };
            livenessProbe = healthz // {
              initialDelaySeconds = 35;
              periodSeconds = 10;
            };
          };

        dashboardFolder = "/tmp/dashboards";
        datasourceFolder = "${paths.GF_PATHS_PROVISIONING}/datasources";

        sidecars =
          lib.optional dashboardsOn (sidecar {
            container = "grafana-sc-dashboard";
            healthPort = 8084;
            folder = dashboardFolder;
            reloadPath = "/api/admin/provisioning/dashboards/reload";
            options = config.sidecar.dashboards;
          })
          ++ lib.optional datasourcesOn (sidecar {
            container = "grafana-sc-datasources";
            healthPort = 8082;
            folder = datasourceFolder;
            reloadPath = "/api/admin/provisioning/datasources/reload";
            options = config.sidecar.datasources;
          });

        inherit (scope.rbac) core grant watch;

        storageVolume =
          if storage != null then
            {
              name = "storage";
            }
            // (kix.mount.pvc storage { mountPath = paths.GF_PATHS_DATA; }).source
          else
            {
              name = "storage";
              emptyDir = { };
            };

        httpProbe = {
          httpGet = {
            path = "/api/health";
            port = "grafana";
          };
        };
      in
      {
        serviceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          inherit name;
        };

        # The sidecars watch the kinds in `sidecar.sources` across all
        # namespaces.
        sidecarRbac =
          if dashboardsOn || datasourcesOn then
            scope.rbac.mkClusterRoleSet scope {
              labels = scope.selectorLabels;
              subjects = [
                {
                  kind = "ServiceAccount";
                  name = self.serviceAccount.out.name;
                  namespace = ns;
                }
              ];
              roles.${name} = grant (
                lib.optional config.sidecar.sources.configMaps (core.configmaps |> watch)
                ++ lib.optional config.sidecar.sources.secrets (core.secrets |> watch)
              );
            }
          else
            null;

        configMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-config";
          extra.data."grafana.ini" = iniText;
        };

        scDashboardProvider =
          if dashboardsOn then
            scope.mkResource {
              apiVersion = "v1";
              kind = "ConfigMap";
              name = "${name}-sc-dashboard-provider";
              extra.data."provider.yaml" = builtins.toJSON {
                apiVersion = 1;
                providers = [
                  {
                    name = "sidecarProvider";
                    orgId = 1;
                    type = "file";
                    disableDeletion = false;
                    allowUiUpdates = false;
                    updateIntervalSeconds = 30;
                    options = {
                      foldersFromFilesStructure = false;
                      path = dashboardFolder;
                    };
                  }
                ];
              };
            }
          else
            null;

        # The datasources sidecar loads this ConfigMap by its label; with the
        # sidecar off, the Deployment mounts it.
        datasourcesConfigMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-datasources";
          labels = lib.optionalAttrs datasourcesOn {
            ${config.sidecar.datasources.label} = config.sidecar.datasources.labelValue;
          };
          extra.data."datasources.yaml" = builtins.toJSON (
            {
              apiVersion = 1;
              inherit datasources;
            }
            // lib.optionalAttrs (config.deleteDatasources != [ ]) {
              inherit (config) deleteDatasources;
            }
          );
        };

        deployment = scope.mkDeployment {
          inherit name;
          availability.max = "none";
          spec = {
            replicas = 1;
            selector.matchLabels = scope.selectorLabels;
            # One pod writes the SQLite database and the data claim.
            strategy.type = "Recreate";
            # The datasources reach the pod through the sidecar or a volume,
            # so this annotation carries their Service addresses into the pod
            # spec, which gives Grafana derived egress to each datasource,
            # and restarts the pod when a datasource changes. The others
            # restart it when grafana.ini or the administrator's login
            # changes; Grafana reads both only at start.
            template.metadata.annotations = lib.filterAttrs (_: v: v != null) {
              "checksum/datasources" = self.datasourcesConfigMap.out.identityHash;
              "checksum/config" = self.configMap.out.identityHash;
              "checksum/grafana-admin" = admin.out.identityHash or null;
              "checksum/oidc-client" = if oidcOn then oidcCredentials.out.identityHash or null else null;
            };
            template.spec = {
              serviceAccountName = self.serviceAccount.out.name;
              # Kubernetes' default; Grafana documents no shutdown drain.
              terminationGracePeriodSeconds = 30;
              # `fsGroup` gives Grafana its data volume: the kubelet makes the
              # volume group 472, group-writable and setgid. `OnRootMismatch`
              # limits that to mounts where the top directory is wrong.
              securityContext = {
                runAsNonRoot = true;
                runAsUser = 472;
                runAsGroup = 472;
                fsGroup = 472;
                fsGroupChangePolicy = "OnRootMismatch";
              };
              containers = [
                {
                  name = "grafana";
                  image = kix.image.ref config.image;
                  imagePullPolicy = config.image.pullPolicy;
                  inherit env;
                  ports = [ (kix.port "grafana" httpPort) ];
                  resources = config.resources;
                  # Grafana writes to /var/lib/grafana (storage) and /tmp;
                  # logs go to the console. Grafana 13 installs zipkin and
                  # elasticsearch into the plugins directory at startup and
                  # deletes the copies in plugins-bundled first; on a
                  # read-only root the delete fails and neither plugin
                  # loads, so plugins-bundled is an emptyDir.
                  inherit securityContext;
                  livenessProbe = httpProbe // {
                    initialDelaySeconds = 60;
                    periodSeconds = 10;
                    failureThreshold = 10;
                    timeoutSeconds = 30;
                  };
                  readinessProbe = httpProbe // {
                    periodSeconds = 10;
                    failureThreshold = 3;
                  };
                  volumeMounts = [
                    {
                      name = "tmp";
                      mountPath = "/tmp";
                    }
                    {
                      name = "plugins-bundled";
                      mountPath = "/usr/share/grafana/data/plugins-bundled";
                    }
                    {
                      name = "config";
                      mountPath = "/etc/grafana/grafana.ini";
                      subPath = "grafana.ini";
                    }
                    {
                      name = "storage";
                      mountPath = paths.GF_PATHS_DATA;
                    }
                  ]
                  ++ lib.optionals dashboardsOn [
                    {
                      name = "sc-dashboard-provider";
                      mountPath = "${paths.GF_PATHS_PROVISIONING}/dashboards/sc-dashboardproviders.yaml";
                      subPath = "provider.yaml";
                    }
                    {
                      name = "grafana-sc-dashboard";
                      mountPath = dashboardFolder;
                    }
                  ]
                  ++ [
                    {
                      name = if datasourcesOn then "grafana-sc-datasources" else "datasources";
                      mountPath = datasourceFolder;
                    }
                  ];
                }
              ]
              ++ sidecars;
              volumes = [
                {
                  name = "tmp";
                  emptyDir = { };
                }
                {
                  name = "plugins-bundled";
                  emptyDir = { };
                }
                {
                  name = "config";
                  configMap.name = self.configMap.out.name;
                }
                storageVolume
              ]
              ++ lib.optionals dashboardsOn [
                {
                  name = "sc-dashboard-provider";
                  configMap.name = self.scDashboardProvider.out.name;
                }
                {
                  name = "grafana-sc-dashboard";
                  emptyDir = { };
                }
              ]
              ++ [
                (
                  if datasourcesOn then
                    {
                      name = "grafana-sc-datasources";
                      emptyDir = { };
                    }
                  else
                    {
                      name = "datasources";
                      configMap.name = self.datasourcesConfigMap.out.name;
                    }
                )
              ];
              nodeSelector."kubernetes.io/os" = "linux";
            }
            // lib.optionalAttrs config.initChownData.enabled {
              initContainers = [ initChownContainer ];
            };
          };
        };

        service =
          self.deployment
          |> kix.service.fromWorkload {
            inherit name;
            ports = [
              {
                name = "http-web";
                port = 80;
                targetPort = "grafana";
                protocol = "TCP";
              }
            ];
          }
          |> scope.mkResource;

        root = {
          resource = self.service;
          requires = [
            self.serviceAccount
            self.configMap
            self.datasourcesConfigMap
            self.deployment
          ]
          ++ builtins.filter (p: p != null) [
            self.scDashboardProvider
            self.serviceMonitor
          ];
        };
      }
    )
    # Routed only with an explicit ingress.host; see the header on /metrics.
    (kix.expose {
      service = "service";
      deriveHost = false;
    })
    (kix.monitor {
      service = "service";
      port = "http-web";
    })
  ];
}

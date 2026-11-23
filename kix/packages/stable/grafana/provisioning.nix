# Provisioned datasources and rendered grafana.ini for the grafana package.
{
  lib,
  kix,
  scope,
  fail,
  httpPort,
  paths,
  config,
  self,
  adminUser,
  adminPassword,
  oidcOn,
  oidcProviderInfo,
  oidcCredentials,
  relay,
  prometheusServer,
  alertmanager,
  loki,
  tempo,
}:
let
  wiredDatasources =
    lib.optional (prometheusServer != null) {
      inherit (config.prometheusDatasource) name uid;
      type = "prometheus";
      url =
        prometheusServer.out.serviceUrl or (fail {
          package = "grafana";
          dependency = "prometheusServer";
          message = "deps.prometheusServer resolved to an instance without out.serviceUrl, the base URL of the Prometheus HTTP API.";
          fix = "Wire a prometheus instance, or set out.serviceUrl in the kix.mkImport that answers prometheusServer.";
        });
      access = "proxy";
      isDefault = true;
      jsonData.httpMethod = "POST";
    }
    ++ lib.optional (alertmanager != null) {
      inherit (config.alertmanagerDatasource) name uid;
      type = "alertmanager";
      url =
        alertmanager.out.serviceUrl or (fail {
          package = "grafana";
          dependency = "alertmanager";
          message = "deps.alertmanager resolved to an instance without out.serviceUrl, the base URL of Alertmanager's API.";
          fix = "Wire an alertmanager instance, or set out.serviceUrl in the kix.mkImport that answers alertmanager.";
        });
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
        loki.out.serviceUrl or (fail {
          package = "grafana";
          dependency = "loki";
          message = "deps.loki resolved to an instance without out.serviceUrl, the base URL of Loki's HTTP API.";
          fix = "Wire a loki instance, or set out.serviceUrl in the kix.mkImport that answers loki.";
        });
      access = "proxy";
    }
    ++ lib.optional (tempo != null) {
      inherit (config.tempoDatasource) name uid;
      type = "tempo";
      url =
        tempo.out.queryUrl or (fail {
          package = "grafana";
          dependency = "tempo";
          message = "deps.tempo resolved to an instance without out.queryUrl, the base URL of Tempo's query API.";
          fix = "Wire a tempo instance, or set out.queryUrl in the kix.mkImport that answers tempo.";
        });
      access = "proxy";
      jsonData =
        lib.optionalAttrs (prometheusServer != null) {
          serviceMap.datasourceUid = config.prometheusDatasource.uid;
        }
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

  # Grafana expands $VAR, ${VAR}, $__env{VAR}, and $__file{path} in
  # provisioning files, so credentials must be written as references rather
  # than literals in the datasources ConfigMap.
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

  datasources =
    if inlineSecrets != [ ] then
      fail {
        package = "grafana";
        option = "datasources";
        message = "${lib.concatStringsSep ", " inlineSecrets} holds a value written inline, and the datasources ConfigMap would carry it.";
        fix = "Write a reference that Grafana expands: $NAME with NAME in `env` from a secretKeyRef, or $__file{<path>} for a mounted file, and put it under secureJsonData.";
      }
    else if clashing != [ ] then
      fail {
        package = "grafana";
        option = "datasources";
        message = "datasources reuses ${
          lib.concatMapStringsSep ", " (v: "\"${v}\"") clashing
        }, the name or uid of a datasource wired from a dependency.";
        fix = "Rename the entry, or change prometheusDatasource, alertmanagerDatasource, lokiDatasource, or tempoDatasource.";
      }
    else
      wiredDatasources ++ map (lib.filterAttrs (_: v: v != null)) config.datasources;

  # Booleans render as `true`/`false`: Grafana reads an empty value as the
  # setting's default, so `toString false` would be lost.
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
  # Grafana's mailer picks implicit TLS from port 465 alone, which the
  # package checks. MandatoryStartTLS refuses a server that does not offer
  # STARTTLS.
  // lib.optionalAttrs (relay != null) {
    smtp = {
      enabled = true;
      host = "${relay.host}:${relay.port}";
      from_address = relay.from;
      startTLS_policy = if relay.tls == "none" then "NoStartTLS" else "MandatoryStartTLS";
    };
  }
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

  # Grafana reads GF_<SECTION>_<KEY> over grafana.ini, so `env` is locked for
  # OIDC keys too while `oidc` is wired.
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

  smtpKeys = [
    "enabled"
    "host"
    "from_address"
    "startTLS_policy"
    "user"
    "password"
  ];

  ini = lib.mapAttrs (_: lib.filterAttrs (_: v: v != null)) (
    kix.mergeGuarded {
      inherit scope;
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
      )
      ++ lib.optionals (relay != null) (
        map (k: [
          "smtp"
          k
        ]) smtpKeys
      );
    } defaultIni config.settings
  );

  oidcRootUrlCheck =
    if oidcOn && (ini.server.root_url or null) == null then
      fail {
        package = "grafana";
        option = "settings.server.root_url";
        message = "deps.oidc is wired, but Grafana has no root_url, from which it builds the redirect URI <root_url>/login/generic_oauth.";
        fix = "Set ingress.host with an ingress controller or a gateway in the cluster, or set settings.server.root_url to the URL users open.";
      }
    else
      null;

  renderIniValue = v: if builtins.isBool v then lib.boolToString v else toString v;

  # Reject characters that would inject a new INI section or key past the
  # guarded merge above.
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
      fail {
        package = "grafana";
        option = "settings";
        message = "settings: ${lib.concatStringsSep ", " iniProblems} would break a grafana.ini line, so the file would carry sections or keys that settings does not show.";
        fix = "Keep values on one line, and leave line breaks and `]` out of section names and line breaks and `=` out of keys.";
      }
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
      inherit scope;
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
        from = "the oidc option and the oidc dependency";
        fix = "Set the oidc option, or wire another client through deps.oidc.";
      }
      ++ lib.optional (relay != null) {
        vars = lib.optionalAttrs (relay.credentials != null) {
          GF_SMTP_USER = relay.credentials.out.keyRef "username";
          GF_SMTP_PASSWORD = relay.credentials.out.keyRef "password";
        };
        names = map (k: "GF_SMTP_${lib.toUpper k}") smtpKeys ++ [
          "GF_SMTP_USER__FILE"
          "GF_SMTP_PASSWORD__FILE"
        ];
        from = "the smtp dependency";
        fix = "Wire another SMTP instance through deps.smtp, or set mail.from.";
      };
    } config.env
  );
in
{
  inherit datasources iniText env;
}

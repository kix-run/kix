# Harbor core (API server, auth, and project management) and portal (web UI).

{
  self,
  config,
  scope,
  lib,
  kix,
  database,
  valkey,
  harborSecrets,
  caBundle ? null,
  prometheus ? null,
  reloader ? null,
  oidcProvider ? null,
  oidcClient ? null,
  ...
}:

let
  c = import ./common.nix { inherit lib kix scope; };
  inherit (c)
    name
    who
    metricsPort
    registryUser
    svc
    ;
  b = c.forBuild {
    inherit
      self
      config
      database
      valkey
      harborSecrets
      caBundle
      prometheus
      reloader
      ;
  };
  inherit (b)
    metricsEnabled
    secrets
    ca
    dbCredentials
    valkeySecret
    checksumOf
    reloadOn
    sslmode
    dbPasswordEnv
    coreUrl
    tokenServiceUrl
    portalUrl
    registryUrl
    registryCtlUrl
    jobserviceUrl
    redisUrl
    redisPasswordEnv
    valkeyChecksum
    componentEnv
    componentSelector
    coreSelector
    componentLabels
    containerSecurityContext
    caBundleMount
    tmpMount
    harborPodDefaults
    coreProbe
    portalProbe
    metricsContainerPort
    metricsServicePort
    ;

  oidcOn = config.oidc.enabled;
  oidcProviderInfo = kix.contracts.oidcProvider.requireClient {
    inherit who;
    inherit (config) oidc;
    provider = oidcProvider;
    client = oidcClient;
  };
  # Forcing oidcProviderInfo first reports a missing dependency by
  # name rather than as a missing attribute of null.
  oidcCredentials =
    if oidcOn then
      builtins.seq oidcProviderInfo (
        kix.checkSecretKeys {
          inherit who;
          arg = "oidcClient";
          dep = oidcClient;
          keys = kix.contracts.oidcProvider.clientKeys;
        }
      )
    else
      null;

  # Harbor configuration items for CONFIG_OVERWRITE_JSON. The client
  # id and secret are `$(VAR)` references that Kubernetes expands from
  # the env entries before it, so the JSON in the pod spec holds no
  # credential.
  oidcClientRefs = lib.optionalAttrs oidcOn {
    oidc_client_id = "$(OIDC_CLIENT_ID)";
    oidc_client_secret = "$(OIDC_CLIENT_SECRET)";
  };
  oidcSettings = lib.optionalAttrs oidcOn (
    {
      auth_mode = "oidc_auth";
      oidc_endpoint = oidcProviderInfo.issuerUrl;
      oidc_scope = lib.concatStringsSep "," config.oidc.scopes;
    }
    // lib.optionalAttrs (config.oidc.groupsClaim != null) {
      oidc_groups_claim = config.oidc.groupsClaim;
    }
    // lib.optionalAttrs (config.oidc.adminGroup != null) {
      oidc_admin_group = config.oidc.adminGroup;
    }
  );
  oidcOwnedSettings = [
    "auth_mode"
    "oidc_endpoint"
    "oidc_client_id"
    "oidc_client_secret"
    "oidc_scope"
    "oidc_groups_claim"
    "oidc_admin_group"
  ];
  settingsProblems =
    map
      (
        k:
        "core.settings sets ${k}, a credential that would land in the pod spec. ${
          if k != "oidc_client_secret" then
            "Harbor has no reference form for it; configure it in Harbor's UI without core.settings."
          else if oidcOn then
            "oidc.enabled already sets it from the oidcClient dependency; remove it from core.settings."
          else
            "Set oidc.enabled and wire the client through deps.oidcClient instead."
        }"
      )
      (
        builtins.filter (k: config.core.settings ? ${k}) [
          "oidc_client_secret"
          "ldap_search_password"
        ]
      )
    ++ lib.optionals oidcOn (
      map (
        k:
        "core.settings sets ${k}, which oidc.enabled sets. Use the oidc option and the oidcProvider and oidcClient dependencies instead."
      ) (builtins.filter (k: k != "oidc_client_secret" && config.core.settings ? ${k}) oidcOwnedSettings)
    );
  coreSettings =
    if settingsProblems != [ ] then
      throw "${who}: ${lib.concatStringsSep " " settingsProblems}"
    else
      # Kubernetes expands `$(VAR)` and turns `$$` into `$` across the
      # whole env value, so every `$` except the client references is
      # doubled to reach Harbor as written.
      lib.mapAttrs (_: v: if builtins.isString v then lib.replaceStrings [ "$" ] [ "$$" ] v else v) (
        lib.optionalAttrs oidcOn { oidc_name = "OpenID Connect"; } // config.core.settings // oidcSettings
      )
      // oidcClientRefs;

  # Public URL. Harbor needs one for EXT_ENDPOINT, so it reads
  # `exposure.url`, which throws with the cause when Kix renders no
  # route or cannot tell its scheme.
  externalURL = if config.externalURL != null then config.externalURL else self.exposure.url;

  coreConfigData = {
    EXT_ENDPOINT = externalURL;
    CONFIG_PATH = "/etc/core/app.conf";
    CORE_URL = coreUrl;
    CORE_LOCAL_URL = "http://127.0.0.1:8080";
    JOBSERVICE_URL = jobserviceUrl;
    REGISTRY_URL = registryUrl;
    REGISTRY_CONTROLLER_URL = registryCtlUrl;
    TOKEN_SERVICE_URL = tokenServiceUrl;
    PORTAL_URL = portalUrl;
    REGISTRY_STORAGE_PROVIDER_NAME = "filesystem";
    WITH_TRIVY = "false";
    REGISTRY_CREDENTIAL_USERNAME = registryUser;
    PORT = "8080";
    QUOTA_UPDATE_PROVIDER = "db";
    DATABASE_TYPE = "postgresql";
    POSTGRESQL_HOST = database.out.host;
    POSTGRESQL_PORT = database.out.port;
    POSTGRESQL_USERNAME = database.out.username;
    POSTGRESQL_DATABASE = database.out.database;
    POSTGRESQL_SSLMODE = sslmode;
    CHART_CACHE_DRIVER = "redis";
    "app.conf" = ''
      appname = Harbor
      runmode = prod
      enablegzip = true
      [prod]
      httpport = 8080'';
  }
  // lib.optionalAttrs metricsEnabled {
    METRIC_ENABLE = "true";
    METRIC_NAMESPACE = "harbor";
    METRIC_PATH = "/metrics";
    METRIC_PORT = toString metricsPort;
    METRIC_SUBSYSTEM = "core";
  };
in
{
  coreConfigMap = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = "${name}-core";
    data = coreConfigData;
  };

  # Not fromWorkload: core's own config carries CORE_URL, so a core
  # Service with the core Deployment's context would recurse (core
  # Deployment -> core ConfigMap -> core Service -> core Deployment).
  # The selector is the same literal the Deployment is built from, so
  # they cannot drift; root.requires restores the ordering edge to
  # the core Deployment.
  coreService = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = svc.core;
    labels = componentLabels "core";
    spec = {
      selector = coreSelector;
      ports = [
        {
          name = "http-web";
          port = 80;
          targetPort = 8080;
          protocol = "TCP";
        }
      ]
      ++ metricsServicePort;
    };
    outputs.port = "80";
  };

  coreDeployment =
    {
      name = "${name}-core";
      labels = componentSelector "core";
      spec = {
        replicas = config.core.replicas;
        revisionHistoryLimit = 5;
        selector.matchLabels = coreSelector;
        template.metadata.annotations = {
          "checksum/config" = self.coreConfigMap.out.identityHash;
        }
        // checksumOf "harbor-secrets" secrets
        // checksumOf "ca-bundle" ca
        // checksumOf "database-credentials" dbCredentials
        // valkeyChecksum
        // checksumOf "oidc-client" oidcCredentials;
        template.spec = harborPodDefaults // {
          containers = [
            {
              name = "core";
              image = kix.image.ref config.core.image;
              command = [ "/harbor/harbor_core" ];
              imagePullPolicy = config.core.image.pullPolicy;
              livenessProbe = coreProbe;
              readinessProbe = coreProbe;
              startupProbe = coreProbe // {
                initialDelaySeconds = 10;
                failureThreshold = 360;
              };
              envFrom = [ { configMapRef.name = self.coreConfigMap.out.name; } ];
              env = componentEnv {
                option = "core.env";
                secretEnv =
                  secrets.out.mkEnv {
                    HARBOR_ADMIN_PASSWORD = "adminPassword";
                    CORE_SECRET = "coreSecret";
                    JOBSERVICE_SECRET = "jobserviceSecret";
                    CSRF_KEY = "csrfKey";
                    REGISTRY_CREDENTIAL_PASSWORD = "registryPassword";
                  }
                  ++ dbPasswordEnv "POSTGRESQL_PASSWORD"
                  ++ redisPasswordEnv
                  ++ lib.optionals oidcOn (
                    oidcCredentials.out.mkEnv {
                      OIDC_CLIENT_ID = "clientId";
                      OIDC_CLIENT_SECRET = "clientSecret";
                    }
                  );
                facts = builtins.attrNames coreConfigData;
                sslmodeVar = "POSTGRESQL_SSLMODE";
                vars = {
                  _REDIS_URL_CORE = "${redisUrl 0}?idle_timeout_seconds=30";
                  _REDIS_URL_REG = "${redisUrl 2}?idle_timeout_seconds=30";
                }
                // lib.optionalAttrs (coreSettings != { }) {
                  CONFIG_OVERWRITE_JSON = builtins.toJSON coreSettings;
                };
                owned = [
                  {
                    names = [ "CONFIG_OVERWRITE_JSON" ];
                    from = "core.settings and oidc";
                    fix = "Set the configuration items in core.settings.";
                  }
                ];
                tunables = {
                  LOG_LEVEL = "info";
                  PERMITTED_REGISTRY_TYPES_FOR_PROXY_CACHE = "docker-hub,harbor,azure-acr,ali-acr,aws-ecr,google-gcr,docker-registry,github-ghcr,jfrog-artifactory";
                  REPLICATION_ADAPTER_WHITELIST = "ali-acr,aws-ecr,azure-acr,docker-hub,docker-registry,github-ghcr,google-gcr,harbor,huawei-SWR,jfrog-artifactory,tencent-tcr,volcengine-cr";
                  POSTGRESQL_MAX_IDLE_CONNS = "100";
                  POSTGRESQL_MAX_OPEN_CONNS = "900";
                };
                env = config.core.env;
              };
              ports = [ (kix.port "http" 8080) ] ++ metricsContainerPort;
              resources = config.core.resources;
              securityContext = containerSecurityContext;
            }
          ];
        };
      };
    }
    |> kix.withMounts [
      (kix.mount.configMap self.coreConfigMap {
        name = "config";
        mountPath = "/etc/core/app.conf";
        subPath = "app.conf";
        items = [
          {
            key = "app.conf";
            path = "app.conf";
          }
        ];
      })
      (kix.mount.secret secrets {
        name = "secret-key";
        mountPath = "/etc/core/key";
        subPath = "key";
        items = [
          {
            key = "secretKey";
            path = "key";
          }
        ];
        defaultMode = 420;
      })
      (kix.mount.secret secrets {
        name = "token-service-private-key";
        mountPath = "/etc/core/private_key.pem";
        subPath = "private_key.pem";
        items = [
          {
            key = "tokenPrivateKey";
            path = "private_key.pem";
          }
        ];
        defaultMode = 420;
      })
      (kix.mount.emptyDir {
        name = "ca-download";
        mountPath = "/etc/core/ca";
        sizeLimit = "16Mi";
      })
      (kix.mount.emptyDir {
        name = "psc";
        mountPath = "/etc/core/token";
        sizeLimit = "16Mi";
      })
      (tmpMount "tmp")
      caBundleMount
    ]
    |> reloadOn [
      secrets
      ca
      dbCredentials
      valkeySecret
      oidcCredentials
    ]
    |> scope.mkDeployment;

  portalConfigMap = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = "${name}-portal";
    data = {
      "nginx.conf" = ''
        worker_processes auto;
        pid /tmp/nginx.pid;
        events {
            worker_connections  1024;
        }
        http {
            client_body_temp_path /tmp/client_body_temp;
            proxy_temp_path /tmp/proxy_temp;
            fastcgi_temp_path /tmp/fastcgi_temp;
            uwsgi_temp_path /tmp/uwsgi_temp;
            scgi_temp_path /tmp/scgi_temp;
            server {
                listen 8080;
                listen [::]:8080;
                server_name  localhost;
                root   /usr/share/nginx/html;
                index  index.html index.htm;
                include /etc/nginx/mime.types;
                gzip on;
                gzip_min_length 1000;
                gzip_proxied expired no-cache no-store private auth;
                gzip_types text/plain text/css application/json application/javascript application/x-javascript text/xml application/xml application/xml+rss text/javascript;
                location /devcenter-api-2.0 {
                    try_files $uri $uri/ /swagger-ui-index.html;
                }
                location / {
                    try_files $uri $uri/ /index.html;
                }
                location = /index.html {
                    add_header Cache-Control "no-store, no-cache, must-revalidate";
                }
            }
        }'';
    };
  };

  portalService =
    self.portalDeployment
    |> kix.service.fromWorkload {
      name = svc.portal;
      labels = componentLabels "portal";
      ports = [
        {
          name = "http-web";
          port = 80;
          targetPort = 8080;
          protocol = "TCP";
        }
      ];
      outputs.port = "80";
    }
    |> scope.mkResource;

  portalDeployment =
    {
      name = "${name}-portal";
      labels = componentSelector "portal";
      spec = {
        replicas = config.portal.replicas;
        revisionHistoryLimit = 5;
        selector.matchLabels = componentSelector "portal";
        template.metadata.annotations = {
          "checksum/config" = self.portalConfigMap.out.identityHash;
        };
        template.spec = harborPodDefaults // {
          containers = [
            {
              name = "portal";
              image = kix.image.ref config.portal.image;
              imagePullPolicy = config.portal.image.pullPolicy;
              ports = [ (kix.port "http" 8080) ];
              livenessProbe = portalProbe // {
                initialDelaySeconds = 300;
              };
              readinessProbe = portalProbe // {
                initialDelaySeconds = 1;
              };
              resources = config.portal.resources;
              securityContext = containerSecurityContext;
            }
          ];
        };
      };
    }
    |> kix.withMounts [
      (kix.mount.configMap self.portalConfigMap {
        name = "portal-config";
        mountPath = "/etc/nginx/nginx.conf";
        subPath = "nginx.conf";
      })
      # nginx.conf puts the pid file and every temp path under /tmp.
      (tmpMount "tmp")
    ]
    |> scope.mkDeployment;
}

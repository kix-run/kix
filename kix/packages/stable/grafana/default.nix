# grafana: Grafana with datasources wired from its dependencies and
# k8s-sidecar containers that load dashboards and datasources from labelled
# ConfigMaps.
#
# Installs a Deployment and its ServiceAccount, a Service on port 80, the
# grafana.ini ConfigMap, a datasources ConfigMap, and, when the cluster has
# an ingress controller or a gateway and the instance sets `ingress.host`, a
# route through `kix.expose`. Without `ingress.host` there is no route, even
# on a cluster with `cluster.domain`. Grafana's `root_url` is that route's URL.
#
# Dependencies:
#   grafanaAdmin (required)      Secret with keys `admin-user` and
#                                `admin-password`. The sidecars use it to tell
#                                Grafana to reload. A `secret` change restarts
#                                the pod; a `secret-ref` has no content hash,
#                                so a rotated password takes effect on restart.
#   storage (optional)           Claim for /var/lib/grafana (SQLite database
#                                and plugins). Defaults to an emptyDir.
#   prometheusServer (optional)  Default Prometheus datasource (`out.serviceUrl`).
#   alertmanager (optional)      Alertmanager datasource (`out.serviceUrl`).
#   loki (optional)              Loki datasource (`out.serviceUrl`).
#   tempo (optional)             Tempo datasource (`out.queryUrl`). Links spans
#                                to pod logs when `loki` is wired, and queries
#                                Tempo's service graph series when
#                                `prometheusServer` is wired.
#   prometheus (optional)        ServiceMonitor on `/metrics` when
#                                `metrics.enabled`.
#   oidc (optional)              Single sign-on, through an OpenID Connect
#                                client honouring kix.contracts.oidc: an
#                                oidc-client instance, or a kix.mkImport.
#   smtp (optional)              Mail server for alert notifications,
#                                invitations, and reports, honouring the SMTP
#                                contract (kix.contracts.smtp), usually a
#                                kix.mkImport.
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
# Wired datasources have fixed default uids (`prometheusDatasource`,
# `alertmanagerDatasource`, `lokiDatasource`, and `tempoDatasource`) so
# dashboards can reference them portably. `datasources` adds more; clashing
# names or uids are refused.
#
# The dashboards sidecar watches `grafana_dashboard: "1"` across all
# namespaces; the datasources sidecar watches `grafana_datasource: "1"` in
# Grafana's namespace. Either requires cluster-wide ConfigMap read access (and
# Secret read access when `sidecar.sources.secrets` is enabled). When the
# datasources sidecar is disabled, the datasources ConfigMap is mounted
# directly.
#
# Note on `/metrics`: Grafana serves `/metrics` on its HTTP port without
# authentication, so setting `ingress.host` exposes `/metrics` publicly. Set
# `settings.metrics.enabled = false` and `metrics.enabled = false` to disable
# it on a routed instance.
#
# Single sign-on: with `oidc` wired, Grafana authenticates users via
# `auth.generic_oauth` against that client's issuer and endpoints, reading
# `clientId` and `clientSecret` from its `out.credentials`, with
# `oidc.scopes` and `oidc.autoLogin`. Register a confidential client with redirect URI
# `<root_url>/login/generic_oauth` (requires `root_url`). Role mapping can be
# configured via `settings."auth.generic_oauth".role_attribute_path`.
#
# Mail: with `smtp` wired, the package fills grafana.ini's `[smtp]` section
# (the sender is the server's `out.from`, or `mail.from`) and passes the
# login from its `out.credentials` as GF_SMTP_USER and GF_SMTP_PASSWORD. It refuses
# those keys in `settings` and `env`. Grafana requires STARTTLS
# (MandatoryStartTLS), and uses implicit TLS only on port 465, so an
# implicit-TLS server on another port is refused. A server outside the cluster
# gets egress to any address on its port, because the network policy cannot
# name a host outside the cluster.
#
# `out`: Service `name`, `fqdn`, and `port` (80), and `version`, the Grafana
# version `image.tag` names.
# Limits: single replica (`availability.max = "none"` on the Deployment).

{
  scope,
  lib,
  kix,
}:
let
  release = "13.3.1";
  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "grafana ${ns}/${name}";

  httpPort = 3000;

  paths = {
    GF_PATHS_DATA = "/var/lib/grafana/";
    GF_PATHS_LOGS = "/var/log/grafana";
    GF_PATHS_PLUGINS = "/var/lib/grafana/plugins";
    GF_PATHS_PROVISIONING = "/etc/grafana/provisioning";
  };
in
{
  meta = {
    version = release;
    description = "Grafana: observability and data visualization";
    owner = "platform";
    defaultAliases = [ "grafana" ];
    k8s.minVersion = "1.25";
    # When `initChownData.enabled` is true, init-chown-data runs as root to
    # chown the data volume to uid 472.
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

  options = import ./options.nix {
    inherit lib kix release;
  };

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
        oidc ? null,
        smtp ? null,
        ...
      }:
      let
        relay =
          let
            r = kix.contracts.smtp.helpers.settings {
              inherit who smtp;
              inherit (config.mail) from;
            };
          in
          if r == null then
            null
          else if r.tls == "implicit" && r.portNumber != 465 then
            scope.fail {
              package = "grafana";
              dependency = "smtp";
              message = "deps.smtp uses tls = \"implicit\" on port ${r.port}. Grafana's mailer uses implicit TLS only on port 465, so it would speak plain SMTP to this port.";
              fix = "Use the server's port 465, or its STARTTLS port with tls = \"starttls\".";
            }
          else if r.tls != "implicit" && r.portNumber == 465 then
            scope.fail {
              package = "grafana";
              dependency = "smtp";
              message = "deps.smtp uses tls = \"${r.tls}\" on port 465. Grafana's mailer always uses implicit TLS on port 465.";
              fix = "Set tls = \"implicit\" on the SMTP instance.";
            }
          else
            r;

        oidcProviderInfo = kix.contracts.oidc.helpers.client {
          inherit who oidc;
          options = config.oidc;
        };
        oidcOn = oidcProviderInfo != null;
        oidcCredentials = oidcProviderInfo.credentials;

        admin = kix.contracts.secret.helpers.use {
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

        prov = import ./provisioning.nix {
          fail = scope.fail;
          inherit
            lib
            kix
            who
            httpPort
            paths
            config
            self
            adminUser
            adminPassword
            oidcOn
            oidcProviderInfo
            oidcCredentials
            relay
            prometheusServer
            alertmanager
            loki
            tempo
            ;
        };
        inherit (prov) datasources iniText env;

        securityContext = {
          allowPrivilegeEscalation = false;
          capabilities.drop = [ "ALL" ];
          readOnlyRootFilesystem = true;
          seccompProfile.type = "RuntimeDefault";
        };

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

        # k8s-sidecar serves /healthz on HEALTH_PORT (503 until initial sync
        # completes or when watchers fail). Each sidecar uses a distinct port
        # and a 5-minute startupProbe to allow slow initial syncs under low CPU
        # limits.
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
            strategy.type = "Recreate";
            # Carrying `datasourcesConfigMap.out.contentHash` on the pod
            # template propagates datasource Service facts for derived network
            # policy and restarts the pod when datasources, grafana.ini, or
            # credentials change.
            template.metadata.annotations = lib.filterAttrs (_: v: v != null) {
              "checksum/datasources" = self.datasourcesConfigMap.out.contentHash;
              "checksum/config" = self.configMap.out.contentHash;
              "checksum/grafana-admin" = admin.out.contentHash or null;
              "checksum/oidc-client" = if oidcOn then oidcCredentials.out.contentHash or null else null;
              "checksum/smtp" =
                if relay != null && relay.credentials != null then
                  relay.credentials.out.contentHash or null
                else
                  null;
            };
            template.spec = {
              serviceAccountName = self.serviceAccount.out.name;
              terminationGracePeriodSeconds = 30;
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
                  # Grafana loads its core plugins, such as the Prometheus,
                  # Loki, and Tempo data sources and the canvas panel, from
                  # /usr/share/grafana/data/plugins-bundled in the image. A
                  # volume over that directory hides them.
                  volumeMounts = [
                    {
                      name = "tmp";
                      mountPath = "/tmp";
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

        mailEgress = kix.contracts.smtp.helpers.egressPolicy {
          inherit scope;
          smtp = relay;
          name = "${name}-mail-egress";
          selector = self.deployment.out.selector;
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
          out.version = kix.image.version config.image;
          requires = [
            self.serviceAccount
            self.configMap
            self.datasourcesConfigMap
            self.deployment
          ]
          ++ builtins.filter (p: p != null) [
            self.scDashboardProvider
          ];
        };
      }
    )
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

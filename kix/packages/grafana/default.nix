# grafana — Grafana observability dashboard.
#
# Deployment with optional k8s-sidecar containers for auto-provisioning
# dashboards and datasources from ConfigMaps/Secrets labeled with
# grafana_dashboard=1 / grafana_datasource=1.
#
# DI deps:
#   prometheus ? null       — prometheus-operator, for ServiceMonitor creation
#   prometheusServer ? null — auto-wires Prometheus datasource via out.serviceUrl
#   alertmanager ? null     — auto-wires Alertmanager datasource via out.serviceUrl
#   loki ? null             — auto-wires Loki datasource (if out.serviceUrl exists)
#
# Exposes:
#   out.serviceUrl — "http://<name>.<ns>.svc.cluster.local:80"

{
  scope,
  lib,
  kix,
}:
let
  name = scope.instanceName;
  ns = scope.namespaceName;
in
{
  meta = {
    version = "11.6.1";
    description = "Grafana — observability and data visualization";
    provides = [ "dashboards" ];
    defaultAliases = [ "grafana" ];
    k8s.minVersion = "1.25";
  };

  options = {
    image = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "docker.io/grafana/grafana";
        tag = "11.6.1";
        pullPolicy = "IfNotPresent";
      };
    };
    sidecarImage = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "quay.io/kiwigrid/k8s-sidecar";
        tag = "1.30.0";
        pullPolicy = "IfNotPresent";
      };
    };
    replicas = lib.mkOption {
      type = lib.types.int;
      default = 1;
    };
    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
        requests = {
          cpu = "100m";
          memory = "128Mi";
        };
        limits = {
          cpu = "1";
          memory = "1Gi";
        };
      };
    };
    persistence = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = true;
        size = "10Gi";
        storageClass = null;
      };
    };
    sidecar = lib.mkOption {
      type = lib.types.anything;
      default = {
        dashboards = {
          enabled = true;
          searchNamespace = "ALL";
          label = "grafana_dashboard";
          labelValue = "1";
        };
        datasources = {
          enabled = true;
          label = "grafana_datasource";
          labelValue = "1";
        };
      };
    };
    # grafana.ini overrides merged on top of defaults
    grafanaIni = lib.mkOption {
      type = lib.types.anything;
      default = { };
      description = "Extra grafana.ini sections merged on top of defaults.";
    };
    rootUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Grafana root URL (server.root_url in grafana.ini).";
    };
    adminUser = lib.mkOption {
      type = lib.types.str;
      default = "admin";
    };
    adminPassword = lib.mkOption {
      type = lib.types.str;
      default = "admin";
      description = "Default admin password. Override via secret in production.";
    };
    datasources = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
      description = "Extra datasources appended to auto-discovered ones.";
    };
    dashboardProviders = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
      description = "Extra dashboard providers appended to defaults.";
    };
    securityContext = lib.mkOption {
      type = lib.types.anything;
      default = {
        runAsNonRoot = true;
        runAsUser = 472;
        runAsGroup = 472;
        fsGroup = 472;
      };
    };
    metrics = kix.options.monitor;
  };

  build =
    {
      self,
      config,
      # prometheus-operator — for ServiceMonitor creation (alias: "prometheus")
      prometheus ? null,
      # prometheus server — for datasource URL (alias: "prometheusServer")
      prometheusServer ? null,
      alertmanager ? null,
      loki ? null,
      ...
    }:
    let
      hasMetrics = config.metrics.enabled && prometheus != null;
      mkServiceMonitor = if prometheus != null then prometheus.out.mkServiceMonitor scope else null;

      sidecarImg = "${config.sidecarImage.repository}:${config.sidecarImage.tag}";

      # ── Auto-wired datasources from DI ──────────────────────────────────
      autoDatasources =
        lib.optional (prometheusServer != null) {
          name = "Prometheus";
          type = "prometheus";
          url = prometheusServer.out.serviceUrl;
          access = "proxy";
          isDefault = true;
        }
        ++ lib.optional (alertmanager != null) {
          name = "Alertmanager";
          type = "alertmanager";
          url = alertmanager.out.serviceUrl;
          access = "proxy";
          jsonData.handleGrafanaManagedAlerts = true;
        }
        # Loki wiring: if the loki instance exposes out.serviceUrl, use it.
        # For Helm-wrapped Loki, pass the URL via config.datasources instead.
        ++ lib.optional (loki != null && loki ? out && loki.out ? serviceUrl) {
          name = "Loki";
          type = "loki";
          url = loki.out.serviceUrl;
          access = "proxy";
        };

      allDatasources = autoDatasources ++ config.datasources;

      # ── grafana.ini ─────────────────────────────────────────────────────
      defaultIni = {
        analytics.check_for_updates = true;
        "dataproxy".keep_alive_seconds = 600;
        "dataproxy".timeout = 600;
        log.mode = "console";
        paths = {
          data = "/var/lib/grafana/";
          logs = "/var/log/grafana";
          plugins = "/var/lib/grafana/plugins";
          provisioning = "/etc/grafana/provisioning";
        };
        server = lib.optionalAttrs (config.rootUrl != null) {
          root_url = config.rootUrl;
        };
      };

      mergedIni = lib.recursiveUpdate defaultIni config.grafanaIni;

      # Serialize grafana.ini as INI format
      renderIniSection =
        sectionName: attrs:
        let
          lines = lib.mapAttrsToList (k: v: "${k} = ${toString v}") attrs;
        in
        "[${sectionName}]\n${lib.concatStringsSep "\n" lines}\n";

      grafanaIniStr = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (
          section: value:
          if builtins.isAttrs value then
            renderIniSection section value
          else
            renderIniSection section { "${section}" = value; }
        ) mergedIni
      );

      # ── Dashboard providers ─────────────────────────────────────────────
      defaultProviders = [
        {
          name = "default";
          orgId = 1;
          folder = "default";
          type = "file";
          disableDeletion = false;
          editable = true;
          options.path = "/var/lib/grafana/dashboards/standard";
        }
      ];

      sidecarProvider = {
        name = "sidecarProvider";
        orgId = 1;
        folder = "";
        folderUid = "";
        type = "file";
        disableDeletion = false;
        allowUiUpdates = false;
        updateIntervalSeconds = 30;
        options = {
          foldersFromFilesStructure = false;
          path = "/tmp/dashboards";
        };
      };

      allProviders =
        defaultProviders
        ++ lib.optional config.sidecar.dashboards.enabled sidecarProvider
        ++ config.dashboardProviders;

      dashboardProvidersYaml = builtins.toJSON {
        apiVersion = 1;
        providers = allProviders;
      };

      # ── Sidecar security context ────────────────────────────────────────
      sidecarSecCtx = {
        allowPrivilegeEscalation = false;
        capabilities.drop = [ "ALL" ];
        seccompProfile.type = "RuntimeDefault";
      };

      # ── Sidecar containers ──────────────────────────────────────────────
      dashboardSidecar = lib.optional config.sidecar.dashboards.enabled {
        name = "grafana-sc-dashboard";
        image = sidecarImg;
        imagePullPolicy = config.sidecarImage.pullPolicy;
        env =
          kix.mkEnvVars {
            FOLDER = "/tmp/dashboards";
            LABEL = config.sidecar.dashboards.label;
            LABEL_VALUE = config.sidecar.dashboards.labelValue;
            METHOD = "WATCH";
            NAMESPACE = config.sidecar.dashboards.searchNamespace;
            REQ_METHOD = "POST";
            REQ_URL = "http://localhost:3000/api/admin/provisioning/dashboards/reload";
            RESOURCE = "both";
          }
          ++ [
            {
              name = "REQ_USERNAME";
              valueFrom.secretKeyRef = {
                name = self.secret.out.name;
                key = "admin-user";
              };
            }
            {
              name = "REQ_PASSWORD";
              valueFrom.secretKeyRef = {
                name = self.secret.out.name;
                key = "admin-password";
              };
            }
          ];
        securityContext = sidecarSecCtx;
        volumeMounts = [
          {
            name = "sc-dashboard-volume";
            mountPath = "/tmp/dashboards";
          }
        ];
      };

      datasourceSidecar = lib.optional config.sidecar.datasources.enabled {
        name = "grafana-sc-datasources";
        image = sidecarImg;
        imagePullPolicy = config.sidecarImage.pullPolicy;
        env =
          kix.mkEnvVars {
            FOLDER = "/etc/grafana/provisioning/datasources";
            LABEL = config.sidecar.datasources.label;
            LABEL_VALUE = config.sidecar.datasources.labelValue;
            METHOD = "WATCH";
            REQ_METHOD = "POST";
            REQ_URL = "http://localhost:3000/api/admin/provisioning/datasources/reload";
            RESOURCE = "both";
          }
          ++ [
            {
              name = "REQ_USERNAME";
              valueFrom.secretKeyRef = {
                name = self.secret.out.name;
                key = "admin-user";
              };
            }
            {
              name = "REQ_PASSWORD";
              valueFrom.secretKeyRef = {
                name = self.secret.out.name;
                key = "admin-password";
              };
            }
          ];
        securityContext = sidecarSecCtx;
        volumeMounts = [
          {
            name = "sc-datasources-volume";
            mountPath = "/etc/grafana/provisioning/datasources";
          }
        ];
      };

      # ── RBAC for sidecars ───────────────────────────────────────────────
      # Sidecars need to watch ConfigMaps and Secrets across all namespaces
      needsClusterRbac = config.sidecar.dashboards.enabled || config.sidecar.datasources.enabled;

      inherit (scope.rbac)
        core
        grant
        watch
        mkClusterRoleSet
        ;

      clusterRoles = lib.optionalAttrs needsClusterRbac (
        mkClusterRoleSet scope {
          subjects = [
            {
              kind = "ServiceAccount";
              name = self.serviceAccount.out.name;
              namespace = ns;
            }
          ];
          labels = scope.selectorLabels;
          roles = {
            "${name}" = grant [
              (core.configmaps |> watch)
              (core.secrets |> watch)
            ];
          };
        }
      );

    in
    {
      serviceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        inherit name;
        extra.automountServiceAccountToken = true;
      };

      # ── Config ──────────────────────────────────────────────────────────

      configMap = scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "${name}-config";
        extra.data = {
          "grafana.ini" = grafanaIniStr;
          "dashboardproviders.yaml" = builtins.toJSON {
            apiVersion = 1;
            providers = defaultProviders;
          };
        };
      };

      scDashboardProvider =
        if config.sidecar.dashboards.enabled then
          scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "${name}-sc-dashboard-provider";
            extra.data = {
              "provider.yaml" = builtins.toJSON {
                apiVersion = 1;
                providers = [ sidecarProvider ];
              };
            };
          }
        else
          null;

      datasourcesConfigMap = scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "${name}-datasources";
        extra = {
          metadata.labels = {
            grafana_datasource = "1";
          };
          data = {
            "datasources.yaml" = builtins.toJSON {
              apiVersion = 1;
              datasources = allDatasources;
            };
          };
        };
      };

      secret = scope.mkResource {
        apiVersion = "v1";
        kind = "Secret";
        inherit name;
        extra = {
          type = "Opaque";
          stringData = {
            admin-user = config.adminUser;
            admin-password = config.adminPassword;
          };
        };
      };

      # ── PVC ─────────────────────────────────────────────────────────────

      pvc =
        if config.persistence.enabled then
          scope.mkResource {
            apiVersion = "v1";
            kind = "PersistentVolumeClaim";
            inherit name;
            spec = {
              accessModes = [ "ReadWriteOnce" ];
              resources.requests.storage = config.persistence.size;
            }
            // lib.optionalAttrs (config.persistence.storageClass != null) {
              storageClassName = config.persistence.storageClass;
            };
          }
        else
          null;

      # ── Deployment ──────────────────────────────────────────────────────

      deployment =
        {
          inherit name;
          spec = {
            replicas = config.replicas;
            selector.matchLabels = scope.selectorLabels;
            strategy.type = "Recreate";
            template.spec = {
              serviceAccountName = self.serviceAccount.out.name;
              automountServiceAccountToken = true;
              securityContext = config.securityContext;
              initContainers = [
                {
                  name = "init-chown-data";
                  image = "docker.io/library/busybox:1.37.0";
                  command = [
                    "chown"
                    "-R"
                    "472:472"
                    "/var/lib/grafana"
                  ];
                  securityContext = {
                    runAsNonRoot = false;
                    runAsUser = 0;
                    capabilities = {
                      add = [ "CHOWN" ];
                      drop = [ "ALL" ];
                    };
                    seccompProfile.type = "RuntimeDefault";
                  };
                  volumeMounts = [
                    {
                      name = "storage";
                      mountPath = "/var/lib/grafana";
                    }
                  ];
                }
              ];
              containers = [
                {
                  name = "grafana";
                  image = "${config.image.repository}:${config.image.tag}";
                  imagePullPolicy = config.image.pullPolicy;
                  env = [
                    {
                      name = "GF_PATHS_DATA";
                      value = "/var/lib/grafana/";
                    }
                    {
                      name = "GF_PATHS_LOGS";
                      value = "/var/log/grafana";
                    }
                    {
                      name = "GF_PATHS_PLUGINS";
                      value = "/var/lib/grafana/plugins";
                    }
                    {
                      name = "GF_PATHS_PROVISIONING";
                      value = "/etc/grafana/provisioning";
                    }
                    {
                      name = "GF_SECURITY_ADMIN_USER";
                      valueFrom.secretKeyRef = {
                        name = self.secret.out.name;
                        key = "admin-user";
                      };
                    }
                    {
                      name = "GF_SECURITY_ADMIN_PASSWORD";
                      valueFrom.secretKeyRef = {
                        name = self.secret.out.name;
                        key = "admin-password";
                      };
                    }
                    {
                      name = "POD_IP";
                      valueFrom.fieldRef = {
                        apiVersion = "v1";
                        fieldPath = "status.podIP";
                      };
                    }
                  ];
                  ports = [
                    (kix.port "grafana" 3000)
                  ];
                  resources = config.resources;
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    capabilities.drop = [ "ALL" ];
                    seccompProfile.type = "RuntimeDefault";
                  };
                  livenessProbe = {
                    httpGet = {
                      path = "/api/health";
                      port = 3000;
                    };
                    initialDelaySeconds = 60;
                    periodSeconds = 10;
                    failureThreshold = 10;
                    timeoutSeconds = 30;
                  };
                  readinessProbe = {
                    httpGet = {
                      path = "/api/health";
                      port = 3000;
                    };
                    periodSeconds = 10;
                    failureThreshold = 3;
                    timeoutSeconds = 1;
                  };
                  volumeMounts = [
                    {
                      name = "config";
                      mountPath = "/etc/grafana/grafana.ini";
                      subPath = "grafana.ini";
                    }
                    {
                      name = "config";
                      mountPath = "/etc/grafana/provisioning/dashboards/dashboardproviders.yaml";
                      subPath = "dashboardproviders.yaml";
                    }
                  ]
                  ++ lib.optional config.sidecar.dashboards.enabled {
                    name = "sc-dashboard-provider";
                    mountPath = "/etc/grafana/provisioning/dashboards/sc-dashboardproviders.yaml";
                    subPath = "provider.yaml";
                  }
                  ++ lib.optional config.sidecar.datasources.enabled {
                    name = "sc-datasources-volume";
                    mountPath = "/etc/grafana/provisioning/datasources";
                  }
                  ++ lib.optional config.sidecar.dashboards.enabled {
                    name = "sc-dashboard-volume";
                    mountPath = "/tmp/dashboards";
                  }
                  ++ [
                    {
                      name = "storage";
                      mountPath = "/var/lib/grafana";
                    }
                  ];
                }
              ]
              ++ dashboardSidecar
              ++ datasourceSidecar;
              volumes = [
                {
                  name = "config";
                  configMap.name = self.configMap.out.name;
                }
              ]
              ++ lib.optional (self.scDashboardProvider != null) {
                name = "sc-dashboard-provider";
                configMap.name = self.scDashboardProvider.out.name;
              }
              ++ lib.optional config.sidecar.dashboards.enabled {
                name = "sc-dashboard-volume";
                emptyDir = { };
              }
              ++ lib.optional config.sidecar.datasources.enabled {
                name = "sc-datasources-volume";
                emptyDir = { };
              }
              ++ [
                (
                  if config.persistence.enabled then
                    {
                      name = "storage";
                      persistentVolumeClaim.claimName = self.pvc.out.name;
                    }
                  else
                    {
                      name = "storage";
                      emptyDir = { };
                    }
                )
              ];
              nodeSelector = {
                "kubernetes.io/os" = "linux";
              };
            };
          };
        }
        |> scope.mkDeployment;

      # ── Service ─────────────────────────────────────────────────────────

      service =
        self.deployment
        |> kix.service.fromWorkload {
          inherit name;
          type = "ClusterIP";
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

      # ── Monitoring (optional via DI) ────────────────────────────────────

      serviceMonitor =
        if hasMetrics then
          mkServiceMonitor {
            name = "${name}-monitor";
            spec = {
              selector.matchLabels = self.deployment.out.selector;
              endpoints = [
                {
                  port = "http-web";
                  interval = config.metrics.interval or "30s";
                  path = "/metrics";
                }
              ];
            };
          }
        else
          null;

      root = {
        resource = self.service;
        requires = [
          self.serviceAccount
          self.configMap
          self.datasourcesConfigMap
          self.secret
          self.deployment
        ]
        ++ lib.optional (self.scDashboardProvider != null) self.scDashboardProvider
        ++ lib.optional (self.pvc != null) self.pvc
        ++ lib.optional (self.serviceMonitor != null) self.serviceMonitor;
        out = {
          serviceUrl = "http://${name}.${ns}.svc.cluster.local:80";
        };
      };
    }
    // clusterRoles;
}

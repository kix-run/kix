# External-DNS kix package.
#
# Manages DNS records in external providers (e.g. Cloudflare) by watching
# Kubernetes Ingress and Service resources.
#
# Supports multi-instance deployment: each instance can manage different
# DNS zones via domainFilters (e.g. external-dns-cluster-public for lithus.net,
# external-dns-northwind for shopfront.example).
#
# Resources: ServiceAccount, ClusterRole, ClusterRoleBinding, Deployment,
#            Service (metrics), NetworkPolicy, Secret. Disruption budgets
#            are derived by the compiler from the availability level, not
#            written here.
#
# root = Deployment

{
  scope,
  lib,
  kix,
}:

{
  meta = {
    version = "0.16.1";
    description = "ExternalDNS, which manages records in an external DNS provider (Cloudflare by default) from Ingresses and Services";
    owner = "platform";
  };

  options = {
    image = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        repository = "docker.io/bitnamilegacy/external-dns";
        tag = "0.16.1-debian-12-r1";
        pullPolicy = "IfNotPresent";
      };
    };
    provider = lib.mkOption {
      type = lib.types.str;
      default = "cloudflare";
    };
    sources = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "service"
        "ingress"
      ];
    };
    domainFilters = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
    serviceTypeFilters = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
    annotationFilter = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    policy = lib.mkOption {
      type = lib.types.str;
      default = "upsert-only";
    };
    txtOwnerId = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    txtPrefix = lib.mkOption {
      type = lib.types.str;
      default = "ext-dns-";
    };
    registry = lib.mkOption {
      type = lib.types.str;
      default = "txt";
    };
    logLevel = lib.mkOption {
      type = lib.types.str;
      default = "info";
    };
    logFormat = lib.mkOption {
      type = lib.types.str;
      default = "text";
    };
    interval = lib.mkOption {
      type = lib.types.str;
      default = "1m";
    };
    metricsPort = lib.mkOption {
      type = lib.types.int;
      default = 7979;
    };
    cloudflare = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {
        dnsRecordsPerPage = 100;
      };
    };
    triggerLoopOnEvent = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    env = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
    };
    secretName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    extraLabels = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };
    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
        requests = {
          cpu = "100m";
          memory = "128Mi";
          ephemeral-storage = "50Mi";
        };
        limits = {
          cpu = "150m";
          memory = "192Mi";
          ephemeral-storage = "2Gi";
        };
      };
    };
    affinity = lib.mkOption {
      type = lib.types.anything;
      default = { };
      description = ''
        Pod affinity, verbatim. Spread across failure domains is derived by
        the cluster (cluster.spread); set this only for node affinity or a
        rule stronger than the derived one.
      '';
    };
    networkPolicy = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {
        enabled = true;
      };
    };
  };

  build =
    {
      self,
      config,
      clusterConfig,
    }:
    let
      name = scope.instanceName;

      # Selector labels — use static app name (external-dns) not instance name.
      # This matches the Helm chart convention where all external-dns instances
      # share the same app.kubernetes.io/name.
      edSelectorLabels = {
        "app.kubernetes.io/instance" = name;
        "app.kubernetes.io/name" = "external-dns";
      };

      # --- RBAC DSL ---
      inherit (scope.rbac)
        core
        group
        grant
        watch
        allow
        mkClusterRoleSet
        ;

      f5 = group "cis.f5.com" [
        "virtualservers"
        "transportservers"
      ];
      kong = group "configuration.konghq.com" [ "tcpingresses" ];
      gateway = group "gateway.networking.k8s.io" [
        "gateways"
        "httproutes"
        "tlsroutes"
        "tcproutes"
        "udproutes"
        "grpcroutes"
      ];
      istio = group "networking.istio.io" [
        "gateways"
        "virtualservices"
      ];
      contour = group "projectcontour.io" [ "httpproxies" ];
      openshift = group "route.openshift.io" [ "routes" ];
      zalando = group "zalando.org" [ "routegroups" ];

      clusterRoles = mkClusterRoleSet scope {
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = scope.namespaceName;
          }
        ];
        labels = config.extraLabels;
        roles = {
          "${name}-${scope.namespaceName}" = grant [
            # Core resources: services, pods, nodes, endpoints, namespaces
            (
              [
                core.services
                core.pods
                core.nodes
                core.endpoints
                core.namespaces
              ]
              |> watch
            )
            # CIS F5
            (
              [
                f5.virtualservers
                f5.transportservers
              ]
              |> watch
            )
            # Kong
            (kong.tcpingresses |> watch)
            # Extensions, networking.k8s.io, Ambassador — shared ingresses/hosts
            [
              {
                apiGroups = [
                  "extensions"
                  "networking.k8s.io"
                  "getambassador.io"
                ];
                resources = [
                  "ingresses"
                  "hosts"
                ];
                verbs = [
                  "get"
                  "list"
                  "watch"
                ];
              }
            ]
            # Gateway API
            (
              [
                gateway.gateways
                gateway.httproutes
                gateway.tlsroutes
                gateway.tcproutes
                gateway.udproutes
                gateway.grpcroutes
              ]
              |> watch
            )
            # Gloo / Gateway Solo
            [
              {
                apiGroups = [
                  "gloo.solo.io"
                  "gateway.solo.io"
                ];
                resources = [
                  "proxies"
                  "virtualservices"
                ];
                verbs = [
                  "get"
                  "list"
                  "watch"
                ];
              }
            ]
            # Istio
            (
              [
                istio.gateways
                istio.virtualservices
              ]
              |> watch
            )
            # Contour
            (contour.httpproxies |> watch)
            # OpenShift
            (openshift.routes |> watch)
            # Zalando routegroups — watch
            (zalando.routegroups |> watch)
            # Zalando routegroups/status — patch, update
            (
              zalando "routegroups/status"
              |> allow [
                "patch"
                "update"
              ]
            )
          ];
        };
      };

      # Not passed as --txt-owner-id yet; see housekeeping/2026-09-27-external-dns-ignores-txt-owner-id.md.
      # deadnix: skip
      ownerId = if config.txtOwnerId != null then config.txtOwnerId else name;

      # Merge extra labels into all resource labels.
      allLabels = edSelectorLabels // config.extraLabels;

      resolvedAffinity = if config.affinity == { } then null else config.affinity;

      # Build CLI args for the external-dns binary — ordered to match bitnami chart.
      args = [
        "--metrics-address=:${toString config.metricsPort}"
        "--log-level=${config.logLevel}"
        "--log-format=${config.logFormat}"
      ]
      ++ map (t: "--service-type-filter=${t}") config.serviceTypeFilters
      ++ map (d: "--domain-filter=${d}") config.domainFilters
      ++ [
        "--policy=${config.policy}"
        "--provider=${config.provider}"
        "--registry=${config.registry}"
        "--interval=${config.interval}"
        "--txt-prefix=${config.txtPrefix}"
      ]
      ++ lib.optional (config.annotationFilter != null) "--annotation-filter=${config.annotationFilter}"
      ++ map (s: "--source=${s}") config.sources
      ++ [ "--cloudflare-dns-records-per-page=${toString config.cloudflare.dnsRecordsPerPage}" ]
      ++ lib.optional config.triggerLoopOnEvent "--events";

      # Container env: Cloudflare credentials from a secret named after the instance.
      containerEnv =
        config.env
        ++ lib.optionals (self.secret != null) [
          {
            name = "CF_API_EMAIL";
            value = "";
          }
          (lib.recursiveUpdate (self.secret.out.keyRef "cloudflare_api_key") {
            name = "CF_API_KEY";
            valueFrom.secretKeyRef.optional = true;
          })
          (lib.recursiveUpdate (self.secret.out.keyRef "cloudflare_api_token") {
            name = "CF_API_TOKEN";
            valueFrom.secretKeyRef.optional = true;
          })
        ];

      # --- Mounts ---
      tmpMount = kix.mount.emptyDir {
        name = "empty-dir";
        mountPath = "/tmp";
        subPath = "tmp-dir";
      };

    in
    {

      # --- ServiceAccount ---
      serviceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        inherit name;
        labels = allLabels;
        extra = {
          automountServiceAccountToken = false;
        };
      };

      # --- Secret (Opaque, credentials managed externally) ---
      secret =
        if config.secretName != null then
          scope.mkSecret {
            name = config.secretName;
            labels = allLabels;
            keys = [
              "cloudflare_api_key"
              "cloudflare_api_token"
            ];
          }
        else
          null;

      # --- Service (metrics) ---
      service = scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        inherit name;
        labels = allLabels // {
          "k8s-app" = "external-dns";
        };
        spec = {
          type = "ClusterIP";
          selector = self.deployment.out.selector;
          ports = [
            {
              name = "http";
              port = config.metricsPort;
              targetPort = config.metricsPort;
              protocol = "TCP";
            }
          ];
        };
        outputs = {
          metricsPort = toString config.metricsPort;
        };
      };

      # --- NetworkPolicy ---
      networkPolicy =
        if config.networkPolicy.enabled then
          scope.mkResource {
            apiVersion = "networking.k8s.io/v1";
            kind = "NetworkPolicy";
            inherit name;
            labels = allLabels // {
              "app.kubernetes.io/component" = "controller";
            };
            spec = {
              podSelector.matchLabels = edSelectorLabels;
              policyTypes = [
                "Ingress"
                "Egress"
              ];
              ingress = [
                {
                  ports = [
                    {
                      port = config.metricsPort;
                      protocol = "TCP";
                    }
                  ];
                }
              ];
              egress = [ { } ];
            };
          }
        else
          null;

      # --- Deployment ---
      deployment =
        {
          inherit name;
          labels = allLabels;
          requires =
            builtins.attrValues clusterRoles
            ++ lib.optional (self.secret != null) self.secret
            ++ lib.optional (self.networkPolicy != null) self.networkPolicy;
          spec = {
            replicas = 1;
            selector.matchLabels = edSelectorLabels;
            strategy = {
              type = "RollingUpdate";
              rollingUpdate = {
                maxSurge = "25%";
                maxUnavailable = "25%";
              };
            };
            template.metadata.labels =
              edSelectorLabels
              // {
                "k8s-app" = "external-dns";
              }
              // config.extraLabels;
            template.spec = {
              serviceAccountName = self.serviceAccount.out.name;
              automountServiceAccountToken = true;
              # Kubernetes' default, set explicitly; the external-dns chart
              # (1.16.1) leaves `terminationGracePeriodSeconds` unset.
              terminationGracePeriodSeconds = 30;
              affinity = resolvedAffinity;
              securityContext = {
                fsGroup = 1001;
                fsGroupChangePolicy = "Always";
              };
              containers = [
                (
                  {
                    name = "external-dns";
                    image = "${config.image.repository}:${config.image.tag}";
                    imagePullPolicy = config.image.pullPolicy;
                    inherit args;
                    ports = [
                      (kix.port "http" config.metricsPort)
                    ];
                    livenessProbe = {
                      tcpSocket = {
                        port = "http";
                      };
                      initialDelaySeconds = 10;
                      periodSeconds = 10;
                      timeoutSeconds = 5;
                      failureThreshold = 2;
                      successThreshold = 1;
                    };
                    readinessProbe = {
                      httpGet = {
                        path = "/healthz";
                        port = "http";
                      };
                      initialDelaySeconds = 5;
                      periodSeconds = 10;
                      timeoutSeconds = 5;
                      failureThreshold = 6;
                      successThreshold = 1;
                    };
                    resources = config.resources;
                    securityContext = {
                      allowPrivilegeEscalation = false;
                      capabilities.drop = [ "ALL" ];
                      privileged = false;
                      readOnlyRootFilesystem = true;
                      runAsGroup = 1001;
                      runAsNonRoot = true;
                      runAsUser = 1001;
                      seccompProfile.type = "RuntimeDefault";
                    };
                  }
                  // lib.optionalAttrs (containerEnv != [ ]) {
                    env = containerEnv;
                  }
                )
              ];
            };
          };
        }
        |> kix.withMounts [ tmpMount ]
        |> scope.mkDeployment;

      # --- Entry point ---
      root = self.deployment;
    }
    // clusterRoles;
}

# alertmanager — Alertmanager managed by the Prometheus Operator.
#
# Creates an Alertmanager CR that the operator reconciles into a StatefulSet.
# Routing config (receivers, routes) is cluster-specific.
#
# DI deps:
#   prometheus-operator (required) — provides the Alertmanager CRD
#
# Exposes:
#   out.serviceUrl — for Prometheus alerting config

{
  scope,
  lib,
}:
let
  name = scope.instanceName;
  ns = scope.namespaceName;
in
{
  meta = {
    version = "v0.33.1";
    description = "Alertmanager — alert routing and deduplication";
    defaultAliases = [ "alertmanager" ];
    k8s.minVersion = "1.25";
    # Silences and notification state are recoverable — expendable on
    # storage backend swaps. See v2_discussions/67_stateful_migration_orchestration.md.
    lifecycle = "ephemeral";
  };

  options = {
    image = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "quay.io/prometheus/alertmanager";
        tag = "v0.33.1";
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
          cpu = "10m";
          memory = "256Mi";
        };
        limits = {
          cpu = "1";
          memory = "1Gi";
        };
      };
    };
    # Alertmanager config — receivers, routes, etc.
    # This is cluster-specific and set in the cluster module.
    config = lib.mkOption {
      type = lib.types.anything;
      default = {
        global.resolve_timeout = "5m";
        route = {
          group_by = [
            "namespace"
            "alertname"
          ];
          group_wait = "30s";
          group_interval = "5m";
          repeat_interval = "12h";
          receiver = "null";
          routes = [
            {
              receiver = "null";
              matchers = [ "alertname = Watchdog" ];
            }
          ];
        };
        receivers = [
          { name = "null"; }
        ];
      };
    };
    priorityClassName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    storage = lib.mkOption {
      type = lib.types.anything;
      default = null;
    };
    serviceMonitor = lib.mkOption {
      type = lib.types.submodule {
        options = {
          selfMonitor = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Emit a ServiceMonitor that scrapes Alertmanager itself.";
          };
          interval = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
          };
          path = lib.mkOption {
            type = lib.types.str;
            default = "/metrics";
          };
        };
      };
      default = { };
    };
    alertmanagerConfigSelector = lib.mkOption {
      type = lib.types.nullOr lib.types.attrs;
      default = null;
      description = ''
        Selector for AlertmanagerConfig CRs the operator should aggregate into
        the alertmanager config. Set to `{}` to match all in the namespace, or
        `{ matchLabels = { team = "infra"; }; }`. Without this, AlertmanagerConfig
        CRs are silently ignored.
      '';
    };
    alertmanagerConfigNamespaceSelector = lib.mkOption {
      type = lib.types.nullOr lib.types.attrs;
      default = null;
      description = "Namespace selector for AlertmanagerConfig CRs (default: same namespace).";
    };
    externalUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "External URL where Alertmanager is reachable (used in notification links).";
    };
    routePrefix = lib.mkOption {
      type = lib.types.str;
      default = "/";
    };
    secrets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Secrets mounted into Alertmanager pods at /etc/alertmanager/secrets/<name>.";
    };
    configMaps = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "ConfigMaps mounted into Alertmanager pods at /etc/alertmanager/configmaps/<name>.";
    };
    extraSpec = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = ''
        Extra fields deep-merged into the Alertmanager CR spec. Escape hatch
        for fields not exposed as typed options (tolerations, nodeSelector,
        affinity, additionalPeers, podMetadata, etc.).
      '';
    };

    # ── Web (TLS / HTTP-2 / headers) ──────────────────────────────────────
    # Mirrors chart's `alertmanagerSpec.web`. Free-form because the
    # Alertmanager CR spec.web has many nested fields (tlsConfig, httpConfig,
    # getConcurrency, timeout) and copying every one costs more than it
    # earns. Set to e.g. `{ tlsConfig = { keySecret = ...; cert = ...; }; }`.
    web = lib.mkOption {
      type = lib.types.nullOr lib.types.anything;
      default = null;
      description = ''
        Free-form value injected as `spec.web` on the Alertmanager CR. Use
        for TLS server certs, HTTP-2 toggles, header settings.
      '';
    };

    # ── PodDisruptionBudget ───────────────────────────────────────────────
    # Mirrors templates/alertmanager/podDisruptionBudget.yaml. The chart
    # passes everything except `enabled` straight through to spec, so kix
    # exposes only the common knobs and pipes the rest through extraPdbSpec.
    podDisruptionBudget = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enabled = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
          minAvailable = lib.mkOption {
            type = lib.types.nullOr (lib.types.either lib.types.int lib.types.str);
            default = 1;
          };
          maxUnavailable = lib.mkOption {
            type = lib.types.nullOr (lib.types.either lib.types.int lib.types.str);
            default = null;
          };
          unhealthyPodEvictionPolicy = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = "AlwaysAllow";
          };
          extraSpec = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = { };
            description = "Extra fields deep-merged into the PDB spec.";
          };
        };
      };
      default = { };
    };

    # ── NetworkPolicy ─────────────────────────────────────────────────────
    # Mirrors templates/alertmanager/networkpolicy.yaml. Cilium flavor lives
    # in a separate chart template and is skipped here — kix clusters that
    # need cilium-flavored policy can drop a CiliumNetworkPolicy through the
    # raw-resources package or extend this generator later.
    networkPolicy = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enabled = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
          policyTypes = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "Ingress" ];
          };
          gateway = lib.mkOption {
            type = lib.types.submodule {
              options = {
                namespace = lib.mkOption {
                  type = lib.types.str;
                  default = "";
                };
                podLabels = lib.mkOption {
                  type = lib.types.attrs;
                  default = { };
                };
              };
            };
            default = { };
          };
          additionalIngress = lib.mkOption {
            type = lib.types.listOf lib.types.attrs;
            default = [ ];
          };
          egress = lib.mkOption {
            type = lib.types.submodule {
              options = {
                enabled = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                };
                rules = lib.mkOption {
                  type = lib.types.listOf lib.types.attrs;
                  default = [ ];
                };
              };
            };
            default = { };
          };
          enableClusterRules = lib.mkOption {
            type = lib.types.bool;
            default = true;
          };
          monitoringRules = lib.mkOption {
            type = lib.types.submodule {
              options = {
                prometheus = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                };
                configReloader = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                };
              };
            };
            default = { };
          };
          # Service ports referenced by the NP rules. Default = AM listen
          # port (9093) and operator-managed gossip port (9094).
          servicePort = lib.mkOption {
            type = lib.types.int;
            default = 9093;
          };
          clusterPort = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = 9094;
          };
        };
      };
      default = { };
    };
  };

  build =
    {
      self,
      config,
      prometheusOperator,
      ...
    }:
    let
      mkAlertmanager = prometheusOperator.out.mkAlertmanager;
      mkSmon = prometheusOperator.out.mkServiceMonitor scope;
      svcSelector = {
        "app.kubernetes.io/name" = "alertmanager";
        "app.kubernetes.io/instance" = name;
      };
    in
    {
      serviceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        inherit name;
        extra.automountServiceAccountToken = true;
      };

      # Alertmanager config as a Secret (the operator expects this)
      alertmanagerConfig = scope.mkSecret {
        name = "alertmanager-${name}";
        stringData."alertmanager.yaml" = builtins.toJSON config.config;
      };

      # Alertmanager CR — operator reconciles into StatefulSet
      alertmanager = mkAlertmanager scope {
        inherit name;
        spec = lib.recursiveUpdate (
          {
            replicas = config.replicas;
            image = "${config.image.repository}:${config.image.tag}";
            version = config.image.tag;
            serviceAccountName = self.serviceAccount.out.name;
            resources = config.resources;
            routePrefix = config.routePrefix;
          }
          // lib.optionalAttrs (config.priorityClassName != null) {
            priorityClassName = config.priorityClassName;
          }
          // lib.optionalAttrs (config.storage != null) {
            storage.volumeClaimTemplate = config.storage;
          }
          // lib.optionalAttrs (config.externalUrl != null) {
            externalUrl = config.externalUrl;
          }
          // lib.optionalAttrs (config.alertmanagerConfigSelector != null) {
            alertmanagerConfigSelector = config.alertmanagerConfigSelector;
          }
          // lib.optionalAttrs (config.alertmanagerConfigNamespaceSelector != null) {
            alertmanagerConfigNamespaceSelector = config.alertmanagerConfigNamespaceSelector;
          }
          // lib.optionalAttrs (config.secrets != [ ]) {
            secrets = config.secrets;
          }
          // lib.optionalAttrs (config.configMaps != [ ]) {
            configMaps = config.configMaps;
          }
          // lib.optionalAttrs (config.web != null) {
            web = config.web;
          }
        ) config.extraSpec;
      };

      service = scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        inherit name;
        spec = {
          type = "ClusterIP";
          selector = svcSelector;
          ports = [
            {
              name = "http-web";
              port = 9093;
              targetPort = 9093;
              protocol = "TCP";
            }
          ];
        };
        outputs = {
          serviceUrl = "http://${name}.${ns}.svc.cluster.local:9093";
        };
      };

      # ── PodDisruptionBudget ─────────────────────────────────────────────
      # Mirrors templates/alertmanager/podDisruptionBudget.yaml. Selector
      # uses `app.kubernetes.io/name=alertmanager` + `alertmanager=<crname>`,
      # the labels the Prometheus Operator stamps on Alertmanager pods.
      podDisruptionBudget = lib.optionalAttrs config.podDisruptionBudget.enabled {
        pdb = scope.mkResource {
          apiVersion = "policy/v1";
          kind = "PodDisruptionBudget";
          name = "${name}-alertmanager";
          spec = lib.recursiveUpdate (
            {
              selector.matchLabels = {
                "app.kubernetes.io/name" = "alertmanager";
                alertmanager = name;
              };
            }
            // lib.optionalAttrs (config.podDisruptionBudget.minAvailable != null) {
              inherit (config.podDisruptionBudget) minAvailable;
            }
            // lib.optionalAttrs (config.podDisruptionBudget.maxUnavailable != null) {
              inherit (config.podDisruptionBudget) maxUnavailable;
            }
            // lib.optionalAttrs (config.podDisruptionBudget.unhealthyPodEvictionPolicy != null) {
              inherit (config.podDisruptionBudget) unhealthyPodEvictionPolicy;
            }
          ) config.podDisruptionBudget.extraSpec;
        };
      };

      # ── NetworkPolicy ───────────────────────────────────────────────────
      # Mirrors templates/alertmanager/networkpolicy.yaml. Each conditional
      # ingress block matches the chart's gating logic byte-for-byte.
      networkPolicy = lib.optionalAttrs config.networkPolicy.enabled (
        let
          npc = config.networkPolicy;
          gatewaySet = npc.gateway.namespace != "" && npc.gateway.podLabels != { };
          gatewayIngress = lib.optional gatewaySet {
            from = [
              {
                namespaceSelector.matchLabels."kubernetes.io/metadata.name" = npc.gateway.namespace;
                podSelector.matchLabels = npc.gateway.podLabels;
              }
            ];
            ports = [
              {
                port = npc.servicePort;
                protocol = "TCP";
              }
            ];
          };
          promIngress = lib.optional npc.monitoringRules.prometheus {
            from = [
              { podSelector.matchLabels."app.kubernetes.io/name" = "prometheus"; }
            ];
            ports = [
              {
                port = npc.servicePort;
                protocol = "TCP";
              }
            ]
            ++ lib.optional npc.monitoringRules.configReloader {
              port = 8080;
              protocol = "TCP";
            };
          };
          clusterIngress = lib.optional (npc.enableClusterRules && npc.clusterPort != null) {
            from = [
              { podSelector.matchLabels."app.kubernetes.io/name" = "alertmanager"; }
            ];
            ports = [
              {
                port = npc.clusterPort;
                protocol = "TCP";
              }
            ];
          };
          configReloaderIngress = lib.optional npc.monitoringRules.configReloader {
            from = [
              {
                podSelector.matchLabels = {
                  "app.kubernetes.io/name" = "alertmanager";
                  component = "config-reloader";
                };
              }
            ];
            ports = [
              {
                port = 8080;
                protocol = "TCP";
              }
            ];
          };
          ingressRules =
            gatewayIngress ++ promIngress ++ clusterIngress ++ configReloaderIngress ++ npc.additionalIngress;
        in
        {
          np = scope.mkResource {
            apiVersion = "networking.k8s.io/v1";
            kind = "NetworkPolicy";
            name = "${name}-alertmanager";
            spec = {
              podSelector.matchLabels."app.kubernetes.io/name" = "alertmanager";
              policyTypes = npc.policyTypes;
              ingress = ingressRules;
            }
            // lib.optionalAttrs npc.egress.enabled {
              egress = npc.egress.rules;
            };
          };
        }
      );

      selfMonitor = lib.optionalAttrs config.serviceMonitor.selfMonitor {
        serviceMonitor = mkSmon {
          name = "${name}-self";
          spec = {
            # ServiceMonitors match SERVICE labels, not pod labels — the
            # pod-shaped svcSelector never matched the Service and the
            # self-monitor was silently unscraped (caught by
            # monitorSelectorMatchesService, 2026-08-31).
            selector.matchLabels = self.service.out.selector;
            namespaceSelector.matchNames = [ ns ];
            endpoints = [
              (
                {
                  port = "http-web";
                  path = config.serviceMonitor.path;
                }
                // lib.optionalAttrs (config.serviceMonitor.interval != null) {
                  inherit (config.serviceMonitor) interval;
                }
              )
            ];
          };
        };
      };

      root = {
        resource = self.service;
        requires = [
          self.serviceAccount
          self.alertmanagerConfig
          self.alertmanager
        ]
        ++ lib.optional config.serviceMonitor.selfMonitor self.selfMonitor.serviceMonitor
        ++ lib.optional config.podDisruptionBudget.enabled self.podDisruptionBudget.pdb
        ++ lib.optional config.networkPolicy.enabled self.networkPolicy.np;
        out = {
          inherit (self.service.out) serviceUrl;
          # The Alertmanager CR's image is reconciled by the operator into a
          # StatefulSet — not directly in a kix-generated pod spec.
          extraImages = [
            "${config.image.repository}:${config.image.tag}"
          ];
        };
      };
    };
}

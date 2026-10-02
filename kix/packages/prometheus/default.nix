# prometheus: a Prometheus server, run by the Prometheus Operator from a
# Prometheus resource.
#
# Installs the Prometheus resource, its ServiceAccount and a ClusterRole for
# Kubernetes service discovery, the egress policy of the server pods, and,
# while `metrics.enabled`, a ServiceMonitor through which the server scrapes
# itself. The operator turns the resource into a StatefulSet and a headless
# Service `prometheus-operated` (port `web`, 9090), which `service` describes.
#
# By default the server selects every ServiceMonitor, PodMonitor, and
# PrometheusRule in every namespace, keeps 7 days of data in an emptyDir,
# and scrapes and evaluates every 30 seconds. `extraSpec` changes any of it.
#
# Dependencies:
#   prometheusOperator (required)  the operator, whose `out.crds.Prometheus`
#                                  builds the resource.
#   alertmanager (optional)        where the server sends alerts
#                                  (`spec.alerting`), from the
#                                  alertmanager package's `out`.
#   storageClasses (optional)      the class of the data volumes when
#                                  `storage.size` is set and
#                                  `storage.storageClassName` is null.
#   priorityClass (optional)       the server pods' PriorityClass.
#
# Minimal instance, with a prometheus-operator in the same cluster:
#
#   instances.monitoring-system.prometheus-server.package = packages.prometheus;
#
# `out`: the `prometheus-operated` Service's `name`, `fqdn`, and `port`, its
# `namespace`, and `serviceUrl`, the base URL of the HTTP API (Grafana's
# datasource).
#
# Replicas follow the instance's availability: one up to `pod`, two from
# `node`, each scraping and storing everything, spread across the level's
# failure domain, with a PodDisruptionBudget that keeps one up.
#
# Network policy: the netpol plugin derives the scrape egress from the
# monitors this server selects and the Alertmanager egress from
# `spec.alerting`; `serverEgress` adds DNS and the API server. Targets that
# `extraSpec.additionalScrapeConfigs` or a ScrapeConfig names get no policy.
#
# Escape hatches: `extraSpec` for the Prometheus resource's spec, and the
# instance's `partsOverlays`.

{
  scope,
  lib,
  kix,
  availability,
}:
let
  release = "v3.13.1";
  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "prometheus ${ns}/${name}";

  replicas = kix.availability.pick availability {
    none = 1;
    pod = 1;
    node = 2;
    zone = 2;
  };
in
{
  meta = {
    version = release;
    description = "Prometheus time-series database";
    owner = "platform";
    defaultAliases = [ "prometheusServer" ];
    k8s.minVersion = "1.25";
    # Historical metrics are expendable; a fresh start is acceptable on
    # storage backend swaps. See v2_discussions/67_stateful_migration_orchestration.md.
    lifecycle = "ephemeral";
  };

  assertions =
    { config, ... }:
    [
      {
        assertion = config.storage.size != null || config.storage.storageClassName == null;
        message = "storage.storageClassName is set but storage.size is null, so the server keeps its data in an emptyDir and the class is unused. Set storage.size, or remove storage.storageClassName.";
      }
    ];

  options = {
    image = kix.options.image {
      repository = "quay.io/prometheus/prometheus";
      tag = release;
      digest = "sha256:3c42b892cf723fa54d2f262c37a0e1f80aa8c8ddb1da7b9b0df9455a35a7f893";
      pullPolicy = null;
    };
    resources = kix.options.resources {
      requests = {
        cpu = "500m";
        memory = "2Gi";
      };
      limits = {
        cpu = "2";
        memory = "4Gi";
      };
    };
    storage = {
      size = lib.mkOption {
        type = lib.types.nullOr kix.types.quantity;
        default = null;
        example = "50Gi";
        description = "Size of each server's data volume, a claim the operator creates from the resource's volume claim template. Null keeps the data in an emptyDir, which a pod restart empties.";
      };
      storageClassName = lib.mkOption {
        type = lib.types.nullOr lib.types.nonEmptyStr;
        default = null;
        description = "StorageClass of the data volumes. Null takes the `storageClasses` dependency's class, or the cluster's default class without one.";
      };
    };
    extraSpec = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        retention = "30d";
        retentionSize = "40GB";
        externalUrl = "https://prometheus.example.com";
        remoteWrite = [ { url = "https://metrics.example.com/api/v1/write"; } ];
      };
      description = ''
        Fields deep-merged into the Prometheus resource's spec, such as
        `retention`, `retentionSize`, `scrapeInterval`, `evaluationInterval`,
        `externalUrl`, `remoteWrite`, the monitor and rule selectors, or
        `securityContext`. The package sets `retention = "7d"`,
        `enableAdminAPI` and `enableRemoteWriteReceiver` to false,
        `scrapeInterval` and `evaluationInterval` to "30s", selectors that
        select everything, and a securityContext running as user 1000 and
        group 2000. It refuses `image`, `version`, and `imagePullPolicy`,
        which image sets, `replicas`, which follows the instance's
        availability, `resources`, `serviceAccountName`, `storage`, and,
        when the instance has the dependency, `alerting` and
        `priorityClassName`.
      '';
    };
    metrics = kix.options.monitor;
  };

  build =
    {
      self,
      config,
      clusterConfig,
      prometheusOperator,
      alertmanager ? null,
      storageClasses ? null,
      priorityClass ? null,
      ...
    }:
    let
      # The labels the operator puts on this resource's server pods.
      serverPodSelector = prometheusOperator.out.operandSelectors.prometheus name;

      storageClassName =
        if config.storage.storageClassName != null then
          config.storage.storageClassName
        else if storageClasses != null then
          storageClasses.out.storageClassName
        else
          null;

      baseSpec = {
        inherit replicas;
        image = kix.image.ref config.image;
        version = config.image.tag;
        serviceAccountName = self.serviceAccount.out.name;
        resources = config.resources;

        # Neither lets a client write: the admin API deletes series, and the
        # receiver accepts remote-write pushes.
        enableAdminAPI = false;
        enableRemoteWriteReceiver = false;

        retention = "7d";
        scrapeInterval = "30s";
        evaluationInterval = "30s";
        securityContext = {
          runAsNonRoot = true;
          runAsUser = 1000;
          runAsGroup = 2000;
          fsGroup = 2000;
        };

        # A null selector selects nothing, `{ }` everything; a null
        # namespace selector means this namespace only.
        serviceMonitorSelector = { };
        serviceMonitorNamespaceSelector = { };
        podMonitorSelector = { };
        podMonitorNamespaceSelector = { };
        ruleSelector = { };
        ruleNamespaceSelector = { };
      }
      // lib.optionalAttrs (config.image.pullPolicy != null) {
        imagePullPolicy = config.image.pullPolicy;
      }
      // lib.optionalAttrs (config.storage.size != null) {
        storage.volumeClaimTemplate.spec = {
          accessModes = [ "ReadWriteOnce" ];
          resources.requests.storage = toString config.storage.size;
        }
        // lib.optionalAttrs (storageClassName != null) { inherit storageClassName; };
      }
      // lib.optionalAttrs (alertmanager != null) {
        alerting.alertmanagers = [
          {
            inherit (alertmanager.out) namespace name;
            port = alertmanager.out.portName;
            apiVersion = "v2";
          }
        ];
      }
      // lib.optionalAttrs (priorityClass != null) {
        priorityClassName = priorityClass.out.name;
      }
      // lib.optionalAttrs (replicas > 1) {
        topologySpreadConstraints = kix.availability.spreadConstraints {
          level = availability;
          selector = serverPodSelector;
          topology = clusterConfig.cluster.topology;
        };
      };

      spec = kix.mergeGuarded {
        inherit who;
        locked = [
          [ "image" ]
          [ "version" ]
          [ "imagePullPolicy" ]
          [ "replicas" ]
          [ "resources" ]
          [ "serviceAccountName" ]
          [ "storage" ]
        ]
        ++ lib.optional (alertmanager != null) [ "alerting" ]
        ++ lib.optional (priorityClass != null) [ "priorityClassName" ];
      } baseSpec config.extraSpec;

      inherit (scope.rbac)
        group
        core
        grant
        watch
        allow
        ;
    in
    {
      serviceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        inherit name;
      };

      # Kubernetes service discovery for every namespace the selectors
      # reach, and the kubelet's metrics endpoints.
      scrapeRbac = scope.rbac.mkClusterRoleSet scope {
        labels = scope.selectorLabels;
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = ns;
          }
        ];
        roles.${name} =
          grant [
            (core.nodes |> watch)
            (core "nodes/metrics" |> allow [ "get" ])
            (core.services |> watch)
            (core.endpoints |> watch)
            (core.pods |> watch)
            (core.configmaps |> allow [ "get" ])
            (group "networking.k8s.io" [ "ingresses" ] |> (r: r.ingresses) |> watch)
            (group "discovery.k8s.io" [ "endpointslices" ] |> (r: r.endpointslices) |> watch)
          ]
          ++ [
            {
              nonResourceURLs = [
                "/metrics"
                "/metrics/cadvisor"
              ];
              verbs = [ "get" ];
            }
          ];
      };

      prometheus = scope.mkCR prometheusOperator.out.crds.Prometheus {
        inherit name spec;
      };

      # The operator creates the server pods, so no workload policy is
      # derived for them. Kubernetes service discovery needs the API server;
      # the netpol plugin adds the scrape and Alertmanager egress from the
      # monitors this Prometheus selects.
      serverEgress = kix.operandPolicy {
        inherit scope;
        name = "${name}-server-egress";
        spec = {
          endpointSelector.matchLabels = serverPodSelector;
          egress = [
            scope.networkPolicyEnforcer.netpol.dnsEgressRule
            scope.networkPolicyEnforcer.netpol.apiServerEgressRule
          ];
        };
      };

      # The operator renders no PodDisruptionBudget, and the availability
      # plugin derives one only for workloads Kix renders.
      podDisruptionBudget =
        if replicas > 1 then
          scope.mkResource {
            apiVersion = "policy/v1";
            kind = "PodDisruptionBudget";
            inherit name;
            annotations.${kix.keys.operandOf} = "monitoring.coreos.com/Prometheus/${self.prometheus.name}";
            requires = [ self.prometheus ];
            spec = {
              maxUnavailable = 1;
              selector.matchLabels = serverPodSelector;
            };
          }
        else
          null;

      # The operator creates `prometheus-operated` (headless, port web 9090)
      # over the server pods of every Prometheus in the namespace. A
      # ServiceRef describes that Service, so out.fqdn carries dependency
      # context, the deploy engine waits for the Service, and netpol derives
      # the same edges as for a rendered Service (v2_discussions/135).
      service = scope.mkServiceRef {
        name = "prometheus-operated";
        selector = serverPodSelector;
        # The label the operator puts on prometheus-operated.
        labels."operated-prometheus" = "true";
        ports = [
          {
            name = "web";
            port = 9090;
            protocol = "TCP";
          }
        ];
        requires = [ self.prometheus ];
      };

      selfMonitor =
        if config.metrics.enabled then
          prometheusOperator.out.mkServiceMonitor scope {
            inherit name;
            spec = {
              # A ServiceMonitor selects Services, not pods, so this uses the
              # labels of the operator's Service from its ref.
              selector.matchLabels = self.service.out.labels;
              namespaceSelector.matchNames = [ ns ];
              endpoints = [
                (
                  {
                    port = "web";
                  }
                  // lib.optionalAttrs (config.metrics.interval != null) { inherit (config.metrics) interval; }
                )
              ];
            };
          }
        else
          null;

      root = {
        resource = self.service;
        requires = [
          self.serviceAccount
          self.prometheus
        ]
        ++ builtins.filter (p: p != null) [
          self.serverEgress
          self.podDisruptionBudget
          self.selfMonitor
        ];
        out = {
          namespace = ns;
          # Built on the ref's fqdn: the URL carries the marker's context.
          serviceUrl = "http://${self.service.out.fqdn}:${self.service.out.port}";
          # The operator runs this image in a StatefulSet that Kix does not
          # render.
          extraImages = [ (kix.image.ref config.image) ];
        };
      };
    };
}

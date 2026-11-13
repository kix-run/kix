# prometheus: a Prometheus server, run by the Prometheus Operator from a
# Prometheus resource.
#
# Installs the Prometheus resource, its ServiceAccount, a ClusterRole for
# Kubernetes service discovery, a headless Service named after the instance
# (port `web`, 9090) that the resource names as its governing Service
# (`spec.serviceName`), the egress policy of the server pods, and, while
# `metrics.enabled`, a ServiceMonitor through which the server scrapes
# itself. The operator turns the resource into a StatefulSet; with
# `spec.serviceName` set it creates no `prometheus-operated` Service, and it
# reports an error for a governing Service that does not select the pods.
#
# By default the server selects every ServiceMonitor, PodMonitor, and
# PrometheusRule in every namespace, keeps 7 days of data in an emptyDir,
# and scrapes and evaluates every 30 seconds. `extraSpec` changes any of it.
#
# Dependencies:
#   prometheusOperator (required)  the operator, whose `out.crds.Prometheus`
#                                  builds the resource.
#   alertmanager (optional)        where the server sends alerts
#                                  (`spec.alerting`), an alertmanager
#                                  instance in the cluster. For an
#                                  Alertmanager outside the cluster, give its
#                                  address in
#                                  `extraSpec.additionalAlertManagerConfigs`.
#   storageClasses (optional)      the class of the data volumes when
#                                  `storage.size` is set. Without one the
#                                  claims take the cluster's default class.
#                                  For another class, set
#                                  `deps.storageClasses = ref.<ns>.<instance>`.
#   priorityClass (optional)       the server pods' PriorityClass.
#
# Minimal instance, with a prometheus-operator in the same cluster:
#
#   instances.monitoring-system.prometheus-server.package = packages.experimental.prometheus;
#
# `out`: the Service's `name` and `fqdn`, its `namespace`, `serviceUrl`, the
# base URL of the HTTP API (Grafana's datasource), and `version`, the
# Prometheus version `image.tag` names. Each instance has its
# own Service, so two instances in one namespace do not share one, and the
# self-scrape of each lands in a job named after the instance.
#
# Replicas follow the instance's availability: one at `none`, two from
# `pod`, each scraping and storing everything, so one can restart while the
# other serves. With two, the pods spread across the level's failure domain
# and a PodDisruptionBudget lets one be down at a time.
#
# Network policy: the netpol plugin derives the scrape egress from the
# monitors this server selects and the Alertmanager egress from
# `spec.alerting`; `serverEgress` adds DNS and the API server. Targets that
# `extraSpec.additionalScrapeConfigs`, a ScrapeConfig, or a Probe names get
# no policy, and neither does an Alertmanager in
# `extraSpec.additionalAlertManagerConfigs`. The netpol plugin warns about
# each.
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
  release = "v3.13.5";
  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "prometheus ${ns}/${name}";

  replicas = kix.availability.pick availability {
    none = 1;
    pod = 2;
    node = 2;
    zone = 2;
  };

  webPort = 9090;
in
{
  meta = {
    version = lib.removePrefix "v" release;
    description = "Prometheus time-series database";
    owner = "platform";
    defaultAliases = [ "prometheusServer" ];
    k8s.minVersion = "1.25";
    # Historical metrics are expendable; a fresh start is acceptable on
    # storage backend swaps.
    lifecycle = "ephemeral";
  };

  options = {
    image = kix.options.image {
      repository = "quay.io/prometheus/prometheus";
      tag = release;
      digest = "sha256:aafa9d694e6a883c02db516d9f6e5b84e14195f49a2a6456a4cca815edda72b9";
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
        description = "Size of each server's data volume, a claim the operator creates from the resource's volume claim template, in the `storageClasses` dependency's class. Null keeps the data in an emptyDir, which a pod restart empties.";
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
        which image sets, `replicas` and `topologySpreadConstraints`, which
        follow the instance's availability, `resources`,
        `serviceAccountName`, `serviceName`, `storage`, and, when the
        instance has the dependency, `alerting` and `priorityClassName`.
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

      # spec.alerting names an Alertmanager resource's governing Service,
      # which only an alertmanager instance in the cluster publishes.
      alertmanagerOut =
        if alertmanager == null then
          null
        else if alertmanager.out ? namespace && alertmanager.out ? portName then
          alertmanager.out
        else
          scope.fail {
            package = "prometheus";
            message = "deps.alertmanager resolved to an instance whose out has no namespace and portName, so spec.alerting cannot name its Service.";
            fix = "Wire an alertmanager instance from packages.experimental.alertmanager. For an Alertmanager outside the cluster, give its address in extraSpec.additionalAlertManagerConfigs and let the kix.mkImport answer another alias, so this instance does not bind it.";
          };

      baseSpec = {
        inherit replicas;
        image = kix.image.ref config.image;
        version = builtins.unsafeDiscardStringContext config.image.tag;
        serviceAccountName = self.serviceAccount.out.name;
        serviceName = self.service.out.name;
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
        // lib.optionalAttrs (storageClasses != null) {
          inherit (storageClasses.out) storageClassName;
        };
      }
      // lib.optionalAttrs (alertmanagerOut != null) {
        alerting.alertmanagers = [
          {
            inherit (alertmanagerOut) namespace name;
            port = alertmanagerOut.portName;
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
          [ "topologySpreadConstraints" ]
          [ "serviceAccountName" ]
          [ "serviceName" ]
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

      # The governing Service of the operator's StatefulSet, named in
      # `spec.serviceName`, headless as the operator's own would be. Check 4
      # cannot see the operator's pods; the annotation names the resource
      # that creates them.
      service = scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        inherit name;
        annotations.${kix.keys.operandOf} = "monitoring.coreos.com/Prometheus/${name}";
        spec = {
          clusterIP = "None";
          selector = serverPodSelector;
          ports = [
            {
              name = "web";
              port = webPort;
              targetPort = webPort;
              protocol = "TCP";
            }
          ];
        };
      };

      selfMonitor =
        if config.metrics.enabled then
          prometheusOperator.out.mkServiceMonitor scope {
            inherit name;
            spec = {
              # A Service's out.selector is its metadata labels, which a
              # ServiceMonitor matches.
              selector.matchLabels = self.service.out.selector;
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
        ];
        out = {
          version = kix.image.version config.image;
          namespace = ns;
          serviceUrl = self.service.out.url { };
          # The operator runs this image in a StatefulSet that Kix does not
          # render.
          extraImages = [ (kix.image.ref config.image) ];
        };
      };
    };
}

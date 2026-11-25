# keda: KEDA, Kubernetes Event-driven Autoscaling. It scales Deployments,
# StatefulSets, and Jobs from metrics it reads from event sources, such as a
# Prometheus query or a NATS JetStream consumer's lag.
#
# The package runs KEDA's three components, each with its own
# ServiceAccount:
#   - the operator, which reconciles ScaledObjects and ScaledJobs, creates a
#     HorizontalPodAutoscaler for each ScaledObject, polls every trigger's
#     source, and serves the values over gRPC on TCP 9666;
#   - the metrics API server, which serves external.metrics.k8s.io to the
#     HorizontalPodAutoscalers through APIService
#     v1beta1.external.metrics.k8s.io, and reads each value from the
#     operator over that gRPC connection;
#   - the admission webhooks, which validate the six KEDA kinds.
# It also applies the six keda.sh and eventing.keda.sh
# CustomResourceDefinitions (crds/, vendored from the release's CRD
# manifest), the operator's ClusterRole and Role and the aggregated
# `<instance>-edit` and `<instance>-view` ClusterRoles (rbac/, from the
# release manifest), the webhooks' ClusterRole (from upstream's Helm chart,
# templates/webhooks/clusterrole.yaml), the metrics API server's
# delegated-authentication bindings, the ValidatingWebhookConfiguration
# `<instance>-admission`, and the APIService.
#
# Certificates: the operator runs with --enable-cert-rotation, as upstream's
# release manifest ships it. On start it creates the Secret
# `<instance>-certs` in its namespace, writes a CA and a certificate for
# the three Services into it, and writes the CA into the `caBundle` of the
# webhook configuration and of the APIService
# (pkg/certificates/certificate_manager.go upstream). The metrics API server
# and the webhooks mount that Secret, and the operator and the metrics API
# server use it for mutual TLS on the gRPC connection. Kix renders both
# objects without `caBundle`, so the operator is that field's only writer.
# The operator learns the names it certifies and patches from flags the
# package sets, so they follow the instance name and the cluster domain.
# Upstream's Helm chart can use cert-manager instead; this package does not,
# because the operator's own rotation needs no other package.
#
# Deploy order: the operator starts first. The metrics API server and the
# webhooks wait for it, because their pods mount the Secret it creates. On a
# fresh install their pods can still restart until the operator has written
# the certificates into that Secret, as with upstream's manifests. The
# APIService and the webhook configuration come after the Services they
# name. The operator watches both objects and writes the CA into each when
# it appears. The deploy then waits for the APIService to report
# Available, which proves the API server reaches the metrics API server and
# trusts its certificate.
#
# Every KEDA kind carries the operator's finalizer (finalizer.keda.sh), so
# every kind names the operator Deployment as its `controller`. A deploy
# creates the custom resources after the operator, and a prune deletes them
# and waits for them to be gone before it deletes the operator. A custom
# resource still being deleted keeps the operator, and the deploy names the
# operator and says whether it is ready.
#
# Every webhook entry has failurePolicy Ignore, as upstream ships it, and
# the webhooks only validate. A ScaledObject written while the webhooks do
# not answer (on a fresh install, before the operator has written the CA)
# is admitted without validation, so custom resources do not wait for the
# webhooks.
#
# A cluster runs one instance (`conflictsWith`): the API server routes
# external.metrics.k8s.io to one APIService, whose name the group and
# version fix, and the operator watches every namespace.
#
# Dependencies:
#   prometheus (optional)  a metrics Service, a ServiceMonitor, and alert
#                          rules for the operator while `metrics.enabled`.
#
# Minimal instance:
#
#   instances.keda.keda.package = packages.experimental.keda;
#
# Consumer pattern, in a package that depends on `keda` and on `prometheus`
# (clusters/test-keda.nix builds it, with a NATS JetStream trigger on
# packages.experimental.nats in another namespace too):
#
#   worker = scope.mkDeployment { ... };   # no spec.replicas, see below
#   scaler = scope.mkCR keda.out.crds.ScaledObject {
#     name = "worker";
#     spec = {
#       scaleTargetRef.name = self.worker.out.name;
#       triggers = [ {
#         type = "prometheus";
#         metadata = {
#           serverAddress = prometheus.out.serviceUrl;
#           query = "sum(rate(jobs_enqueued_total[2m]))";
#           threshold = "10";
#         };
#       } ];
#     };
#   };
#
# Network policy: the ScaledObject, ScaledJob, TriggerAuthentication, and
# ClusterTriggerAuthentication definitions declare that the operator dials
# the addresses in their specs. A trigger whose metadata carries a Kix
# Service address (`prometheus.out.serviceUrl`, or
# `"${nats.out.monitoringHost}:${nats.out.monitoringPort}"` for the NATS
# monitoring endpoint) therefore orders the custom resource after
# that Service and opens the operator's egress to it and the Service's
# ingress from the operator, in one declaration. A source outside the
# cluster, or one written as a literal address, needs a
# `networkPolicy.platformIntents` entry for the operator's pods. The metrics
# API server's egress to the operator's gRPC port is derived from the
# address the package passes it. The intents admit the API server to TCP
# 6443 (the metrics API) and TCP 9443 (the webhooks). Package intents apply
# to every workload of the instance, so all three components accept both,
# where only one listens on each.
#
# Scale targets: KEDA's HorizontalPodAutoscaler writes `spec.replicas` of
# the target, and KEDA itself writes it when it scales to or from zero.
# Leave `spec.replicas` out of a target Deployment or StatefulSet, so Kix
# never owns the field and a deploy does not reset the count.
#
# Replicas: the operator elects a leader; one replica at availability none
# and pod, two from node up, the standby taking over when the leader is
# lost (upstream's high-availability notes allow two). The metrics API
# server and the webhooks keep no state and run one replica at none, two
# from pod up.
#
# Alerts: with a prometheus dependency and `metrics.enabled`, a
# PrometheusRule `<instance>-alerts` selects the operator's metrics Service.
#   KedaOperatorDown (warning)            no operator replica answers a
#                                         scrape. Nothing is scaled, and the
#                                         HorizontalPodAutoscalers read no
#                                         value.
#   KedaScalerErrors (warning)            a trigger of a ScaledObject or
#                                         ScaledJob has failed to read its
#                                         source for 15 minutes, such as a
#                                         source the network policy does not
#                                         open.
#   KedaOperatorReconcileErrors (warning) reconciles of one kind fail for 15
#                                         minutes.
# The metrics API server and the webhooks have no monitor. An unreachable
# metrics API server is prometheus-default-rules' KubeAggregatedAPIDown,
# and a webhook that does not answer only skips validation.
#
# `out`:
#   out.crds.<Kind>   CRD handles for scope.mkCR: ScaledObject, ScaledJob,
#                     TriggerAuthentication, and ClusterTriggerAuthentication.
#                       scope.mkCR keda.out.crds.ScaledObject { ... }
#   out.version       the KEDA version `image.tag` names.
#
# KEDA copies a ScaledObject's labels and annotations, Kix's included, onto
# the HorizontalPodAutoscaler it creates, and a ScaledJob's onto each Job
# (controllers/keda/hpa.go and pkg/scaling/executor/scale_jobs.go upstream).
# `kix gc --full-scan` lists those objects under "Copied labels" and keeps
# them, because Kix never wrote them, and a prune never treats them as
# orphans.
#
# Escape hatches: `env` and `extraArgs` for the operator,
# `metricsServer.extraArgs`, `webhooks.extraArgs`, and the instance's
# `partsOverlays`. The flags and variables that carry names, ports, or the
# certificate setup are refused with the reason.
#
# Limits:
# - The operator watches every namespace and reads any object, Secrets
#   included, in every namespace (upstream's ClusterRole grants get on every
#   resource), because a trigger's TriggerAuthentication names Secrets in
#   the ScaledObject's namespace and a scale target can be any kind with a
#   scale subresource.
# - CloudEventSource and ClusterCloudEventSource have definitions (the
#   operator watches them) and no handle, so no package builds them.
# - Service addresses in a ScaledJob's `jobTargetRef` open the operator's
#   egress, not the Job pods'. A definition can name one set of pods that
#   dials its addresses. The Job pods KEDA starts get no derived policy.
# - The operator serves the gRPC metrics service only while it leads
#   (pkg/metricsservice/server.go upstream), and its readiness probe passes
#   on the standby too. With two replicas, a connection from the metrics API
#   server can reach the standby and fail until the client reconnects.
# - A deploy that changes a ScaledObject can report it ready from the
#   previous Ready condition: KEDA records no observed generation.
# - A cpu or memory trigger needs the resource metrics API (metrics.k8s.io).
#   Kix does not check that the cluster serves it for a ScaledObject.
# - A scale target without `spec.replicas` counts as one replica: Kix adds
#   no spread or disruption budget for it and counts one pod against a
#   ResourceQuota, whatever `minReplicaCount` says.
# - Kix does not refuse a HorizontalPodAutoscaler and a ScaledObject on the
#   same target, and KEDA's webhook, which refuses it, may be skipped
#   (failurePolicy Ignore).
#
# root = the operator Deployment.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  # meta.version, the default tag of every image, and the tag in
  # crds/sources.txt and rbac/sources.txt.
  release = "2.21.1";

  name = scope.instanceName;
  ns = scope.namespaceName;

  vendored = file: (builtins.fromJSON (builtins.readFile ./crds/${file})).spec;
  vendoredRules = file: (builtins.fromJSON (builtins.readFile ./rbac/${file})).rules;

  # Each component's pods carry its own component label, so no Service
  # selects another component's pods.
  componentLabels = component: scope.selectorLabels // { "app.kubernetes.io/component" = component; };
  operatorLabels = componentLabels "operator";
  metricsServerLabels = componentLabels "metrics-apiserver";
  webhooksLabels = componentLabels "admission-webhooks";

  # Names the operator certifies and patches. Plain strings, without the
  # Services' context: the metrics API server and the webhooks require the
  # operator, and their Services select their pods, so a reference from the
  # operator to them would close a cycle.
  operatorServiceName = "${name}-operator";
  metricsServerServiceName = "${name}-metrics-apiserver";
  webhooksServiceName = "${name}-admission-webhooks";
  webhookConfigName = "${name}-admission";
  certSecretName = "${name}-certs";
  certDir = "/certs";
  # The API server routes external.metrics.k8s.io v1beta1 by this name, and
  # the operator patches the APIService of this name (cmd/operator/main.go).
  apiServiceName = "v1beta1.external.metrics.k8s.io";

  # Ports from the flag defaults in cmd/operator/main.go,
  # cmd/webhooks/main.go, and the release manifest's --secure-port.
  ports = {
    metrics = 8080;
    health = 8081;
    grpc = 9666;
    metricsApi = 6443;
    webhook = 9443;
  };
  metricsServiceName = "${name}-operator-metrics";

  # The images' user (USER 65532:65532 in Dockerfile, Dockerfile.adapter,
  # and Dockerfile.webhooks upstream).
  uid = 65532;

  tcp = port: {
    inherit port;
    protocol = "TCP";
  };

  fieldRef = path: { valueFrom.fieldRef.fieldPath = path; };

  # The release manifest's container hardening, shared by the three
  # components.
  containerSecurity = {
    allowPrivilegeEscalation = false;
    capabilities.drop = [ "ALL" ];
    readOnlyRootFilesystem = true;
  };
  podSecurity = {
    runAsNonRoot = true;
    runAsUser = uid;
    runAsGroup = uid;
    seccompProfile.type = "RuntimeDefault";
  };

  # The release manifest's zap flags. extraArgs replaces any of them by
  # setting the same flag.
  logDefaults = [
    "--zap-log-level=info"
    "--zap-encoder=console"
    "--zap-time-encoding=rfc3339"
  ];

  certFlagReason = "this package manages KEDA's TLS certificates, Service names, and CA bundle patching automatically using Secret ${certSecretName}.";

  # The operator dials the addresses in these kinds' specs: trigger
  # sources, and the secret stores a TriggerAuthentication names.
  scalerFacts = {
    endpoint = "terminate";
    podSelector = operatorLabels;
    podNamespace = ns;
  };

  # KEDA writes Ready on ScaledObjects and ScaledJobs, False with a reason
  # when a reconcile fails and True once it succeeds, and requeues a failed
  # reconcile (controllers/keda/scaledobject_controller.go). The conditions
  # carry no observedGeneration and the status has none.
  ready = {
    condition = {
      type = "Ready";
      status = "True";
    };
    observedGeneration = false;
  };
in
{
  meta = {
    version = release;
    description = "Kubernetes Event-driven Autoscaling (KEDA) for scaling Deployments, StatefulSets, and Jobs from external metrics and queues";
    owner = "platform";
    defaultAliases = [ "keda" ];
    conflictsWith = [
      {
        key = "cluster:keda";
        reason = "Only one v1beta1.external.metrics.k8s.io APIService can exist in a cluster, and the KEDA operator watches all namespaces.";
      }
    ];
    # The annotations KEDA reads on ScaledObjects and ScaledJobs (the
    # *.keda.sh keys in apis/keda/v1alpha1 upstream).
    annotationDomains = [
      "autoscaling.keda.sh"
      "scaledobject.keda.sh"
      "scaledjob.keda.sh"
      "validations.keda.sh"
    ];
    # The Kubernetes versions upstream tests KEDA 2.21 against, from the
    # compatibility matrix in its cluster documentation. No version outside
    # it is known to fail. Move `supported` with `release`.
    k8s.supported = {
      minVersion = "1.34";
      maxVersion = "1.36";
      source = "the compatibility matrix at keda.sh/docs/2.21/operate/cluster";
    };
    network.intents = {
      # The API server proxies external.metrics.k8s.io to the metrics API
      # server's pods.
      metricsApi.ingress = [
        {
          from = "apiserver";
          ports = [ (tcp ports.metricsApi) ];
        }
      ];
      # The API server calls the admission webhooks.
      webhooks.ingress = [
        {
          from = "apiserver";
          ports = [ (tcp ports.webhook) ];
        }
      ];
    };
  };

  assertions =
    { config, ... }:
    map
      (
        option:
        kix.image.checkRelease {
          image = lib.getAttrFromPath (lib.splitString "." option) config;
          inherit option release;
          reason = "this package's CustomResourceDefinitions and the operator's RBAC roles are copied from the KEDA ${release} release manifests";
          fix = "To update the package itself in Kix, set release in kix/packages/experimental/keda/default.nix, update the version tags in crds/sources.txt and rbac/sources.txt, and run uv run scripts/vendor-crds.py keda.";
        }
      )
      (
        [ "image" ]
        ++
          builtins.filter
            (option: (lib.getAttrFromPath (lib.splitString "." option) config).tag != config.image.tag)
            [
              "metricsServer.image"
              "webhooks.image"
            ]
      );

  options = {
    image = kix.options.image {
      repository = "ghcr.io/kedacore/keda";
      tag = release;
      digest = "sha256:d09d92c0a310e3057a3c54df387b99abf2bf31352218dbe1adcb00e807886488";
      description = "Container image for the KEDA operator. Its major.minor version must match this package's KEDA release series. By default, `metricsServer.image.tag` and `webhooks.image.tag` match `image.tag`.";
    };

    # The release manifest's values for every component.
    resources = kix.options.resources {
      requests = {
        cpu = "100m";
        memory = "100Mi";
      };
      limits = {
        cpu = "1";
        memory = "1000Mi";
      };
      description = "CPU and memory requests and limits for the operator container. Unset fields keep their defaults; set a field to `null` to remove its default.";
    };

    env = kix.options.env // {
      description = "Extra environment variables for the operator container, such as `KEDA_HTTP_DEFAULT_TIMEOUT` or `WATCH_LABEL_SELECTOR`. Each value can be a string or a `valueFrom` source (such as a `fieldRef`, or a `secretKeyRef` using `kix.untrackedRef`). `POD_NAMESPACE` and `WATCH_NAMESPACE` are rejected because the package sets the pod namespace and watches all namespaces.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--kube-api-qps=40" ];
      description = "Extra command-line flags passed to the operator. Passing `--zap-log-level`, `--zap-encoder`, or `--zap-time-encoding` overrides the package default. Flags that control leader election, listening ports, cluster domain, or TLS certificates are rejected.";
    };

    metricsServer = {
      image = kix.options.image {
        repository = "ghcr.io/kedacore/keda-metrics-apiserver";
        tag = release;
        digest = "sha256:747e376b3e80dc4f72bf4f7043f47cc4cdb56f34b1aed9531789f474996e1c84";
        tagText = "config.image.tag";
        description = "Container image for the metrics API server. Defaults `tag` to `image.tag`, and its major.minor version must match this package's KEDA release series.";
      };

      resources = kix.options.resources {
        requests = {
          cpu = "100m";
          memory = "100Mi";
        };
        limits = {
          cpu = "1";
          memory = "1000Mi";
        };
        description = "CPU and memory requests and limits for the metrics API server container. Unset fields keep their defaults; set a field to `null` to remove its default.";
      };

      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "--zap-log-level=info" ];
        description = "Extra command-line flags passed to the metrics API server. Passing `--zap-log-level` overrides the package default (`--zap-log-level=error`). Flags that control the HTTPS port, TLS certificates, or operator gRPC address are rejected.";
      };
    };

    webhooks = {
      image = kix.options.image {
        repository = "ghcr.io/kedacore/keda-admission-webhooks";
        tag = release;
        digest = "sha256:5f4b0b0f7831b9f53738be85e99449a1747a5effa970305fe602455ab0f4fcd3";
        tagText = "config.image.tag";
        description = "Container image for the admission webhooks. Defaults `tag` to `image.tag`, and its major.minor version must match this package's KEDA release series.";
      };

      resources = kix.options.resources {
        requests = {
          cpu = "100m";
          memory = "100Mi";
        };
        limits = {
          cpu = "1";
          memory = "1000Mi";
        };
        description = "CPU and memory requests and limits for the admission webhooks container. Unset fields keep their defaults; set a field to `null` to remove its default.";
      };

      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "--cache-miss-to-direct-client=true" ];
        description = "Extra command-line flags passed to the admission webhooks. Passing `--zap-log-level`, `--zap-encoder`, or `--zap-time-encoding` overrides the package default. Flags that control listening ports or the certificate directory are rejected.";
      };
    };

    metrics = kix.options.monitor;
  };

  # The component tags follow the operator's `image.tag` unless the instance
  # sets them.
  config =
    { config, ... }:
    {
      metricsServer.image.tag = lib.mkDefault config.image.tag;
      webhooks.image.tag = lib.mkDefault config.image.tag;
    };

  build = [
    (
      {
        self,
        config,
        clusterConfig,
        prometheus ? null,
        ...
      }:
      let
        inherit (scope.rbac)
          group
          grant
          allow
          watch
          emit
          mkClusterRoleSet
          mkRoleSet
          ;

        subjectsOf = sa: [
          {
            kind = "ServiceAccount";
            name = sa.out.name;
            namespace = ns;
          }
        ];

        mkServiceAccount =
          saName:
          scope.mkResource {
            apiVersion = "v1";
            kind = "ServiceAccount";
            name = saName;
          };

        withPullPolicy =
          image: container:
          container // lib.optionalAttrs (image.pullPolicy != null) { imagePullPolicy = image.pullPolicy; };

        # The Secret the operator creates. The metrics API server and the
        # webhooks cannot start without it, so the deploy applies them once
        # the operator is ready and the Secret exists.
        certVolume = {
          name = "certificates";
          secret.secretName = kix.untrackedRef {
            name = certSecretName;
            kind = "Secret";
            by = self.operator;
          };
        };
        certMount = {
          name = "certificates";
          mountPath = certDir;
          readOnly = true;
        };

        # The three programs read their flags with pflag.
        operatorArgs = kix.mergeArgs {
          inherit scope;
          parser = "gnu";
          args = [
            {
              flags = [ "--leader-elect" ];
              reason = "this package already enables --leader-elect so operator replicas coordinate safely across availability levels.";
            }
            {
              flags = [
                "--enable-cert-rotation=true"
                "--cert-dir=${certDir}"
                "--cert-secret-name=${certSecretName}"
                "--operator-service-name=${operatorServiceName}"
                "--metrics-server-service-name=${metricsServerServiceName}"
                "--webhooks-service-name=${webhooksServiceName}"
                "--validating-webhook-name=${webhookConfigName}"
              ];
              names = [
                "--enable-webhook-patching"
                "--enable-apiservice-patching"
              ];
              reason = certFlagReason;
            }
            {
              flags = [ "--k8s-cluster-domain=${clusterConfig.clusterDomain}" ];
              from = "the cluster's clusterDomain option";
              fix = "Set clusterDomain on the cluster instead, and remove the flag from extraArgs.";
            }
            { defaults = logDefaults; }
            {
              names = [ "--metrics-bind-address" ];
              reason = "the operator's metrics Service and ServiceMonitor scrape port ${toString ports.metrics}.";
            }
            {
              names = [ "--health-probe-bind-address" ];
              reason = "the operator's liveness and readiness probes check port ${toString ports.health}.";
            }
            {
              names = [ "--metrics-service-bind-address" ];
              reason = "the metrics API server and generated network policies connect to the operator's gRPC server on port ${toString ports.grpc}.";
            }
          ];
        } config.extraArgs;

        operatorEnv = kix.mkEnvVars (
          kix.mergeEnv {
            inherit scope;
            owned = [
              {
                vars.POD_NAMESPACE = fieldRef "metadata.namespace";
                from = "the pod's metadata.namespace so the operator stores its leader-election lease and TLS certificates in the instance namespace";
              }
              {
                vars.WATCH_NAMESPACE = "";
                from = "the package, which sets it to the empty string because KEDA must watch all namespaces to serve its cluster-wide APIService and webhooks";
                fix = "Remove WATCH_NAMESPACE from env.";
              }
            ];
          } config.env
        );

        metricsServerArgs = kix.mergeArgs {
          inherit scope;
          option = "metricsServer.extraArgs";
          parser = "gnu";
          args = [
            {
              flags = [ "--secure-port=${toString ports.metricsApi}" ];
              reason = "the metrics API Service, health probes, and generated network policies use port ${toString ports.metricsApi}.";
            }
            {
              flags = [
                "--cert-dir=${certDir}"
                "--client-ca-file=${certDir}/ca.crt"
                "--tls-cert-file=${certDir}/tls.crt"
                "--tls-private-key-file=${certDir}/tls.key"
              ];
              reason = certFlagReason;
            }
            # The operator's certificate names this Service's FQDN, and the
            # address carries the Service, so the egress to the gRPC port is
            # derived from it.
            {
              flags = [
                "--metrics-service-address=${self.operatorService.out.fqdn}:${toString ports.grpc}"
              ];
              reason = "this package points the metrics API server at the operator's gRPC Service and opens network policy for that connection.";
            }
            {
              names = [ "--metrics-service-grpc-authority" ];
              reason = "the operator's TLS certificate already matches the gRPC Service address that this package configures.";
            }
            # The release manifest logs only errors here.
            { defaults = [ "--zap-log-level=error" ]; }
          ];
        } config.metricsServer.extraArgs;

        webhooksArgs = kix.mergeArgs {
          inherit scope;
          option = "webhooks.extraArgs";
          parser = "gnu";
          args = [
            { defaults = logDefaults; }
            {
              names = [ "--port" ];
              reason = "the webhook Service and generated network policies connect to port ${toString ports.webhook}.";
            }
            {
              names = [ "--cert-dir" ];
              reason = certFlagReason;
            }
            {
              names = [ "--health-probe-bind-address" ];
              reason = "the webhook liveness and readiness probes check port ${toString ports.health}.";
            }
            {
              names = [ "--metrics-bind-address" ];
              reason = "the webhook container exposes metrics on port ${toString ports.metrics}.";
            }
          ];
        } config.webhooks.extraArgs;

        # Every component exits at start when WATCH_NAMESPACE is unset. The
        # empty string means all namespaces, as in the release manifest.
        namespaceEnv = [
          {
            name = "POD_NAMESPACE";
            inherit (fieldRef "metadata.namespace") valueFrom;
          }
          {
            name = "WATCH_NAMESPACE";
            value = "";
          }
        ];

        healthProbes = {
          livenessProbe = {
            httpGet = {
              path = "/healthz";
              port = ports.health;
            };
            initialDelaySeconds = 25;
          };
          readinessProbe = {
            httpGet = {
              path = "/readyz";
              port = ports.health;
            };
            initialDelaySeconds = 20;
          };
        };

        # One entry per kind the webhooks serve, with the entry names of the
        # release manifest's keda-admission configuration.
        webhookEntry =
          {
            entry,
            group,
            plural,
            path,
          }:
          {
            name = entry;
            admissionReviewVersions = [ "v1" ];
            clientConfig.service = {
              name = self.webhookService.out.name;
              namespace = ns;
              inherit path;
              port = 443;
            };
            failurePolicy = "Ignore";
            sideEffects = "None";
            rules = [
              {
                apiGroups = [ group ];
                apiVersions = [ "v1alpha1" ];
                operations = [
                  "CREATE"
                  "UPDATE"
                ];
                resources = [ plural ];
              }
            ];
          };
        webhookKinds = [
          {
            entry = "vscaledobject.kb.io";
            group = "keda.sh";
            plural = "scaledobjects";
            path = "/validate-keda-sh-v1alpha1-scaledobject";
          }
          {
            entry = "vscaledjob.kb.io";
            group = "keda.sh";
            plural = "scaledjobs";
            path = "/validate-keda-sh-v1alpha1-scaledjob";
          }
          {
            entry = "vstriggerauthentication.kb.io";
            group = "keda.sh";
            plural = "triggerauthentications";
            path = "/validate-keda-sh-v1alpha1-triggerauthentication";
          }
          {
            entry = "vsclustertriggerauthentication.kb.io";
            group = "keda.sh";
            plural = "clustertriggerauthentications";
            path = "/validate-keda-sh-v1alpha1-clustertriggerauthentication";
          }
          {
            entry = "vcloudeventsource.kb.io";
            group = "eventing.keda.sh";
            plural = "cloudeventsources";
            path = "/validate-eventing-keda-sh-v1alpha1-cloudeventsource";
          }
          {
            entry = "vclustercloudeventsource.kb.io";
            group = "eventing.keda.sh";
            plural = "clustercloudeventsources";
            path = "/validate-eventing-keda-sh-v1alpha1-clustercloudeventsource";
          }
        ];
      in
      {
        operatorServiceAccount = mkServiceAccount "${name}-operator";
        metricsServerServiceAccount = mkServiceAccount metricsServerServiceName;
        webhooksServiceAccount = mkServiceAccount webhooksServiceName;

        operatorClusterRole = mkClusterRoleSet scope {
          subjects = subjectsOf self.operatorServiceAccount;
          roles."${name}-operator" = vendoredRules "clusterrole-keda-operator.json";
        };
        # Secrets for its certificates and leases for leader election, in
        # its own namespace.
        operatorRole = mkRoleSet scope {
          subjects = subjectsOf self.operatorServiceAccount;
          roles."${name}-operator" = vendoredRules "role-keda-operator.json";
        };

        # The webhooks read these through their informer cache, which lists
        # and watches (apis/keda/v1alpha1/scaledobject_webhook.go). Upstream's
        # chart grants LimitRanges list only; the cache needs watch too.
        webhooksClusterRole = mkClusterRoleSet scope {
          subjects = subjectsOf self.webhooksServiceAccount;
          roles.${webhooksServiceName} = grant [
            (allow [
              "list"
              "watch"
            ] (group "autoscaling" [ "horizontalpodautoscalers" ]).horizontalpodautoscalers)
            (allow [ "list" "watch" ] (group "keda.sh" [ "scaledobjects" ]).scaledobjects)
            (allow [ "list" "watch" ] (group "" [ "limitranges" ]).limitranges)
            (
              [
                (group "apps" [ "deployments" ]).deployments
                (group "apps" [ "statefulsets" ]).statefulsets
              ]
              |> watch
            )
            (emit (group "events.k8s.io" [ "events" ]).events)
          ];
        };

        # The HorizontalPodAutoscaler controller reads the metrics KEDA
        # serves, as upstream's chart grants
        # (templates/metrics-server/clusterrole.yaml).
        externalMetricsReader = mkClusterRoleSet scope {
          subjects = [
            {
              kind = "ServiceAccount";
              name = "horizontal-pod-autoscaler";
              namespace = "kube-system";
            }
          ];
          roles."${name}-external-metrics-reader" = grant [
            (allow [ "get" ] (group "external.metrics.k8s.io" [ "externalmetrics" ]).externalmetrics)
          ];
        };

        # Delegated authentication and authorization: the metrics API server
        # reviews each caller's token and access through the API server.
        metricsServerAuthDelegator = scope.mkClusterResource {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "ClusterRoleBinding";
          name = "${metricsServerServiceName}-auth-delegator";
          extra = {
            roleRef = {
              apiGroup = "rbac.authorization.k8s.io";
              kind = "ClusterRole";
              name = "system:auth-delegator";
            };
            subjects = subjectsOf self.metricsServerServiceAccount;
          };
        };

        # The requestheader client CA the API server proxies with lives in
        # ConfigMap kube-system/extension-apiserver-authentication.
        metricsServerAuthReader = (scope.forNamespace "kube-system").mkResource {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "RoleBinding";
          name = "${metricsServerServiceName}-auth-reader";
          extra = {
            roleRef = {
              apiGroup = "rbac.authorization.k8s.io";
              kind = "Role";
              name = "extension-apiserver-authentication-reader";
            };
            subjects = subjectsOf self.metricsServerServiceAccount;
          };
        };

        # Upstream's keda:edit and keda:view, which the aggregation labels
        # fold into the built-in admin, edit, and view roles.
        aggregatedRoles =
          lib.mapAttrs
            (
              suffix: file:
              scope.mkClusterResource {
                apiVersion = "rbac.authorization.k8s.io/v1";
                kind = "ClusterRole";
                name = "${name}-${suffix}";
                labels =
                  lib.filterAttrs (k: _: lib.hasPrefix "rbac.authorization.k8s.io/" k)
                    (builtins.fromJSON (builtins.readFile ./rbac/${file})).metadata.labels;
                extra.rules = vendoredRules file;
              }
            )
            {
              edit = "clusterrole-keda_edit.json";
              view = "clusterrole-keda_view.json";
            };

        # The operator watches every kind, so every definition is applied.
        # None holds data: they describe autoscaling, and deleting one
        # deletes only the HorizontalPodAutoscaler or Jobs KEDA made for it.
        crds = {
          scaledObjects = scope.mkCRD {
            spec = vendored "scaledobjects.keda.sh.json";
            readiness = ready;
            holdsData = false;
            controller = self.operator;
            factBehavior = scalerFacts;
            usesAtLeast = _: { };
          };
          scaledJobs = scope.mkCRD {
            spec = vendored "scaledjobs.keda.sh.json";
            readiness = ready;
            holdsData = false;
            controller = self.operator;
            factBehavior = scalerFacts;
          };
          # Neither authentication kind reports conditions.
          triggerAuthentications = scope.mkCRD {
            spec = vendored "triggerauthentications.keda.sh.json";
            holdsData = false;
            controller = self.operator;
            factBehavior = scalerFacts;
            usesAtLeast = _: { };
          };
          clusterTriggerAuthentications = scope.mkCRD {
            spec = vendored "clustertriggerauthentications.keda.sh.json";
            holdsData = false;
            controller = self.operator;
            factBehavior = scalerFacts;
            usesAtLeast = _: { };
          };
          cloudEventSources = scope.mkCRD {
            spec = vendored "cloudeventsources.eventing.keda.sh.json";
            holdsData = false;
            controller = self.operator;
            usesAtLeast = _: { };
          };
          clusterCloudEventSources = scope.mkCRD {
            spec = vendored "clustercloudeventsources.eventing.keda.sh.json";
            holdsData = false;
            controller = self.operator;
            usesAtLeast = _: { };
          };
        };

        operator = scope.mkDeployment {
          name = "${name}-operator";
          requires =
            builtins.attrValues self.crds
            ++ builtins.attrValues self.operatorClusterRole
            ++ builtins.attrValues self.operatorRole;
          spec = {
            # Leader election keeps one operator active; a standby on
            # another node covers `node` and `zone`.
            replicas = kix.availability.pick availability {
              none = 1;
              pod = 1;
              node = 2;
              zone = 2;
            };
            selector.matchLabels = operatorLabels;
            template = {
              metadata.labels = operatorLabels;
              spec = {
                serviceAccount = self.operatorServiceAccount;
                # The release manifest's value.
                terminationGracePeriodSeconds = 10;
                securityContext = podSecurity;
                # Service links would put KEDA_* variables from this
                # instance's Service names into the environment KEDA reads.
                enableServiceLinks = false;
                containers = [
                  (withPullPolicy config.image (
                    {
                      name = "keda-operator";
                      image = kix.image.ref config.image;
                      command = [ "/keda" ];
                      args = operatorArgs;
                      env = operatorEnv;
                      ports = [
                        (kix.port "metrics" ports.metrics)
                        (kix.port "grpc" ports.grpc)
                      ];
                      resources = config.resources;
                      securityContext = containerSecurity;
                      volumeMounts = [ certMount ];
                    }
                    // healthProbes
                  ))
                ];
                volumes = [
                  {
                    name = "certificates";
                    secret = {
                      # The operator creates this Secret when it starts.
                      secretName = kix.untrackedRef {
                        name = certSecretName;
                        by = "self";
                      };
                      optional = true;
                    };
                  }
                ];
              };
            };
          };
        };

        operatorService =
          self.operator
          |> kix.service.fromWorkload {
            name = operatorServiceName;
            labels."app.kubernetes.io/component" = "operator";
            ports = [
              {
                name = "grpc";
                port = ports.grpc;
                targetPort = "grpc";
                protocol = "TCP";
                appProtocol = "grpc";
              }
            ];
          }
          |> scope.mkResource;

        metricsService =
          if config.metrics.enabled && prometheus != null then
            self.operator
            |> kix.service.fromWorkload {
              name = metricsServiceName;
              labels."app.kubernetes.io/component" = "operator-metrics";
              ports = [
                {
                  name = "metrics";
                  port = ports.metrics;
                  targetPort = "metrics";
                  protocol = "TCP";
                }
              ];
            }
            |> scope.mkResource
          else
            null;

        metricsServer = scope.mkDeployment {
          name = metricsServerServiceName;
          requires = [
            self.metricsServerAuthDelegator
            self.metricsServerAuthReader
          ];
          spec = {
            replicas = kix.availability.pick availability {
              none = 1;
              pod = 2;
              node = 2;
              zone = 2;
            };
            selector.matchLabels = metricsServerLabels;
            template = {
              metadata.labels = metricsServerLabels;
              spec = {
                serviceAccount = self.metricsServerServiceAccount;
                # The server holds no state; 30 is the Kubernetes default,
                # written out for the reliability.gracefulShutdown rule.
                terminationGracePeriodSeconds = 30;
                securityContext = podSecurity;
                # Service links would put KEDA_* variables from this
                # instance's Service names into the environment KEDA reads.
                enableServiceLinks = false;
                containers = [
                  (withPullPolicy config.metricsServer.image {
                    name = "keda-metrics-apiserver";
                    image = kix.image.ref config.metricsServer.image;
                    command = [ "/keda-adapter" ];
                    args = metricsServerArgs;
                    env = namespaceEnv;
                    ports = [
                      (kix.port "https" ports.metricsApi)
                      (kix.port "metrics" ports.metrics)
                    ];
                    livenessProbe = {
                      httpGet = {
                        path = "/healthz";
                        port = ports.metricsApi;
                        scheme = "HTTPS";
                      };
                      initialDelaySeconds = 5;
                    };
                    readinessProbe = {
                      httpGet = {
                        path = "/readyz";
                        port = ports.metricsApi;
                        scheme = "HTTPS";
                      };
                      initialDelaySeconds = 5;
                    };
                    resources = config.metricsServer.resources;
                    securityContext = containerSecurity;
                    volumeMounts = [
                      {
                        name = "tmp";
                        mountPath = "/tmp";
                      }
                      certMount
                    ];
                  })
                ];
                volumes = [
                  {
                    name = "tmp";
                    emptyDir = { };
                  }
                  certVolume
                ];
              };
            };
          };
        };

        metricsServerService =
          self.metricsServer
          |> kix.service.fromWorkload {
            name = metricsServerServiceName;
            labels."app.kubernetes.io/component" = "metrics-apiserver";
            ports = [
              {
                name = "https";
                port = 443;
                targetPort = "https";
                protocol = "TCP";
                appProtocol = "https";
              }
            ];
          }
          |> scope.mkResource;

        apiService = scope.mkClusterResource {
          apiVersion = "apiregistration.k8s.io/v1";
          kind = "APIService";
          name = apiServiceName;
          spec = {
            group = "external.metrics.k8s.io";
            version = "v1beta1";
            service = {
              name = self.metricsServerService.out.name;
              namespace = ns;
              port = 443;
            };
            groupPriorityMinimum = 100;
            versionPriority = 100;
          };
        };

        webhooks = scope.mkDeployment {
          name = webhooksServiceName;
          requires = builtins.attrValues self.webhooksClusterRole;
          spec = {
            replicas = kix.availability.pick availability {
              none = 1;
              pod = 2;
              node = 2;
              zone = 2;
            };
            selector.matchLabels = webhooksLabels;
            template = {
              metadata.labels = webhooksLabels;
              spec = {
                serviceAccount = self.webhooksServiceAccount;
                # The release manifest's value.
                terminationGracePeriodSeconds = 10;
                securityContext = podSecurity;
                # Service links would put KEDA_* variables from this
                # instance's Service names into the environment KEDA reads.
                enableServiceLinks = false;
                containers = [
                  (withPullPolicy config.webhooks.image (
                    {
                      name = "keda-admission-webhooks";
                      image = kix.image.ref config.webhooks.image;
                      command = [ "/keda-admission-webhooks" ];
                      args = webhooksArgs;
                      env = namespaceEnv;
                      ports = [
                        (kix.port "webhook" ports.webhook)
                        (kix.port "metrics" ports.metrics)
                      ];
                      resources = config.webhooks.resources;
                      securityContext = containerSecurity;
                      volumeMounts = [ certMount ];
                    }
                    // healthProbes
                  ))
                ];
                volumes = [ certVolume ];
              };
            };
          };
        };

        webhookService =
          self.webhooks
          |> kix.service.fromWorkload {
            name = webhooksServiceName;
            labels."app.kubernetes.io/component" = "admission-webhooks";
            ports = [
              {
                name = "https";
                port = 443;
                targetPort = "webhook";
                protocol = "TCP";
              }
            ];
          }
          |> scope.mkResource;

        validatingWebhook = scope.mkClusterResource {
          apiVersion = "admissionregistration.k8s.io/v1";
          kind = "ValidatingWebhookConfiguration";
          name = webhookConfigName;
          extra.webhooks = map webhookEntry webhookKinds;
        };

        root = {
          resource = self.operator;
          # Nothing else references these parts, so the PackageInstance
          # reaches them only through this list.
          requires = [
            self.apiService
            self.validatingWebhook
          ]
          ++ builtins.attrValues self.aggregatedRoles
          ++ builtins.attrValues self.externalMetricsReader
          ++ builtins.filter (r: r != null) [ self.metricsService ];
          out = {
            crds = {
              ScaledObject = self.crds.scaledObjects;
              ScaledJob = self.crds.scaledJobs;
              TriggerAuthentication = self.crds.triggerAuthentications;
              ClusterTriggerAuthentication = self.crds.clusterTriggerAuthentications;
            };
            version = kix.image.version config.image;
          };
        };
      }
    )

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
        sel = ''namespace="${ns}",service="${metricsServiceName}"'';
        operator = "KEDA operator ${ns}/${name}";
      in
      kix.monitor {
        service = "metricsService";
        alerts = {
          KedaOperatorDown = {
            expr = "sum by (namespace, service) (up{${sel}}) == 0 or absent(up{${sel}})";
            "for" = "10m";
            severity = "warning";
            summary = "The KEDA operator is down.";
            description = "Prometheus could not scrape any replica of the ${operator} for 10 minutes. While the operator is down, KEDA cannot scale workloads to or from zero, and its HorizontalPodAutoscalers receive no external metrics. Check the operator Deployment and pod logs in namespace ${ns}.";
          };
          # KEDA's own `namespace` label (the ScaledObject's) arrives as
          # `exported_namespace`, beside the scrape's `namespace`.
          KedaScalerErrors = {
            expr = "sum by (namespace, service, exported_namespace, scaledObject, scaler, type) (rate(keda_scaler_detail_errors_total{${sel}}[5m])) > 0";
            "for" = "15m";
            severity = "warning";
            summary = "A KEDA trigger cannot read its source.";
            description = "The {{ $labels.scaler }} trigger on {{ $labels.type }} {{ $labels.exported_namespace }}/{{ $labels.scaledObject }} has failed to read its source for 15 minutes, so the ${operator} cannot scale from this trigger. Check the KEDA operator logs for the connection or authentication error, and verify that network policy allows the operator pods to reach the source.";
          };
          KedaOperatorReconcileErrors = kix.reconcileErrorsAlert {
            selector = sel;
            inherit operator;
            summary = "The KEDA operator is failing to reconcile resources.";
            impact = "ScaledObjects or ScaledJobs managed by that controller may be out of date";
            nextStep = "Check the operator logs for the failing resource and error.";
          };
        };
      } args
    )
  ];
}

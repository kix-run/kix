# Tests for kix/packages/experimental/keda: the builders' label exclusion,
# the operator egress derived from a trigger address, the names the
# operator certifies and patches, the metrics API server's operator
# address, the one-per-cluster refusal, the owned flags and variables, the
# release checks, and the metrics and alert gating. KEDA runs in namespace
# `keda` and the consumer in `app`.

{
  lib,
  kixKeys,
  kixlib,
  mkCluster,
  netpolOn,
  manifests,
  ofKind,
  byName,
  evalFails,
  prometheusStub,
  alertRulesOf,
  allSelect,
  ...
}:

let
  kedaPackage = import ../../../packages/experimental/keda;

  # A Service the consumer's trigger reads, and a ScaledObject and a
  # ScaledJob built through the builders.
  consumer = {
    meta = {
      version = "test";
      description = "KEDA consumer";
      owner = "test";
    };
    build =
      {
        self,
        scope,
        keda,
        ...
      }:
      {
        source = scope.mkDeployment {
          name = "source";
          spec = {
            replicas = 1;
            selector.matchLabels = scope.selectorLabels;
            template.spec.containers = [
              {
                name = "source";
                image = "registry.example/source:1";
                ports = [
                  {
                    name = "metrics";
                    containerPort = 9090;
                  }
                ];
              }
            ];
          };
        };
        sourceService =
          self.source
          |> kixlib.service.fromWorkload {
            name = "source";
            ports = [
              {
                name = "metrics";
                port = 9090;
                targetPort = "metrics";
              }
            ];
          }
          |> scope.mkResource;

        scaler = scope.mkCR keda.out.crds.ScaledObject {
          name = "worker";
          spec = {
            scaleTargetRef.name = self.source.out.name;
            triggers = [
              {
                type = "prometheus";
                metadata = {
                  serverAddress = self.sourceService.out.url { };
                  query = "vector(1)";
                  threshold = "1";
                };
              }
            ];
          };
        };
        jobs = scope.mkCR keda.out.crds.ScaledJob {
          name = "batch";
          spec = {
            jobTargetRef.template.spec.containers = [
              {
                name = "batch";
                image = "registry.example/batch:1";
              }
            ];
            triggers = [
              {
                type = "cron";
                metadata = {
                  timezone = "UTC";
                  start = "0 * * * *";
                  end = "30 * * * *";
                  desiredReplicas = "1";
                };
              }
            ];
          };
        };
        auth = scope.mkCR keda.out.crds.TriggerAuthentication {
          name = "source";
          spec.secretTargetRef = [ ];
        };

        root = {
          resource = self.source;
          requires = [
            self.scaler
            self.jobs
            self.auth
          ];
        };
      };
  };

  clusterWith =
    {
      config ? { },
      modules ? [ ],
    }:
    mkCluster (
      [
        {
          # The metrics API server's RoleBinding lives in kube-system.
          namespaces.kube-system = { };
          # Not cluster.local, so a name the operator would default is seen.
          clusterDomain = "corp.test";
          instances.keda.keda = {
            package = kedaPackage;
            inherit config;
          };
          instances.app.consumer.package = consumer;
        }
      ]
      ++ modules
    );

  cluster = clusterWith { };
  ms = manifests cluster;
  find = kind: name: byName name (ofKind kind ms);
  argsOf = m: (builtins.head m.spec.template.spec.containers).args;
  flag =
    m: name:
    let
      prefix = "--${name}=";
      hit = lib.findFirst (lib.hasPrefix prefix) null (argsOf m);
    in
    if hit == null then null else lib.removePrefix prefix hit;

  assertionsOf =
    (kedaPackage {
      inherit lib;
      scope = { };
      kix = kixlib;
      availability = null;
    }).assertions;
  failedAssertions =
    config:
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (assertionsOf {
        inherit config;
      })
    );
  tags = operator: metricsServer: webhooks: {
    image.tag = operator;
    metricsServer.image.tag = metricsServer;
    webhooks.image.tag = webhooks;
  };
in
{
  # Every kind a consumer builds has a handle.
  keda-out =
    let
      out = cluster.instances.keda.keda.raw.root.out;
    in
    (
      builtins.attrNames out.crds == [
        "ClusterTriggerAuthentication"
        "ScaledJob"
        "ScaledObject"
        "TriggerAuthentication"
      ]
      && out.version == "2.21.1"
    )
    || throw "keda out: ${builtins.toJSON (builtins.attrNames out.crds)}";

  # Each component exits at start without WATCH_NAMESPACE, and the empty
  # string watches every namespace.
  keda-watch-namespace =
    let
      deployments = map (n: find "Deployment" n) [
        "keda-operator"
        "keda-metrics-apiserver"
        "keda-admission-webhooks"
      ];
      watchOf =
        m:
        lib.findFirst (e: e.name == "WATCH_NAMESPACE") null
          (builtins.head m.spec.template.spec.containers).env;
      missing = builtins.filter (
        m:
        m == null
        ||
          watchOf m != {
            name = "WATCH_NAMESPACE";
            value = "";
          }
      ) deployments;
    in
    missing == [ ]
    || throw "keda WATCH_NAMESPACE not empty on: ${
      builtins.toJSON (map (m: m.metadata.name or null) missing)
    }";

  # Every custom resource requires the operator, so a deploy creates it after
  # the operator and a prune deletes it before, while the operator can still
  # remove finalizer.keda.sh. Ready is the readiness rule, with no observed
  # generation.
  keda-crs-require-operator =
    let
      operator = builtins.unsafeDiscardStringContext cluster.instances.keda.keda.raw.operator.out.identityHash;
      dependsOn = m: lib.splitString "," (m.metadata.annotations.${kixKeys.dependsOn} or "");
      crs = [
        (find "ScaledObject" "worker")
        (find "ScaledJob" "batch")
        (find "TriggerAuthentication" "source")
      ];
      ungated = builtins.filter (m: !(builtins.elem "requires:${operator}" (dependsOn m))) crs;
      so = find "ScaledObject" "worker";
      readiness = builtins.fromJSON so.metadata.annotations.${kixKeys.readiness};
    in
    (
      builtins.all (m: m != null) crs
      && ungated == [ ]
      &&
        readiness == {
          condition = {
            type = "Ready";
            status = "True";
          };
          observedGeneration = false;
        }
    )
    || throw "keda custom resources not gated on the operator ${operator}: ${
      builtins.toJSON (map (m: m.metadata) ungated)
    }";

  # A Service address in a trigger opens the operator's egress to it, in
  # KEDA's namespace, and the Service's ingress from the operator.
  keda-scaler-egress =
    let
      netpol = manifests (clusterWith {
        modules = [ netpolOn ];
      });
      policy = name: byName name (ofKind "CiliumNetworkPolicy" netpol);
      egress = policy "app-consumer-scaledobject-worker-egress";
      ingress = policy "app-consumer-scaledobject-worker-to-source-ingress";
      operatorPods = {
        "app.kubernetes.io/component" = "operator";
        "app.kubernetes.io/instance" = "keda";
        "app.kubernetes.io/name" = "keda";
      };
    in
    (
      egress != null
      && egress.metadata.namespace == "keda"
      && egress.spec.endpointSelector.matchLabels == operatorPods
      && ingress != null
      && ingress.metadata.namespace == "app"
    )
    || throw "keda scaler egress: ${
      builtins.toJSON (map (p: p.metadata.name) (ofKind "CiliumNetworkPolicy" netpol))
    }";

  # The operator certifies and patches the objects the package renders, by
  # the names it renders them under, and nothing else writes caBundle.
  keda-certificate-names =
    let
      operator = find "Deployment" "keda-operator";
      webhook = find "ValidatingWebhookConfiguration" (flag operator "validating-webhook-name");
      apiService = find "APIService" "v1beta1.external.metrics.k8s.io";
      mounted =
        d:
        (lib.findFirst (v: v.name == "certificates") { } d.spec.template.spec.volumes).secret.secretName
          or null;
      certSecret = flag operator "cert-secret-name";
    in
    (
      find "Service" (flag operator "operator-service-name") != null
      && find "Service" (flag operator "metrics-server-service-name") != null
      && find "Service" (flag operator "webhooks-service-name") != null
      && flag operator "k8s-cluster-domain" == "corp.test"
      && webhook != null
      && builtins.length webhook.webhooks == 6
      && builtins.all (
        e:
        !(e.clientConfig ? caBundle)
        && e.failurePolicy == "Ignore"
        && e.clientConfig.service.name == flag operator "webhooks-service-name"
      ) webhook.webhooks
      && !(apiService.spec ? caBundle)
      && !(apiService.spec ? insecureSkipTLSVerify)
      && apiService.spec.service.name == flag operator "metrics-server-service-name"
      && mounted operator == certSecret
      && mounted (find "Deployment" "keda-metrics-apiserver") == certSecret
      && mounted (find "Deployment" "keda-admission-webhooks") == certSecret
    )
    || throw "keda certificate names: ${builtins.toJSON (argsOf operator)}";

  # The metrics API server dials the operator's gRPC Service by its FQDN,
  # which the operator's certificate names.
  keda-metrics-server-address =
    let
      address = flag (find "Deployment" "keda-metrics-apiserver") "metrics-service-address";
    in
    address == "keda-operator.keda.svc.corp.test:9666"
    || throw "keda metrics server address: ${toString address}";

  # A second instance, here in another namespace, is refused; one builds.
  # The annotation-domain check fires first on two instances, so the
  # conflictsWith entry is tested with the domains removed.
  keda-one-per-cluster =
    let
      withoutDomains = lib.setFunctionArgs (
        args:
        let
          p = kedaPackage args;
        in
        p // { meta = removeAttrs p.meta [ "annotationDomains" ]; }
      ) (builtins.functionArgs kedaPackage);
      clusterOf =
        package: namespaces:
        mkCluster [
          {
            namespaces.kube-system = { };
            instances = lib.genAttrs namespaces (_: {
              keda.package = package;
            });
          }
        ];
    in
    (
      evalFails (
        clusterOf kedaPackage [
          "keda"
          "other"
        ]
      )
      && evalFails (
        clusterOf withoutDomains [
          "keda"
          "other"
        ]
      )
      && !evalFails (clusterOf kedaPackage [ "other" ])
      && !evalFails (clusterOf withoutDomains [ "other" ])
    )
    || throw "keda one per cluster: two instances evaluated";

  # Owned flags and variables are refused; others pass through.
  keda-owned-settings =
    let
      with' = config: clusterWith { inherit config; };
      operatorArgs = argsOf (
        byName "keda-operator" (
          ofKind "Deployment" (
            manifests (with' {
              extraArgs = [
                "--kube-api-qps=40"
                "--zap-log-level=debug"
              ];
            })
          )
        )
      );
    in
    (
      evalFails (with' {
        extraArgs = [ "--cert-dir=/tmp" ];
      })
      && evalFails (with' {
        extraArgs = [ "--k8s-cluster-domain=example.org" ];
      })
      && evalFails (with' {
        metricsServer.extraArgs = [ "--metrics-service-address=x:1" ];
      })
      && evalFails (with' {
        webhooks.extraArgs = [ "--port=1" ];
      })
      && evalFails (with' {
        env.WATCH_NAMESPACE = "app";
      })
      && !evalFails (with' {
        env.KEDA_HTTP_DEFAULT_TIMEOUT = "5000";
      })
      && builtins.elem "--kube-api-qps=40" operatorArgs
      && builtins.elem "--zap-log-level=debug" operatorArgs
      && !(builtins.elem "--zap-log-level=info" operatorArgs)
    )
    || throw "keda owned settings: ${builtins.toJSON operatorArgs}";

  # Every image must be of the release's minor; a component that follows
  # the operator's tag is checked through it.
  keda-release-check =
    (
      failedAssertions (tags "2.21.1" "2.21.1" "2.21.1") == [ ]
      && failedAssertions (tags "2.21.3" "2.21.3" "2.21.3") == [ ]
      && builtins.length (failedAssertions (tags "2.20.2" "2.20.2" "2.20.2")) == 1
      && builtins.length (failedAssertions (tags "2.21.1" "2.20.2" "2.21.1")) == 1
      && builtins.length (failedAssertions (tags "2.21.1" "2.21.1" "2.22.0")) == 1
    )
    || throw "keda release check: ${
      builtins.toJSON (failedAssertions (tags "2.20.2" "2.20.2" "2.20.2"))
    }";

  # crds/sources.txt and rbac/sources.txt fetch the release the package pins.
  keda-sources-match-release =
    let
      release =
        (kedaPackage {
          inherit lib;
          scope = { };
          kix = { };
          availability = null;
        }).meta.version;
      urlsOf =
        dir:
        builtins.filter (l: l != "" && !lib.hasPrefix "#" l) (
          lib.splitString "\n" (
            builtins.readFile (../../../packages/experimental/keda + "/${dir}/sources.txt")
          )
        );
      urls = urlsOf "crds" ++ urlsOf "rbac";
    in
    (urls != [ ] && lib.all (lib.hasInfix "/v${release}/keda-${release}") urls)
    || throw "keda sources.txt is not at ${release}: ${builtins.toJSON urls}";

  # The metrics Service, the ServiceMonitor, and the rules need a prometheus
  # dependency and metrics.enabled; every rule selects the metrics Service.
  keda-metrics =
    let
      withPrometheus =
        config:
        manifests (clusterWith {
          inherit config;
          modules = [ { instances.monitoring.prometheus.package = prometheusStub; } ];
        });
      on = withPrometheus { };
      off = withPrometheus { metrics.enabled = false; };
      rules = alertRulesOf "PrometheusRule" "keda" on;
    in
    (
      byName "keda-operator-metrics" (ofKind "Service" on) != null
      && builtins.length (ofKind "ServiceMonitor" on) == 1
      && allSelect ''namespace="keda",service="keda-operator-metrics"'' rules
      &&
        builtins.attrNames rules == [
          "KedaOperatorDown"
          "KedaOperatorReconcileErrors"
          "KedaScalerErrors"
        ]
      && byName "keda-operator-metrics" (ofKind "Service" off) == null
      && ofKind "PrometheusRule" off == [ ]
      && byName "keda-operator-metrics" (ofKind "Service" ms) == null
      && ofKind "PrometheusRule" ms == [ ]
    )
    || throw "keda metrics: ${builtins.toJSON (map (s: s.metadata.name) (ofKind "Service" on))}";
}

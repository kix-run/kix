# Tests for the ingress-nginx package: every RBAC object it builds reaches
# the manifest set, each refusal fires next to a passing control, metrics
# follow `metrics.enabled` and the prometheus dependency, and two instances
# cannot share one IngressClass.

{
  lib,
  kixlib,
  mkCluster,
  baseInstances,
  manifests,
  ofKind,
  byName,
  evalFails,
  prometheusStub,
  ...
}:

let
  ingressNginx = import ../../../packages/stable/ingress-nginx;

  # One instance in namespace `ingress`, beside the shared DNS provider.
  # `extra` is a second module, for another instance or a prometheus
  # provider.
  clusterWithModule =
    config: extra:
    mkCluster [
      {
        instances.dns = baseInstances.instances.dns;
        instances.ingress.ingress-nginx = {
          package = ingressNginx;
          inherit config;
        };
      }
      extra
    ];
  clusterWith = config: clusterWithModule config { };
  withPrometheus =
    config:
    clusterWithModule config {
      instances.monitoring.prometheus.package = prometheusStub;
    };
  fails = config: evalFails (clusterWith config);

  namesOfKind = kind: cluster: map (m: m.metadata.name) (ofKind kind (manifests cluster));
  controller =
    cluster:
    builtins.head (byName "ingress-nginx" (ofKind "Deployment" (manifests cluster)))
      .spec.template.spec.containers;
  controllerEnv = cluster: (controller cluster).env;
  controllerArgs = cluster: (controller cluster).args;
  controllerService = cluster: byName "ingress-nginx" (ofKind "Service" (manifests cluster));
in
{
  ingress-nginx-renders-cluster-rbac =
    let
      cluster = clusterWith { };
      roles = ofKind "Role" (manifests cluster);
      leaseRole = byName "ingress-nginx" roles;
      sorted = kind: lib.sort lib.lessThan (namesOfKind kind cluster);
    in
    (
      sorted "ClusterRole" == [
        "ingress-ingress-nginx"
        "ingress-ingress-nginx-admission"
      ]
      &&
        sorted "ClusterRoleBinding" == [
          "ingress-ingress-nginx"
          "ingress-ingress-nginx-admission"
        ]
      &&
        sorted "Role" == [
          "ingress-nginx"
          "ingress-nginx-admission"
        ]
      &&
        sorted "RoleBinding" == [
          "ingress-nginx"
          "ingress-nginx-admission"
        ]
      && lib.all (r: r.resources == [ "leases" ]) leaseRole.rules
    )
    || throw "ingress-nginx rbac: ${
      builtins.toJSON (
        map sorted [
          "ClusterRole"
          "ClusterRoleBinding"
          "Role"
          "RoleBinding"
        ]
      )
    }";

  # The controller value carries the namespace, so two instances that render
  # the same IngressClass name differ and fail the duplicate-resource check.
  ingress-nginx-same-class-two-namespaces-fails =
    let
      second = config: {
        instances.other.ingress-nginx = {
          package = ingressNginx;
          inherit config;
        };
      };
      distinct = clusterWithModule { } (second {
        ingressClassName = "other";
      });
      controllers = map (c: c.spec.controller) (ofKind "IngressClass" (manifests distinct));
    in
    evalFails (clusterWithModule { } (second { }))
    && (
      lib.sort lib.lessThan controllers == [
        "k8s.io/ingress-nginx/ingress/ingress-nginx"
        "k8s.io/ingress-nginx/other/other"
      ]
      || throw "ingress-nginx distinct classes: ${builtins.toJSON controllers}"
    );

  ingress-nginx-class-name-checked =
    fails { ingressClassName = "Bad_Name"; }
    && fails { ingressClassName = lib.concatStrings (lib.replicate 240 "a"); }
    && !fails { ingressClassName = "public.example"; };

  ingress-nginx-snippets-need-critical-risk =
    fails { settings."allow-snippet-annotations" = "true"; }
    && !fails {
      settings = {
        "allow-snippet-annotations" = "true";
        "annotations-risk-level" = "Critical";
      };
    }
    && !fails {
      settings = {
        "allow-snippet-annotations" = "true";
        "annotations-risk-level" = "critical";
      };
    };

  # Spellings that Go's strconv.ParseBool reads as true are refused.
  ingress-nginx-snippets-bool-spelling =
    fails { settings."allow-snippet-annotations" = "True"; }
    && fails { settings."allow-snippet-annotations" = "1"; }
    && !fails { settings."allow-snippet-annotations" = "false"; };

  ingress-nginx-service-spec-locked =
    let
      lbClass =
        (controllerService (clusterWith {
          service.spec.loadBalancerClass = "x";
        })).spec;
    in
    fails { service.spec.selector.app = "other"; }
    && fails { service.spec.ports = [ ]; }
    && (
      (lbClass.type == "ClusterIP" && lbClass.loadBalancerClass == "x")
      || throw "ingress-nginx loadBalancerClass: ${builtins.toJSON lbClass}"
    );

  ingress-nginx-service-type-checks =
    let
      spec =
        (controllerService (clusterWith {
          service.spec = {
            type = "NodePort";
            externalTrafficPolicy = "Local";
          };
          service.nodePorts.http = 30080;
        })).spec;
      http = lib.findFirst (p: p.name == "http") null spec.ports;
    in
    fails { service.nodePorts.http = 30080; }
    && fails { service.spec.externalTrafficPolicy = "Local"; }
    && (
      (spec.externalTrafficPolicy == "Local" && http.nodePort == 30080)
      || throw "ingress-nginx NodePort: ${builtins.toJSON spec}"
    );

  # A flag matches only as itself or followed by "=", so
  # --ingress-class-by-name passes while --ingress-class is refused.
  ingress-nginx-extra-args-guarded =
    let
      owned = [
        "--publish-service=x"
        "--election-id=x"
        "--controller-class=x"
        "--ingress-class"
        "--configmap=x"
        "--enable-metrics=false"
        "--http-port=8080"
        "--https-port=8443"
        "--healthz-port=1"
        "--validating-webhook=:9443"
        "--validating-webhook-certificate=x"
        "--validating-webhook-key=x"
      ];
      refused = builtins.filter (arg: !fails { extraArgs = [ arg ]; }) owned;
      args = controllerArgs (clusterWith {
        extraArgs = [ "--ingress-class-by-name=true" ];
      });
    in
    (refused == [ ] || throw "ingress-nginx extraArgs accepted: ${builtins.toJSON refused}")
    && lib.last args == "--ingress-class-by-name=true";

  ingress-nginx-env-owned =
    let
      names = map (e: e.name) (
        controllerEnv (clusterWith {
          env.GOMAXPROCS = "2";
        })
      );
    in
    fails { env.POD_NAME = "x"; }
    && fails { env.POD_NAMESPACE = "x"; }
    && fails { env.LD_PRELOAD = null; }
    && (
      lib.all (n: builtins.elem n names) [
        "GOMAXPROCS"
        "LD_PRELOAD"
        "POD_NAME"
        "POD_NAMESPACE"
      ]
      || throw "ingress-nginx env: ${builtins.toJSON names}"
    );

  ingress-nginx-env-untracked-secret =
    let
      license = lib.findFirst (e: e.name == "MAXMIND_LICENSE_KEY") null (
        controllerEnv (clusterWith {
          env.MAXMIND_LICENSE_KEY.valueFrom.secretKeyRef = {
            name = kixlib.untrackedRef "maxmind";
            key = "license-key";
          };
        })
      );
    in
    license.valueFrom.secretKeyRef == {
      name = "maxmind";
      key = "license-key";
    };

  # --enable-metrics follows metrics.enabled alone. The metrics Service and
  # ServiceMonitor also need a prometheus provider.
  ingress-nginx-metrics =
    let
      summary = cluster: {
        flag = builtins.elem "--enable-metrics=true" (controllerArgs cluster);
        service = byName "ingress-nginx-metrics" (ofKind "Service" (manifests cluster)) != null;
        monitors = namesOfKind "ServiceMonitor" cluster;
      };
      on = summary (withPrometheus { });
      off = summary (withPrometheus {
        metrics.enabled = false;
      });
      noProvider = summary (clusterWith { });
    in
    (
      on == {
        flag = true;
        service = true;
        monitors = [ "ingress-nginx" ];
      }
      &&
        off == {
          flag = false;
          service = false;
          monitors = [ ];
        }
      &&
        noProvider == {
          flag = true;
          service = false;
          monitors = [ ];
        }
    )
    || throw "ingress-nginx metrics: ${builtins.toJSON { inherit on off noProvider; }}";
}

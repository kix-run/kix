# Tests for the gateway contract (kix/lib/vocab/gateway.nix): `check` on
# the provider side, `claims` and `require` on the consumer side,
# kix.expose against envoy-gateway, traefik, and kix.mkImport gateways, and
# the traefik package's refusals and alert rules.

{
  lib,
  eval,
  kixlib,
  mkCluster,
  netpolOn,
  manifests,
  ofKind,
  namesOf,
  byName,
  evalFails,
  containerBase,
  alertRulesOf,
  allSelect,
  prometheusStub,
  ...
}:

let
  contract = kixlib.contracts.gateway;
  envoyGateway = import ../../../packages/stable/envoy-gateway;
  traefik = import ../../../packages/stable/traefik;

  importOut.gatewayRef = {
    name = "shared";
    namespace = "gwns";
  };
  providerOut = importOut // {
    listeners = [
      {
        name = "http";
        port = 80;
        protocol = "HTTP";
      }
    ];
    podSelector."app.kubernetes.io/name" = "proxy";
    podNamespace = "gwns";
  };

  depOf = out: {
    inherit out;
    _meta = {
      namespaceName = "gwns";
      instanceName = "gw";
    };
  };
  succeeds = v: (builtins.tryEval (builtins.deepSeq v true)).success;

  # One Deployment and Service on port 8080, exposed with kix.expose.
  backend = {
    meta.version = "test";
    build = [
      (
        {
          self,
          scope,
          kix,
          ...
        }:
        {
          deployment = scope.mkDeployment {
            name = "web";
            spec = {
              replicas = 1;
              selector.matchLabels = scope.selectorLabels;
              template = {
                metadata.labels = scope.selectorLabels;
                spec.containers = [
                  (
                    {
                      name = "web";
                      image = "web:1";
                      ports = [
                        {
                          name = "http";
                          containerPort = 8080;
                        }
                      ];
                    }
                    // containerBase
                  )
                ];
              };
            };
          };
          service = self.deployment |> kix.service.fromWorkload { name = "web"; } |> scope.mkResource;
          root = self.service;
        }
      )
      (kixlib.expose { service = "service"; })
    ];
  };

  # A cluster with `gateway` in gwns and the backend in appns. `extra` is
  # a further module (network policy, for one).
  exposedVia =
    gateway: extra:
    mkCluster [
      extra
      {
        cluster.domain = "test.local";
        instances.gwns.gw = gateway;
        instances.appns.web.package = backend;
      }
    ];

  traefikWith =
    config:
    exposedVia {
      package = traefik;
      inherit config;
    } { };
  traefikUnderPolicy =
    config:
    exposedVia {
      package = traefik;
      inherit config;
    } netpolOn;
in
{
  # A provider out with every field passes `check` unchanged, nulls
  # included; one without listeners, or with only one of podSelector and
  # podNamespace, is refused.
  gateway-check-requires-every-field =
    contract.check "provider gwns/gw" providerOut == providerOut
    && contract.check "provider gwns/gw" (
      providerOut
      // {
        podSelector = null;
        podNamespace = null;
      }
    ) ? podSelector
    && !succeeds (contract.check "provider gwns/gw" importOut)
    && !succeeds (contract.check "provider gwns/gw" (providerOut // { podNamespace = null; }))
    && !succeeds (contract.check "provider gwns/gw" (providerOut // { podSelector = { }; }));

  # A consumer accepts an import with only gatewayRef and refuses one
  # without it. A present optional field is still checked.
  gateway-require-needs-only-gatewayRef =
    let
      missing = contract.problems { listeners = [ ]; };
    in
    contract.problems importOut == [ ]
    && contract.problems providerOut == [ ]
    && builtins.length missing == 1
    && lib.hasInfix "gatewayRef is missing" (builtins.head missing)
    && lib.hasInfix "listeners is not" (
      builtins.head (contract.problems (importOut // { listeners = "http"; }))
    )
    && succeeds (contract.require "x" (depOf importOut))
    && !succeeds (contract.require "x" (depOf { }));

  # An instance claims to be a gateway through out.gatewayRef or the
  # `gateway` alias on the instance or in its package's defaultAliases.
  gateway-claims =
    contract.claims (depOf importOut)
    && contract.claims {
      out = { };
      _meta.aliases = [ "gateway" ];
    }
    && contract.claims {
      out = { };
      _meta.packageMeta.defaultAliases = [ "gateway" ];
    }
    && !contract.claims (depOf { })
    && !contract.claims {
      out = { };
      _meta.aliases = [ "otlp" ];
    };

  # An instance merely named `gateway` (a ConfigMap stub in another
  # namespace, standing in for an OpenTelemetry Collector) is no gateway:
  # kix.expose renders no HTTPRoute, and beside ingress-nginx it routes
  # through an Ingress instead of refusing two routers.
  gateway-name-without-contract-is-ignored =
    let
      notGateway = {
        meta.version = "test";
        build = [
          (
            { self, scope, ... }:
            {
              configMap = scope.mkResource {
                apiVersion = "v1";
                kind = "ConfigMap";
                name = "gateway";
                data.a = "b";
              };
              root = self.configMap;
            }
          )
        ];
      };
      clusterWith =
        extra:
        mkCluster [
          extra
          {
            cluster.domain = "test.local";
            instances.other.gateway.package = notGateway;
            instances.appns.web.package = backend;
          }
        ];
      alone = manifests (clusterWith { });
      withIngress = manifests (clusterWith {
        instances.ingress.ingress-nginx.package = import ../../../packages/stable/ingress-nginx;
      });
    in
    ofKind "HTTPRoute" alone == [ ]
    && byName "web" (ofKind "Ingress" withIngress) != null
    && ofKind "HTTPRoute" withIngress == [ ];

  # kix.expose holds a gateway to the contract: an import without
  # gatewayRef fails, while one with only gatewayRef routes.
  gateway-expose-requires-contract =
    let
      viaImport =
        out:
        exposedVia {
          package = eval.mkImport { inherit out; };
          aliases = [ "gateway" ];
        } { };
      route = byName "web" (ofKind "HTTPRoute" (manifests (viaImport importOut)));
    in
    (builtins.head route.spec.parentRefs).name == "shared"
    && evalFails (viaImport {
      gatewayName = "shared";
    });

  # traefik's root out passes the contract: the HTTPRoute attaches to its
  # Gateway, and under network policy the backend admits the Traefik pods.
  gateway-traefik-routes-and-opens-backend =
    let
      plain = manifests (traefikWith { });
      route = byName "web" (ofKind "HTTPRoute" plain);
      cnps = ofKind "CiliumNetworkPolicy" (manifests (traefikUnderPolicy { }));
      edge = byName "web-from-gateway" cnps;
      rule = builtins.head edge.spec.ingress;
    in
    (
      builtins.head route.spec.parentRefs == {
        name = "gw";
        namespace = "gwns";
      }
      && edge.metadata.namespace == "appns"
      && rule.callerNamespace == "gwns"
      && rule.callerSelector."app.kubernetes.io/name" == "traefik"
      && (builtins.head rule.ports).port == 8080
    )
    || throw "traefik route or edge: ${builtins.toJSON (namesOf cnps)}";

  # envoy-gateway publishes the labels Envoy Gateway puts on the proxy pods
  # and their namespace, so the backend admits the proxies. A merged
  # GatewayClass selects by class; with proxyNamespace null, or another
  # controller, there is no selector and no policy.
  gateway-envoy-opens-backend =
    let
      edgeWith =
        config:
        byName "web-from-gateway" (
          ofKind "CiliumNetworkPolicy" (
            manifests (
              exposedVia {
                package = envoyGateway;
                inherit config;
              } netpolOn
            )
          )
        );
      rule = edge: builtins.head edge.spec.ingress;
      plain = rule (edgeWith { });
      merged = rule (edgeWith {
        proxySpec.mergeGateways = true;
      });
      elsewhere = rule (edgeWith {
        proxyNamespace = "gwns";
      });
    in
    (
      plain.callerNamespace == "envoy-gateway-system"
      &&
        plain.callerSelector == {
          "app.kubernetes.io/name" = "envoy";
          "app.kubernetes.io/component" = "proxy";
          "app.kubernetes.io/managed-by" = "envoy-gateway";
          "gateway.envoyproxy.io/owning-gateway-name" = "gw";
          "gateway.envoyproxy.io/owning-gateway-namespace" = "gwns";
        }
      && (builtins.head plain.ports).port == 8080
      && merged.callerSelector."gateway.envoyproxy.io/owning-gatewayclass" == "gw"
      && !(merged.callerSelector ? "gateway.envoyproxy.io/owning-gateway-name")
      && elsewhere.callerNamespace == "gwns"
      && edgeWith { proxyNamespace = null; } == null
      && edgeWith { controllerName = "example.com/other"; } == null
    )
    || throw "envoy-gateway edge: ${builtins.toJSON plain}";

  # The edge is ingress-only, so a cluster that enforces only egress gets
  # none; the control enforces ingress only.
  gateway-edge-follows-directions =
    let
      edgeUnder =
        directions:
        byName "web-from-gateway" (
          ofKind "CiliumNetworkPolicy" (
            manifests (
              exposedVia { package = traefik; } {
                imports = [ netpolOn ];
                networkPolicy.directions = directions;
              }
            )
          )
        );
    in
    (edgeUnder "egress" == null && edgeUnder "ingress" != null)
    || throw "expected no gateway edge under directions = egress";

  # A Service without a selector gets no edge, which would otherwise select
  # every pod in the namespace. The selected Service beside it still does.
  gateway-edge-skips-selectorless-service =
    let
      twoBackends = {
        meta.version = "test";
        build = [
          (
            { self, scope, ... }:
            {
              deployment = scope.mkDeployment {
                name = "web";
                spec = {
                  replicas = 1;
                  selector.matchLabels = scope.selectorLabels;
                  template = {
                    metadata.labels = scope.selectorLabels;
                    spec.containers = [
                      (
                        {
                          name = "web";
                          image = "web:1";
                          ports = [ { containerPort = 8080; } ];
                        }
                        // containerBase
                      )
                    ];
                  };
                };
              };
              selected = scope.mkResource {
                apiVersion = "v1";
                kind = "Service";
                name = "selected";
                spec = {
                  selector = scope.selectorLabels;
                  ports = [ { port = 8080; } ];
                };
              };
              external = scope.mkResource {
                apiVersion = "v1";
                kind = "Service";
                name = "external";
                spec.ports = [ { port = 9090; } ];
              };
              root = {
                resource = self.selected;
                requires = [ self.deployment ];
              };
            }
          )
          (kixlib.expose {
            paths = [
              {
                path = "/";
                service = "selected";
                port = 8080;
              }
              {
                path = "/ext";
                service = "external";
                port = 9090;
              }
            ];
          })
        ];
      };
      cnps = ofKind "CiliumNetworkPolicy" (
        manifests (mkCluster [
          netpolOn
          {
            cluster.domain = "test.local";
            instances.gwns.gw.package = traefik;
            instances.appns.web.package = twoBackends;
          }
        ])
      );
    in
    (byName "selected-from-gateway" cnps != null && byName "external-from-gateway" cnps == null)
    || throw "selectorless edge: ${builtins.toJSON (namesOf cnps)}";

  # Each listener port is an entrypoint, a container port, and a Service
  # port; the Service is a NodePort on kind's absent loadBalancer binding
  # and a LoadBalancer otherwise.
  gateway-traefik-ports-follow-listeners =
    let
      listeners = [
        {
          name = "http";
          port = 8000;
          protocol = "HTTP";
          allowedRoutes.namespaces.from = "All";
        }
      ];
      ms = manifests (traefikWith {
        inherit listeners;
      });
      svc = byName "gw" (ofKind "Service" ms);
      dep = byName "gw" (ofKind "Deployment" ms);
      args = (builtins.head dep.spec.template.spec.containers).args;
      lbType =
        absent:
        (byName "gw" (
          ofKind "Service" (
            manifests (mkCluster [
              {
                cluster.roles.loadBalancer.binding = if absent then "absent" else "exclusive";
                instances.gwns.gw.package = traefik;
              }
            ])
          )
        )).spec.type;
    in
    map (p: p.port) svc.spec.ports == [ 8000 ]
    && builtins.elem "--entryPoints.http.address=:8000" args
    # No port below 1024, so no sysctl.
    && !(dep.spec.template.spec.securityContext ? sysctls)
    && lbType true == "NodePort"
    && lbType false == "LoadBalancer";

  # Every refusal fails evaluation, beside a control that evaluates.
  gateway-traefik-refusals =
    let
      fails = config: evalFails (traefikWith config);
      tcp = [
        {
          name = "db";
          port = 5432;
          protocol = "TCP";
        }
      ];
    in
    !evalFails (traefikWith {
      extraArgs = [
        "--log.level=INFO"
        "--providers.kubernetesgateway.statusaddress.ip=192.0.2.1"
        # A value argument is not a flag, even one that reads "ping".
        "--accessLog.filePath"
        "ping"
        "-accesslog=true"
      ];
      env.TZ = "UTC";
      service.spec.externalTrafficPolicy = "Local";
    })
    && !evalFails (traefikUnderPolicy { })
    && fails { extraArgs = [ "--entrypoints.HTTP.address=:81" ]; }
    && fails { extraArgs = [ "--PING=false" ]; }
    && fails { extraArgs = [ "-ping=false" ]; }
    && fails { extraArgs = [ "-entrypoints.http.address=:81" ]; }
    && fails { extraArgs = [ "-providers.kubernetesCRD=true" ]; }
    && fails { extraArgs = [ "--providers.kubernetesGateway.labelSelector=a=b" ]; }
    && fails { extraArgs = [ "--providers.kubernetesGateway.statusAddress.service.name=x" ]; }
    && fails { extraArgs = [ "--providers.kubernetesGateway.statusAddress.service.namespace=x" ]; }
    && fails { extraArgs = [ "--providers.kubernetesGateway.experimentalChannel=true" ]; }
    && fails { extraArgs = [ "--metrics.prometheus=true" ]; }
    && fails { extraArgs = [ "--metrics.prometheus.entryPoint=web" ]; }
    && fails { extraArgs = [ "--entryPoints.traefik.address=:9000" ]; }
    && fails { extraArgs = [ "--providers.kubernetesIngressNginx=true" ]; }
    && fails { extraArgs = [ "--providers.knative.namespaces=a" ]; }
    && fails { service.spec.ports = [ { port = 1; } ]; }
    && fails {
      service.spec.externalTrafficPolicy = "Local";
      service.spec.type = "ClusterIP";
    }
    && fails { extraArgs = [ "--providers.kubernetescrd.namespaces=a" ]; }
    && fails { extraArgs = [ "--providers.kubernetesingress" ]; }
    && fails { extraArgs = [ "--configFile=/etc/traefik.yml" ]; }
    && fails { env.TRAEFIK_LOG_LEVEL = "DEBUG"; }
    && fails { service.spec.selector.a = "b"; }
    && fails {
      listeners = [
        {
          name = "http";
          port = 8080;
          protocol = "HTTP";
        }
      ];
    }
    && fails { listeners = tcp; }
    && fails { listeners = [ ]; }
    && evalFails (traefikUnderPolicy {
      listeners = [
        {
          name = "http";
          port = 8000;
          protocol = "HTTP";
        }
      ];
    });

  # traefik's rules select its metrics Service, take their thresholds from
  # the metrics options, and need a prometheus dependency and
  # metrics.enabled.
  gateway-traefik-alerts =
    let
      withPrometheus.instances.monitoring.prometheus.package = prometheusStub;
      rulesOf =
        config: extra:
        alertRulesOf "PrometheusRule" "gw" (
          manifests (
            exposedVia {
              package = traefik;
              inherit config;
            } extra
          )
        );
      rules = rulesOf { } withPrometheus;
      tuned = rulesOf {
        metrics = {
          minCertificateValidity = "21d";
          backendErrorRatio = 0.25;
          backendErrorMinRate = 2;
        };
      } withPrometheus;
    in
    (
      allSelect ''namespace="gwns",service="gw-metrics"'' rules
      &&
        builtins.attrNames rules == [
          "TraefikBackendErrorsHigh"
          "TraefikCertificateExpiringSoon"
          "TraefikDown"
        ]
      && lib.hasSuffix "< 604800" rules.TraefikCertificateExpiringSoon.expr
      && lib.hasSuffix "< 1814400" tuned.TraefikCertificateExpiringSoon.expr
      && lib.hasInfix "> 0.250000 and" tuned.TraefikBackendErrorsHigh.expr
      && lib.hasSuffix "> 2" tuned.TraefikBackendErrorsHigh.expr
      && rulesOf { } { } == null
      && rulesOf { metrics.enabled = false; } withPrometheus == null
    )
    || throw "traefik alerts: ${builtins.toJSON (builtins.attrNames rules)}";
}

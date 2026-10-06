# Tests for the gateway contract (kix/lib/vocab/gateway.nix): `check` on
# the provider side, `claims` and `require` on the consumer side,
# kix.expose against envoy-gateway, traefik, and kix.mkImport gateways, and
# the traefik package's refusals.

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
  ...
}:

let
  contract = kixlib.contracts.gateway;
  envoyGateway = import ../../../packages/envoy-gateway;
  traefik = import ../../../packages/traefik;

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
        instances.ingress.ingress-nginx.package = import ../../../packages/ingress-nginx;
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

  # envoy-gateway publishes no data-plane selector, so the backend gets no
  # policy admitting the proxy pods.
  gateway-envoy-opens-no-backend =
    let
      cnps = ofKind "CiliumNetworkPolicy" (
        manifests (
          exposedVia {
            package = envoyGateway;
          } netpolOn
        )
      );
    in
    byName "web-from-gateway" cnps == null && cnps != [ ];

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
}

# Tests that the warnings raised while a package builds a resource reach the
# instance's warning list, which `kix check` shows. The builders attach them
# to the resource as `_warnings`, and the instance collects them from its
# parts.

{
  lib,
  kixlib,
  mkCluster,
  baseInstances,
  netpolOn,
  ...
}:

let
  # A package whose parts come from `parts scope`.
  packageWith = parts: {
    meta.version = "test";
    build =
      { self, scope, ... }:
      parts scope
      // {
        root = self.main;
      };
  };

  warningsOf =
    modules: parts:
    (mkCluster (
      [
        baseInstances
        { instances.appns.probe.package = packageWith parts; }
      ]
      ++ modules
    )).instances.appns.probe._diagnostics.warnings;

  # A capability Kix knows about, so the capability checks run.
  someCapabilities = {
    cluster.capabilities.multiNode = true;
  };

  container = {
    name = "app";
    image = "app:1";
    resources = {
      requests = {
        cpu = "10m";
        memory = "16Mi";
      };
      limits = {
        cpu = "10m";
        memory = "16Mi";
      };
    };
  };

  loadBalancer = scope: {
    main = scope.mkResource {
      apiVersion = "v1";
      kind = "Service";
      name = "public";
      spec = {
        type = "LoadBalancer";
        selector = scope.selectorLabels;
        ports = [ { port = 80; } ];
      };
    };
    web = scope.mkDeployment {
      name = "web";
      spec = {
        selector.matchLabels = scope.selectorLabels;
        template.spec.containers = [ container ];
      };
    };
  };

  daemonSet = scope: {
    main = scope.mkDaemonSet {
      name = "agent";
      spec = {
        selector.matchLabels = scope.selectorLabels;
        template.spec.containers = [ container ];
      };
    };
  };

  find = text: ws: builtins.filter (w: lib.hasInfix text (w.message or "")) ws;
in
{
  # A LoadBalancer Service in a cluster that does not say whether it has a
  # load balancer gives one warning, which names the Service and the
  # cluster option to set.
  resource-warnings-load-balancer-binding-unset =
    let
      found = find "cluster.roles.loadBalancer.binding is not set" (
        warningsOf [ someCapabilities ] loadBalancer
      );
      w = builtins.head found;
    in
    (
      builtins.length found == 1
      && w.instance == "appns/probe"
      && w.clusterOption == "cluster.roles.loadBalancer.binding"
      &&
        w.object == {
          kind = "Service";
          name = "public";
        }
    )
    || throw "load balancer warning: ${builtins.toJSON found}";

  # The warning goes away once the cluster names its load balancer.
  resource-warnings-load-balancer-binding-set =
    find "loadBalancer.binding" (
      warningsOf [
        someCapabilities
        { cluster.roles.loadBalancer.binding = "shadowable"; }
      ] loadBalancer
    ) == [ ]
    || throw "load balancer warning with the binding set";

  # A DaemonSet in a cluster that does not say whether it runs DaemonSets
  # gives the capability warning.
  resource-warnings-daemonset-capability-unset =
    let
      found = find "cluster.capabilities.daemonSets" (warningsOf [ someCapabilities ] daemonSet);
    in
    (
      builtins.length found == 1
      && (builtins.head found).clusterOption == "cluster.capabilities.daemonSets"
    )
    || throw "daemonSets warning: ${builtins.toJSON found}";

  # A workload capped by availability.max on its builder warns, naming the
  # workload.
  resource-warnings-capped-workload =
    let
      capped = scope: {
        main = scope.mkDeployment {
          name = "web";
          availability.max = "none";
          spec = {
            replicas = 1;
            selector.matchLabels = scope.selectorLabels;
            template.spec.containers = [ container ];
          };
        };
      };
      found = find "supports at most" (warningsOf [ { cluster.capabilities.multiNode = true; } ] capped);
    in
    (
      builtins.length found == 1
      &&
        (builtins.head found).object == {
          kind = "Deployment";
          name = "web";
        }
    )
    || throw "capped workload warning: ${builtins.toJSON found}";

  # kix.expose behind an ingress controller that publishes no pod selector
  # warns that no network policy opens the backend to the controller. The
  # warning is attached to the Ingress.
  resource-warnings-expose-controller-without-pod-selector =
    let
      controller = {
        meta.version = "test";
        build =
          { self, scope, ... }:
          {
            class = scope.mkClusterResource {
              apiVersion = "networking.k8s.io/v1";
              kind = "IngressClass";
              name = "nginx";
              spec.controller = "k8s.io/ingress-nginx";
            };
            root = {
              resource = self.class;
              out.ingressClassName = self.class.out.name;
            };
          };
      };
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
                  selector.matchLabels = scope.selectorLabels;
                  template.spec.containers = [ (container // { ports = [ { containerPort = 8080; } ]; }) ];
                };
              };
              service = scope.mkResource (kix.service.fromWorkload { name = "web"; } self.deployment);
              root = self.service;
            }
          )
          (kixlib.expose { service = "service"; })
        ];
      };
      cluster = mkCluster [
        netpolOn
        {
          cluster.domain = "test.local";
          instances.ingressns.ingress-nginx.package = controller;
        }
        (
          { ref, ... }:
          {
            instances.appns.web = {
              package = backend;
              deps.ingressNginx = ref.ingressns.ingress-nginx;
            };
          }
        )
      ];
      found = find "does not publish `out.podSelector`" cluster.instances.appns.web._diagnostics.warnings;
    in
    builtins.length found == 1 || throw "expose warning: ${builtins.toJSON found}";
}

# Tests that the warnings raised while a package builds a resource reach the
# instance's warning list, which `kix check` shows. The builders attach them
# to the resource as `_warnings`, and the instance collects them from its
# parts. A package's own checks return warnings from its `warnings`.

{
  lib,
  kixlib,
  mkCluster,
  baseInstances,
  netpolOn,
  manifests,
  ofKind,
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

  # A custom resource that reads a Service address, of a kind that does not
  # declare how its controller uses the address, warns and names itself.
  resource-warnings-custom-resource-reads-service-address =
    let
      widget =
        { self, scope, ... }:
        {
          web = scope.mkDeployment {
            name = "web";
            spec = {
              selector.matchLabels = scope.selectorLabels;
              template.spec.containers = [ container ];
            };
          };
          svc = scope.mkResource {
            apiVersion = "v1";
            kind = "Service";
            name = "backend";
            spec = {
              selector = scope.selectorLabels;
              ports = [ { port = 80; } ];
            };
          };
          widgetCrd = scope.mkCRDRef {
            group = "example.com";
            kind = "Widget";
            plural = "widgets";
            version = "v1";
          };
          main = scope.mkCR self.widgetCrd {
            name = "w";
            spec.target = self.svc.out.fqdn;
          };
          root = self.main;
        };
      found = find "references a Service address" (
        (mkCluster [
          baseInstances
          {
            instances.appns.probe.package = {
              meta.version = "test";
              build = widget;
            };
          }
        ]).instances.appns.probe._diagnostics.warnings
      );
    in
    (
      builtins.length found == 1
      &&
        (builtins.head found).object == {
          kind = "Widget";
          name = "w";
        }
    )
    || throw "custom resource warning: ${builtins.toJSON found}";

  # Two custom resources that name each other, one of them reading a
  # Service address, still build. The instance checks the custom resources
  # before its view exists, and the check must not need that view.
  resource-warnings-custom-resources-name-each-other =
    let
      package = {
        meta.version = "test";
        build =
          { self, scope, ... }:
          {
            web = scope.mkDeployment {
              name = "web";
              spec = {
                selector.matchLabels = scope.selectorLabels;
                template.spec.containers = [ container ];
              };
            };
            svc = scope.mkResource {
              apiVersion = "v1";
              kind = "Service";
              name = "backend";
              spec = {
                selector = scope.selectorLabels;
                ports = [ { port = 80; } ];
              };
            };
            widgetCrd = scope.mkCRDRef {
              group = "example.com";
              kind = "Widget";
              plural = "widgets";
              version = "v1";
            };
            a = scope.mkCR self.widgetCrd {
              name = "a";
              spec = {
                peer = self.b.out.name;
                target = self.svc.out.fqdn;
              };
            };
            b = scope.mkCR self.widgetCrd {
              name = "b";
              spec.peer = self.a.name;
            };
            root = self.a;
          };
      };
      cluster = mkCluster [
        baseInstances
        { instances.appns.probe.package = package; }
      ];
      found = find "references a Service address" cluster.instances.appns.probe._diagnostics.warnings;
    in
    (builtins.length (ofKind "Widget" (manifests cluster)) == 2 && builtins.length found == 1)
    || throw "custom resources that name each other: ${builtins.toJSON found}";

  # A typed value in a known folder that is not a resource is left out of
  # the build, and the instance warns about it.
  resource-warnings-folder-holds-non-resource =
    let
      found = find "which is not a resource" (
        warningsOf [ ] (scope: {
          main = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "main";
          };
          secrets.stray = {
            _type = "kix-test-value";
          };
        })
      );
    in
    builtins.length found == 1 || throw "folder warning: ${builtins.toJSON found}";

  # scope.requireMetricsApi returns its warning for the package's
  # `warnings`, so the warning reaches the instance's list.
  resource-warnings-require-metrics-api =
    let
      package =
        { scope, ... }:
        {
          meta.version = "test";
          warnings = _: scope.requireMetricsApi "the probe";
          build =
            { self, scope, ... }:
            {
              main = scope.mkResource {
                apiVersion = "v1";
                kind = "ConfigMap";
                name = "main";
              };
              root = self.main;
            };
        };
      found = find "requires the Kubernetes Metrics API" (
        (mkCluster [
          baseInstances
          someCapabilities
          { instances.appns.probe.package = package; }
        ]).instances.appns.probe._diagnostics.warnings
      );
    in
    (
      builtins.length found == 1
      && (builtins.head found).clusterOption == "cluster.roles.metricsApi.binding"
    )
    || throw "metrics API warning: ${builtins.toJSON found}";

  # The warnings on a resource an instance processor returns reach the
  # instance's list, as those on its parts do.
  resource-warnings-processor-resource =
    let
      found = find "from the processor" (
        (mkCluster [
          baseInstances
          {
            instances.appns.probe.package = packageWith (scope: {
              main = scope.mkResource {
                apiVersion = "v1";
                kind = "ConfigMap";
                name = "main";
              };
            });
            hooks.instanceProcessors.test-warn = ctx: {
              resources = lib.optional (ctx.instanceName == "probe") (
                ctx.emit.mkResource {
                  apiVersion = "v1";
                  kind = "ConfigMap";
                  name = "processed";
                }
                // {
                  _warnings = [ "a warning from the processor" ];
                }
              );
            };
          }
        ]).instances.appns.probe._diagnostics.warnings
      );
    in
    builtins.length found == 1 || throw "processor resource warning: ${builtins.toJSON found}";
}

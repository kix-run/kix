# Tests for kix/packages/reloader: the `out.withReloadOn` transformer, the
# refused flags and env variables, the namespace checks, the one-instance
# guards, the replica count, and metrics gating. The reloader runs in
# namespace `reloader`, the consumer in `demo`.

{
  lib,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  ...
}:

let
  reloaderPackage = import ../../../packages/reloader;
  secretPackage = import ../../../packages/secret;
  secretRefPackage = import ../../../packages/secret-ref;
  rules = import ../../rules { inherit lib; };

  # A Deployment `web` whose builder args go through withReloadOn with the
  # Secrets `refs` picks. `token` is a local scope.mkSecretRef, `config` a
  # Kix-built ConfigMap, `external` a secret-ref dependency, and `built` a
  # Kix-built Secret dependency. `args` replaces the builder args, and
  # `transform` builds the `deployment` part itself.
  mkConsumer =
    {
      refs ? p: [ p.self.token ],
      args ? null,
      transform ? null,
    }:
    {
      meta = {
        version = "test";
        description = "reloader consumer";
        owner = "test";
      };
      build =
        {
          self,
          scope,
          reloader,
          external ? null,
          built ? null,
          ...
        }:
        let
          p = {
            inherit
              self
              scope
              reloader
              external
              built
              ;
          };
          webArgs =
            if args != null then
              lib.recursiveUpdate { spec.selector.matchLabels = scope.selectorLabels; } args
            else
              {
                name = "web";
                spec = {
                  selector.matchLabels = scope.selectorLabels;
                  template.spec.containers = [
                    {
                      name = "web";
                      image = "nginx";
                      env = self.token.out.mkEnv { TOKEN = "token"; };
                    }
                  ];
                };
              };
        in
        {
          token = scope.mkSecretRef {
            name = "demo-token";
            keys = [ "token" ];
          };
          config = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "web-config";
            data.a = "b";
          };
          deployment =
            if transform != null then
              transform p
            else
              webArgs |> reloader.out.withReloadOn (refs p) |> scope.mkDeployment;
          root = self.deployment;
        };
    };

  clusterWith =
    {
      config ? { },
      consumer ? mkConsumer { },
      modules ? [ ],
    }:
    mkCluster (
      [
        {
          instances.reloader.reloader = {
            package = reloaderPackage;
            inherit config;
          };
          instances.demo.web.package = consumer;
          instances.demo.external = {
            package = secretRefPackage;
            aliases = [ "external" ];
            config.keys = [ "token" ];
          };
          instances.demo.built = {
            package = secretPackage;
            aliases = [ "built" ];
            config.stringData.token = "a";
          };
        }
      ]
      ++ modules
    );

  reloadAnnotationOf =
    cluster:
    (byName "web" (ofKind "Deployment" (manifests cluster)))
    .metadata.annotations."secret.reloader.stakater.com/reload" or null;

  # A prometheus provider whose builders render their arguments.
  prometheusStub = {
    meta = {
      version = "test";
      defaultAliases = [ "prometheus" ];
    };
    build =
      { self, scope, ... }:
      let
        as =
          kind: consumerScope: args:
          consumerScope.mkResource (
            args
            // {
              apiVersion = "monitoring.coreos.com/v1";
              inherit kind;
            }
          );
      in
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "prometheus";
        };
        root = {
          resource = self.cm;
          out = {
            mkServiceMonitor = as "ServiceMonitor";
            mkPrometheusRule = as "PrometheusRule";
          };
        };
      };
  };
in
{
  # A local mkSecretRef and a secret-ref dependency are accepted; a repeated
  # Secret is written once and a second call appends to the annotation.
  reloader-with-reload-on =
    let
      chained = reloadAnnotationOf (clusterWith {
        consumer = mkConsumer {
          transform =
            p:
            {
              name = "web";
              spec.selector.matchLabels = p.scope.selectorLabels;
              spec.template.spec.containers = [
                {
                  name = "web";
                  image = "nginx";
                }
              ];
            }
            |> p.reloader.out.withReloadOn [ p.external ]
            |> p.reloader.out.withReloadOn [
              p.self.token
              p.external
            ]
            |> p.scope.mkDeployment;
        };
      });
      local = reloadAnnotationOf (clusterWith {
        consumer = mkConsumer {
          refs = p: [
            p.self.token
            p.self.token
          ];
        };
      });
      external = reloadAnnotationOf (clusterWith {
        consumer = mkConsumer {
          refs = p: [
            p.external
            p.self.token
          ];
        };
      });
      composed = reloadAnnotationOf (clusterWith {
        consumer = mkConsumer {
          args = {
            name = "web";
            annotations."secret.reloader.stakater.com/reload" = "demo-token,other";
            spec.template.spec.containers = [
              {
                name = "web";
                image = "nginx";
              }
            ];
          };
          refs = p: [
            p.external
            p.self.token
          ];
        };
      });
    in
    (
      local == "demo-token"
      && external == "external,demo-token"
      && composed == "demo-token,other,external"
      && chained == "external,demo-token"
    )
    || throw "reloader withReloadOn: local ${builtins.toJSON local}, external ${builtins.toJSON external}, composed ${builtins.toJSON composed}, chained ${builtins.toJSON chained}";

  # Each refused case fails and its corrected form builds, so a refusal
  # cannot pass on an unrelated failure in the fixture.
  reloader-refusals =
    let
      withRefs = refs: clusterWith { consumer = mkConsumer { inherit refs; }; };
      withArgs =
        args:
        clusterWith {
          consumer = mkConsumer {
            inherit args;
          };
        };
      withConfig = config: clusterWith { inherit config; };
      inDemo =
        extraArgs:
        clusterWith {
          config = { inherit extraArgs; };
        };
      container = {
        name = "job";
        image = "busybox";
      };
      cases = {
        kixBuiltSecret = {
          bad = withRefs (p: [ p.built ]);
          good = withRefs (p: [ p.external ]);
        };
        kixBuiltConfigMap = {
          bad = withRefs (p: [ p.self.config ]);
          good = withRefs (p: [ p.self.token ]);
        };
        emptyList = {
          bad = withRefs (_: [ ]);
          good = withRefs (p: [ p.self.token ]);
        };
        notASecret = {
          bad = withRefs (_: [ "demo-token" ]);
          good = withRefs (p: [ p.self.token ]);
        };
        cronJobArgs = {
          bad = withArgs {
            name = "web";
            spec.jobTemplate.spec.template.spec = {
              restartPolicy = "OnFailure";
              containers = [ container ];
            };
          };
          good = withArgs {
            name = "web";
            spec.template.spec.containers = [ container ];
          };
        };
        jobArgs = {
          bad = withArgs {
            name = "web";
            spec.template.spec = {
              restartPolicy = "Never";
              containers = [ container ];
            };
          };
          good = withArgs {
            name = "web";
            spec.template.spec = {
              restartPolicy = "Always";
              containers = [ container ];
            };
          };
        };
        builtDeployment = {
          bad = clusterWith {
            consumer = mkConsumer {
              transform =
                p:
                p.scope.mkDeployment {
                  name = "web";
                  spec.selector.matchLabels = p.scope.selectorLabels;
                  spec.template.spec.containers = [ container ];
                }
                |> p.reloader.out.withReloadOn [ p.self.token ];
            };
          };
          good = withRefs (p: [ p.self.token ]);
        };
        reloadStrategy = {
          bad = withConfig { extraArgs = [ "--reload-strategy=annotations" ]; };
          good = withConfig { extraArgs = [ "--log-level=debug" ]; };
        };
        bareSecretAnnotation = {
          bad = withConfig {
            extraArgs = [
              "--secret-annotation"
              "x"
            ];
          };
          good = withConfig { extraArgs = [ "--log-level=debug" ]; };
        };
        webhook = {
          bad = withConfig { extraArgs = [ "--webhook-url=http://x" ]; };
          good = withConfig { extraArgs = [ "--log-level=debug" ]; };
        };
        namespaceSelector = {
          bad = withConfig { extraArgs = [ "--namespace-selector=team=a" ]; };
          good = withConfig { extraArgs = [ "--namespaces-to-ignore=team-a" ]; };
        };
        podNameEnv = {
          bad = withConfig { env.POD_NAME = "x"; };
          good = withConfig { env.GODEBUG = "x509ignoreCN=0"; };
        };
        memoryLimitEnvNull = {
          bad = withConfig { env.GOMEMLIMIT = null; };
          good = withConfig { env.GOGC = "50"; };
        };
        namespaceEnv = {
          bad = withConfig { env.KUBERNETES_NAMESPACE = "demo"; };
          good = withConfig { extraArgs = [ "--namespaces=demo" ]; };
        };
        bareNamespaces = {
          bad = inDemo [
            "--namespaces"
            "demo"
          ];
          good = inDemo [ "--namespaces=demo" ];
        };
        notWatched = {
          bad = inDemo [ "--namespaces=other" ];
          good = inDemo [ "--namespaces=demo,other" ];
        };
        repeatedNamespaces = {
          bad = inDemo [
            "--namespaces=other"
            "--namespaces=more"
          ];
          good = inDemo [
            "--namespaces=other"
            "--namespaces=demo"
          ];
        };
        ignored = {
          bad = inDemo [ "--namespaces-to-ignore=demo" ];
          good = inDemo [ "--namespaces-to-ignore=other" ];
        };
        watchedAndIgnored = {
          bad = inDemo [
            "--namespaces=demo"
            "--namespaces-to-ignore=other"
          ];
          good = inDemo [ "--namespaces=demo" ];
        };
        resourceLabelSelector = {
          bad = inDemo [ "--resource-label-selector=a=b" ];
          good = inDemo [ "--log-level=debug" ];
        };
      };
      wrong = builtins.attrNames (lib.filterAttrs (_: c: !(evalFails c.bad) || evalFails c.good) cases);
    in
    wrong == [ ]
    || throw "reloader refusals: bad case built or good case failed: ${builtins.toJSON wrong}";

  # The consumer depends on the reloader instance, so the annotation rule
  # reports nothing. A workload that writes the annotation without that
  # dependency gets the rule's finding.
  reloader-annotation-domains =
    let
      scorecardOnly = {
        scorecard = {
          enable = true;
          rules.architecture = { inherit (rules.architecture) annotationDomainOwnership; };
        };
      };
      findingsOf =
        cluster:
        builtins.filter (
          f: f.rule == "architecture.annotationDomainOwnership"
        ) cluster.scorecardReport.findings;
      withDep = findingsOf (clusterWith {
        modules = [ scorecardOnly ];
      });
      noDep = findingsOf (clusterWith {
        modules = [
          scorecardOnly
          {
            instances.demo.bare.package = {
              meta = {
                version = "test";
                description = "annotated without the reloader dependency";
                owner = "test";
              };
              build =
                { self, scope, ... }:
                {
                  root = self.deployment;
                  deployment = scope.mkDeployment {
                    name = "bare";
                    spec.selector.matchLabels = scope.selectorLabels;
                    annotations."secret.reloader.stakater.com/reload" = "demo-token";
                    spec.template.spec.containers = [
                      {
                        name = "bare";
                        image = "nginx";
                      }
                    ];
                  };
                };
            };
          }
        ];
      });
    in
    (withDep == [ ] && builtins.length noDep == 1)
    || throw "reloader annotation domains: with dependency ${builtins.toJSON withDep}, without ${builtins.toJSON noDep}";

  # A second instance fails under the default alias (conflictsWith) and
  # under another alias (the annotation-domain index).
  reloader-singleton =
    let
      second = aliases: {
        instances.other.reloader = {
          package = reloaderPackage;
          inherit aliases;
        };
      };
    in
    (
      evalFails (clusterWith {
        modules = [ (second [ "reloader" ]) ];
      })
      && evalFails (clusterWith {
        modules = [ (second [ "secondReloader" ]) ];
      })
      && !(evalFails (clusterWith { }))
    )
    || throw "reloader singleton: a second instance built";

  # At `node` the Deployment runs two replicas with every strategy flag, and
  # the ClusterRole grants nothing on ConfigMaps or batch.
  reloader-node-level =
    let
      ms = manifests (clusterWith {
        modules = [
          {
            cluster.capabilities.multiNode = true;
            instances.reloader.reloader.availability = "node";
          }
        ];
      });
      deployment = byName "reloader" (ofKind "Deployment" ms);
      args = (builtins.head deployment.spec.template.spec.containers).args;
      role = byName "reloader" (ofKind "ClusterRole" ms);
      resources = lib.concatMap (r: r.resources) role.rules;
      groups = lib.concatMap (r: r.apiGroups) role.rules;
      expected = [
        "--enable-ha=true"
        "--reload-strategy=env-vars"
        "--reload-on-create=true"
        "--sync-after-restart=true"
        "--ignored-workload-types=jobs,cronjobs"
        "--resources-to-ignore=configmaps"
      ];
    in
    (
      deployment.spec.replicas == 2
      && lib.all (f: builtins.elem f args) expected
      && !(builtins.elem "configmaps" resources)
      && !(builtins.elem "batch" groups)
      && byName "reloader" (ofKind "PodDisruptionBudget" ms) != null
    )
    || throw "reloader node level: replicas ${toString deployment.spec.replicas}, args ${builtins.toJSON args}, rules ${builtins.toJSON role.rules}";

  # The Service, ServiceMonitor, and alerts render only with a prometheus
  # provider and metrics.enabled; the alerts select the instance's Service.
  reloader-metrics =
    let
      withPrometheus =
        config:
        manifests (clusterWith {
          inherit config;
          modules = [ { instances.monitoring.prometheus.package = prometheusStub; } ];
        });
      on = withPrometheus { };
      off = withPrometheus { metrics.enabled = false; };
      without = manifests (clusterWith { });
      service = byName "reloader" (ofKind "Service" on);
      rule = byName "reloader-alerts" (ofKind "PrometheusRule" on);
      exprs = map (r: r.expr) (builtins.head rule.spec.groups).rules;
    in
    (
      map (p: p.port) service.spec.ports == [ 9090 ]
      && byName "reloader" (ofKind "ServiceMonitor" on) != null
      && lib.all (lib.hasInfix ''namespace="reloader",service="reloader"'') exprs
      && ofKind "Service" off == [ ]
      && ofKind "ServiceMonitor" off == [ ]
      && ofKind "Service" without == [ ]
    )
    || throw "reloader metrics: service ${builtins.toJSON service}, alerts ${builtins.toJSON exprs}";
}

# Evaluation-only regression matrix for kix/lib.
#
# ludo-kind is the golden *build* check, but it pins one topology (netpol
# enabled, cilium enforcer present, no sentinel instances, no hostNetwork
# apps). This matrix evaluates tiny synthetic clusters across the
# configurations ludo-kind does NOT exercise: netpol off, missing enforcer,
# hostNetwork workloads, direction-limited policies, sentinel namespaces,
# hook priorities, hook contract violations, and the emit facade.
#
# Run from the repo root:
#
#   nix eval --extra-experimental-features 'nix-command flakes pipe-operators' \
#     --impure --expr 'import ./kix/lib/tests { }'
#
# Success prints { ok = true; passed = [ ... ]; }. Any failure throws with
# the failing test names and details.

{
  # Default: the exact nixpkgs the ludo flake pins (read from its lock file,
  # fetched by narHash — pure, no registry/channel needed).
  lib ? (
    let
      lock = builtins.fromJSON (builtins.readFile ../../../ludo/flake.lock);
    in
    import (builtins.fetchTree lock.nodes.nixpkgs.locked + "/lib")
  ),
}:

let
  # Kix's own annotation keys and API names, spelled once in
  # core/annotations.nix.
  kixAnnotations = import ../core/annotations.nix;
  kixKeys = kixAnnotations.keys;
  k8s = import ../core { inherit lib; };
  eval = import ../eval { inherit lib k8s; };
  kixlib = import ../vocab { inherit lib; };

  # The *public* surface, as a consuming flake sees it through `mkFlake`.
  # The rest of this matrix imports subtrees directly, which is how
  # `mergeFragments` managed to be implemented, documented and unreachable
  # all at once: no test ever looked at what `kix/lib/default.nix` exports.
  # `pkgs` is forced only by the helm and manifest-writing attributes, so a
  # stub keeps this eval-only like the rest of the file.
  publicKix = import ../default.nix {
    inherit lib;
    pkgs = { };
  };

  # A plain (non-role) dependency and its consumer. Role-named deps take a
  # deliberately different path in `eval/auto.nix`: they are keyed by the
  # role, so one provider is shared by every namespace. A plain dep is keyed
  # `"${depName}@${requesterNs}"`, which is the path that makes mkEnv's
  # namespaces do the isolating.
  envSidecarPackage = mkCmPackage { name = "env-sidecar"; };

  envSidecarConsumer = {
    meta.version = "test";
    build =
      {
        self,
        scope,
        envSidecar,
        ...
      }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "sidecar-consumer";
          extra.data.sidecar = envSidecar.out.name;
        };
        root = self.cm;
      };
  };

  # Renders its own config, so a test can tell two environments apart by
  # what the ConfigMap says rather than only by which namespace it is in.
  envProbePackage = {
    meta.version = "test";
    options.message = lib.mkOption {
      type = lib.types.str;
      default = "unset";
    };
    options.keep = lib.mkOption {
      type = lib.types.str;
      default = "unset";
    };
    build =
      {
        self,
        scope,
        config,
        ...
      }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "probe";
          data = {
            inherit (config) message keep;
          };
        };
        root = self.cm;
      };
  };

  # ---------------------------------------------------------------- fixtures

  containerBase = {
    resources = {
      requests = {
        cpu = "10m";
        memory = "16Mi";
      };
      limits = {
        cpu = "100m";
        memory = "64Mi";
      };
    };
  };

  # NOTE: all fixtures follow the production convention `root = self.<part>`.
  # A resource living ONLY at `parts.root` is dropped from the manifest set
  # (collectResources excludes the `root` key) — see the latent-quirk note
  # in architecture.md.
  dnsPackage = {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "dns-root";
        };
        root = self.cm;
      };
  };

  dbPackage = {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        deployment = scope.mkDeployment {
          name = "db";
          spec = {
            selector.matchLabels = scope.selectorLabels;
            template = {
              metadata.labels = scope.selectorLabels;
              spec.containers = [
                (
                  {
                    name = "db";
                    image = "example/db:1";
                    ports = [
                      {
                        name = "db";
                        containerPort = 5432;
                      }
                    ];
                  }
                  // containerBase
                )
              ];
            };
          };
        };
        service = scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = "db";
          spec = {
            selector = scope.selectorLabels;
            ports = [
              {
                name = "db";
                port = 5432;
              }
            ];
          };
        };
        root = {
          resource = self.service;
          requires = [ self.deployment ];
        };
      };
  };

  mkAppPackage =
    {
      hostNetwork ? false,
      # how the app wires the db address: fqdn = dialing (carries the
      # endpoint fact); out.name alone is structural and derives no edge
      wireDb ? (db: db.out.fqdn),
    }:
    {
      meta.version = "test";
      build =
        {
          self,
          scope,
          db,
          ...
        }:
        {
          root = self.deployment;
          deployment = scope.mkDeployment {
            name = "app";
            spec = {
              selector.matchLabels = scope.selectorLabels;
              template = {
                metadata.labels = scope.selectorLabels;
                spec = {
                  inherit hostNetwork;
                  containers = [
                    (
                      {
                        name = "app";
                        image = "example/app:1";
                        env = [
                          {
                            name = "DB_HOST";
                            value = wireDb db;
                          }
                        ];
                      }
                      // containerBase
                    )
                  ];
                };
              };
            };
          };
        };
    };

  # A Deployment, a Service over the package's selector labels, and a
  # kix.healthCheck probe that dials the Service. Exercises every knob the
  # probe tests need.
  mkProbedPackage =
    {
      targetPort ? 8080,
      wire ? (svc: svc.out.url { }),
      script ? "print('ok')",
      runtime ? null,
    }:
    {
      meta.version = "test";
      build = [
        (
          { self, scope, ... }:
          {
            root = self.svc;
            deployment = scope.mkDeployment {
              name = "app";
              spec = {
                selector.matchLabels = scope.selectorLabels;
                template = {
                  metadata.labels = scope.selectorLabels;
                  spec.containers = [
                    (
                      {
                        name = "app";
                        image = "example/app:1";
                        ports = [
                          {
                            name = "http";
                            containerPort = targetPort;
                          }
                        ];
                        securityContext.runAsNonRoot = true;
                      }
                      // containerBase
                    )
                  ];
                };
              };
            };
            svc = scope.mkResource {
              apiVersion = "v1";
              kind = "Service";
              name = "app";
              requires = [ self.deployment ];
              spec = {
                selector = scope.selectorLabels;
                ports = [
                  {
                    name = "http";
                    port = targetPort;
                    targetPort = "http";
                  }
                ];
              };
            };
          }
        )
        (kixlib.healthCheck (
          {
            inherit script;
            requires = { self, ... }: [ self.deployment ];
            env =
              { self, ... }:
              {
                APP_URL = wire self.svc;
              };
          }
          // lib.optionalAttrs (runtime != null) { inherit runtime; }
        ))
      ];
    };

  # A probe that reads the db package through the `deps` argument. The main
  # entry declares the dependency; the probe entry cannot.
  depsProbePackage = {
    meta.version = "test";
    build = [
      (
        {
          self,
          scope,
          db,
          ...
        }:
        {
          root = self.deployment;
          deployment = scope.mkDeployment {
            name = "app";
            spec = {
              selector.matchLabels = scope.selectorLabels;
              template = {
                metadata.labels = scope.selectorLabels;
                spec.containers = [
                  (
                    {
                      name = "app";
                      image = "example/app:1";
                      env = [
                        {
                          name = "DB_HOST";
                          value = db.out.fqdn;
                        }
                      ];
                    }
                    // containerBase
                  )
                ];
              };
            };
          };
        }
      )
      (kixlib.healthCheck {
        script = "print('ok')";
        env =
          { deps, ... }:
          {
            DB_URL = deps.db.out.url { };
          };
      })
    ];
  };

  # dials db through a ConfigMap: the endpoint fact must conduct through the
  # carrier's seal — indirection is the default case, not a special one
  indirectAppPackage = {
    meta.version = "test";
    build =
      {
        self,
        scope,
        db,
        ...
      }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "app-config";
          data.DB_HOST = db.out.fqdn;
        };
        deployment = scope.mkDeployment {
          name = "app";
          spec = {
            selector.matchLabels = scope.selectorLabels;
            template = {
              metadata.labels = scope.selectorLabels;
              spec.containers = [
                (
                  {
                    name = "app";
                    image = "example/app:1";
                    envFrom = [ { configMapRef.name = self.cm.out.name; } ];
                  }
                  // containerBase
                )
              ];
            };
          };
        };
        root = self.deployment;
      };
  };

  # CRD-owning operator: declares TestCluster's fact behavior ON THE CRD
  # REF (behavior is a property of the kind, delivered through the typed
  # builder chain — mkCRDRef → out.crds → consumer's scope.mkCR).
  testClusterBehavior = {
    endpoint = "terminate";
    podSelector = cr: {
      "test.io/cluster" = cr.metadata.name;
    };
  };

  mkOperatorPackage =
    {
      factBehavior ? null,
    }:
    {
      meta = {
        version = "test";
        defaultAliases = [ "testOperator" ];
      };
      build =
        { self, scope, ... }:
        {
          cm = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "test-operator";
          };
          crdRef = scope.mkCRDRef {
            group = "test.io";
            kind = "TestCluster";
            plural = "testclusters";
            inherit factBehavior;
          };
          root = {
            resource = self.cm;
            requires = [ self.crdRef ];
            out.crds.testCluster = self.crdRef;
          };
        };
    };

  # consumer: builds a TestCluster CR via the operator's typed builder,
  # embedding db's address; plus a deployment that only NAMES the CR (no
  # address flows to the workload)
  crConsumerPackage = {
    meta.version = "test";
    build =
      {
        self,
        scope,
        db,
        testOperator,
        ...
      }:
      {
        cluster = scope.mkCR testOperator.out.crds.testCluster {
          name = "mycluster";
          spec.connection = db.out.fqdn;
        };
        deployment = scope.mkDeployment {
          name = "consumer";
          spec = {
            selector.matchLabels = scope.selectorLabels;
            template = {
              metadata.labels = scope.selectorLabels;
              spec.containers = [
                (
                  {
                    name = "consumer";
                    image = "example/consumer:1";
                    env = [
                      {
                        name = "CLUSTER_NAME";
                        value = self.cluster.out.name;
                      }
                    ];
                  }
                  // containerBase
                )
              ];
            };
          };
        };
        root = self.deployment;
      };
  };

  # same consumer but builder-less: raw mkResource with a kind string —
  # no behavior arrives unless cluster.factBehavior supplies it
  rawCrConsumerPackage = {
    meta.version = "test";
    build =
      {
        self,
        scope,
        db,
        ...
      }:
      {
        cluster = scope.mkResource {
          apiVersion = "test.io/v1";
          kind = "TestCluster";
          name = "mycluster";
          spec.connection = db.out.fqdn;
        };
        deployment = scope.mkDeployment {
          name = "consumer";
          spec = {
            selector.matchLabels = scope.selectorLabels;
            template = {
              metadata.labels = scope.selectorLabels;
              spec.containers = [
                (
                  {
                    name = "consumer";
                    image = "example/consumer:1";
                    env = [
                      {
                        name = "CLUSTER_NAME";
                        value = self.cluster.out.name;
                      }
                    ];
                  }
                  // containerBase
                )
              ];
            };
          };
        };
        root = self.deployment;
      };
  };

  # Reports whether the package-facing enforcer handle is set.
  probePackage = {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "enforcer-probe";
          extra.data.enforcer = if scope.networkPolicyEnforcer == null then "unset" else "set";
        };
        root = self.cm;
      };
  };

  # Minimal enforcer satisfying the full interface contract
  # (plugins/netpol/interface.nix). Rule shapes are inert stubs; mkPolicy
  # seals a CNP-shaped resource through whatever mkResource it is handed —
  # exactly the surface the real cilium packages expose.
  stubEnforcer = {
    meta = {
      version = "test";
      roles = [ "network-policy-enforcer" ];
    };
    build =
      { scope, ... }:
      let
        crdRef = scope.mkCRDRef {
          group = "cilium.io";
          kind = "CiliumNetworkPolicy";
          plural = "ciliumnetworkpolicies";
          version = "v2";
        };

        rule = kind: extra: { stubRule = kind; } // extra;

        netpolApi = {
          mkPolicy =
            { mkResource, extraArgs }:
            mkResource (
              extraArgs
              // {
                apiVersion = "cilium.io/v2";
                kind = "CiliumNetworkPolicy";
                requires = (extraArgs.requires or [ ]) ++ [ crdRef ];
              }
            );
          mkDefaultDenySpec =
            { denyIngress, denyEgress }:
            {
              endpointSelector = { };
            }
            // lib.optionalAttrs denyIngress { ingress = [ ]; }
            // lib.optionalAttrs denyEgress { egress = [ ]; };
          dnsEgressRule = rule "dns-egress" { };
          apiServerEgressRule = rule "apiserver-egress" { };
          mkExternalIngressRule = { entities }: rule "external-ingress" { inherit entities; };
          mkExternalEgressRule = { entities }: rule "external-egress" { inherit entities; };
          mkServiceEgressRule =
            {
              selector,
              namespace,
              sourceNamespace,
              ports,
            }:
            rule "service-egress" { inherit selector namespace ports; };
          mkSelfRules =
            { selector }:
            {
              egress = [ (rule "self-egress" { inherit selector; }) ];
              ingress = [ (rule "self-ingress" { inherit selector; }) ];
            };
          mkCallerIngressRule =
            {
              callerSelector,
              callerNamespace,
              ports,
            }:
            rule "caller-ingress" { inherit callerSelector callerNamespace ports; };
          portsToCilium = ports: ports;
          mkEndpointSelector = matchLabels: { inherit matchLabels; };
          translateIntentRules =
            { intents }:
            {
              egressRules = [ ];
              ingressRules = [ ];
            };
          materializePlatformIntent =
            {
              intent,
              mkResource,
              namespaceResource ? null,
              clusterScoped,
            }:
            mkResource {
              apiVersion = "cilium.io/v2";
              kind = "CiliumNetworkPolicy";
              name = intent.name;
              namespace =
                if (intent.scope or "namespaced") == "clusterwide" then clusterScoped else namespaceResource;
              extra.spec.stubIntent = true;
            };
        };
      in
      {
        # Named part: `root` may only alias a named part (kixpkgs#25). Before
        # this the whole netpol matrix failed on that check, unnoticed.
        inherit crdRef;
        root = {
          resource = crdRef;
          out.netpol = netpolApi;
        };
      };
  };

  # Minimal role claimants for the role-model tests.
  mkCmPackage =
    {
      name,
      metaExtra ? { },
      out ? null,
    }:
    {
      meta = {
        version = "test";
      }
      // metaExtra;
      build =
        { self, scope, ... }:
        {
          cm = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            inherit name;
          };
          root =
            if out == null then
              self.cm
            else
              {
                resource = self.cm;
                inherit out;
              };
        };
    };

  # v2_discussions/128 fixtures: a package hand-rolling a PVC, and a package
  # writing annotations under a given domain (optionally linking the
  # `operator` dep — dep args are discovered from literal functionArgs, so
  # the with-dep variant hardcodes the arg name).
  mkPvcPackage =
    {
      metaExtra ? { },
    }:
    {
      meta = {
        version = "test";
      }
      // metaExtra;
      build =
        { self, scope, ... }:
        {
          pvc = scope.mkResource {
            apiVersion = "v1";
            kind = "PersistentVolumeClaim";
            name = "data";
            spec = {
              accessModes = [ "ReadWriteOnce" ];
              resources.requests.storage = "1Gi";
            };
          };
          root = self.pvc;
        };
    };

  mkAnnotatedCmPackage =
    {
      key,
      name ? "writer-cm",
      withOperatorDep ? false,
      metaExtra ? { },
    }:
    let
      body =
        { self, scope, ... }:
        {
          cm = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            inherit name;
            annotations.${key} = "true";
          };
          root = self.cm;
        };
    in
    {
      meta = {
        version = "test";
      }
      // metaExtra;
      build =
        if withOperatorDep then
          {
            self,
            scope,
            operator,
            ...
          }@args:
          body args
        else
          body;
    };

  dsPackage = {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        ds = scope.mkDaemonSet {
          name = "agent";
          spec = {
            selector.matchLabels = scope.selectorLabels;
            template = {
              metadata.labels = scope.selectorLabels;
              spec.containers = [
                (
                  {
                    name = "agent";
                    image = "example/agent:1";
                  }
                  // containerBase
                )
              ];
            };
          };
        };
        root = self.ds;
      };
  };

  # Stock-catalog fixtures: a role-claiming shelf package and a consumer
  # whose storageClasses dep is OPTIONAL (like persistent-volume-claim).
  stockStorage = mkCmPackage {
    name = "stock-sc";
    metaExtra.roles = [ "storageClasses" ];
    out.storageClassName = "stock-sc-name";
  };

  optionalScConsumer = {
    meta.version = "test";
    build =
      {
        self,
        scope,
        storageClasses ? null,
        ...
      }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "sc-consumer";
          extra.data.sc = if storageClasses == null then "missing" else storageClasses.out.storageClassName;
        };
        root = self.cm;
      };
  };

  # Transitive weak-demand fixtures: a shelf package with its own weak
  # storageClasses demand, and a consumer whose REQUIRED dep pulls it.
  weakMiddlePackage = {
    meta.version = "test";
    build =
      {
        self,
        scope,
        storageClasses ? null,
        ...
      }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "middle";
          extra.data.sc = if storageClasses == null then "missing" else storageClasses.out.storageClassName;
        };
        root = self.cm;
      };
  };

  weakMiddleConsumer = {
    meta.version = "test";
    build =
      {
        self,
        scope,
        middle,
        ...
      }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "top-consumer";
        };
        root = self.cm;
      };
  };

  baseInstances = {
    instances.dns.dns = {
      package = dnsPackage;
    };
    instances.dbns.db = {
      package = dbPackage;
    };
    instances.appns.app = {
      package = mkAppPackage { };
    };
  };

  netpolOn = {
    networkPolicy.enable = true;
    instances.infra.cilium = {
      package = stubEnforcer;
    };
  };

  mkCluster =
    modules:
    eval.buildCluster {
      name = "test";
      inherit modules;
    };

  # ----------------------------------------------------------------- helpers

  manifests = cluster: cluster.rawManifests;
  ofKind = kind: ms: builtins.filter (m: (m.kind or "") == kind) ms;
  namesOf = ms: map (m: m.metadata.name or "?") ms;
  hasName = name: ms: builtins.any (m: (m.metadata.name or "") == name) ms;
  byName = name: ms: lib.findFirst (m: (m.metadata.name or "") == name) null ms;
  indexOfName =
    name: ms:
    lib.lists.findFirstIndex (
      m: (m.metadata.name or "") == name
    ) (throw "manifest '${name}' not found") ms;

  dependsOn = m: (m.metadata.annotations or { }).${kixKeys.dependsOn} or "";
  # Identity hash of a part of the appns/app instance. rawManifests carry no
  # identity annotation (the CLI stamps it from the store path), so the
  # tests read the resource's own out.identityHash.
  partHash =
    cluster: part:
    builtins.unsafeDiscardStringContext cluster.instances.appns.app.raw.${part}.out.identityHash;

  evalFails = cluster: !(builtins.tryEval (builtins.deepSeq (manifests cluster) true)).success;

  scorecardOn = {
    scorecard = {
      enable = true;
      rules.architecture = import ../rules/architecture.nix { inherit lib; };
    };
  };

  domainFindings =
    cluster:
    builtins.filter (f: lib.hasSuffix "annotationDomainOwnership" (f.rule or "")) (
      (cluster.scorecardReport or { findings = [ ]; }).findings
    );

  # The real kix/packages/envoy-gateway, not a synthetic stand-in: its
  # EnvoyProxy/GatewayClass/Gateway wiring is what decides whether a
  # Gateway can program on a cluster with no LoadBalancer, so the tests
  # want the shipped package, field names and all.
  envoyGatewayPackage = import ../../packages/envoy-gateway;

  # What a kind scenario opts into. Envoy Gateway's own default is a
  # LoadBalancer Service for the proxy, which stock kind never gives an
  # address; NodePort makes the controller publish node addresses
  # instead, and the Gateway reaches Programmed=True.
  kindProxySpec = {
    provider = {
      type = "Kubernetes";
      kubernetes.envoyService.type = "NodePort";
    };
  };

  mkGatewayCluster =
    config:
    mkCluster [
      {
        instances.gwns.gateway = {
          package = envoyGatewayPackage;
          inherit config;
        };
      }
    ];

  # ------------------------------------------------------------------- tests

  tests = {
    # netpol disabled: no policies of any kind, interceptor pipeline inert.
    t01-netpol-off-no-cnps =
      let
        ms = manifests (mkCluster [ baseInstances ]);
      in
      ofKind "CiliumNetworkPolicy" ms == [ ]
      || throw "expected no CNPs, got: ${builtins.toJSON (namesOf (ofKind "CiliumNetworkPolicy" ms))}";

    # DNS dep injection is core and unconditional: even with netpol
    # disabled, a workload with a cross-instance Service edge must depend
    # on the DNS provider's root.
    t02-netpol-off-dns-dep =
      let
        cluster = mkCluster [ baseInstances ];
        appDeployment = byName "app" (ofKind "Deployment" (manifests cluster));
        dnsHash = k8s.extractStoreHash cluster.instances.dns.dns.root.outPath;
        dbSvcHash = k8s.extractStoreHash cluster.instances.dbns.db.raw.service.outPath;
        annot = dependsOn appDeployment;
      in
      (lib.hasInfix dnsHash annot && lib.hasInfix dbSvcHash annot)
      || throw "app depends-on missing dns/db edge; annotation: ${annot}";

    # netpol enabled with a conforming enforcer: per-workload egress CNP,
    # per-namespace default-deny, and the caller-side ingress CNP parented
    # into the CALLEE's namespace via emit.inNamespace.
    t03-netpol-on-cnp-set =
      let
        ms = manifests (mkCluster [
          baseInstances
          netpolOn
        ]);
        cnps = ofKind "CiliumNetworkPolicy" ms;
        callerIngress = byName "app-deployment-app-to-db-ingress" cnps;
      in
      (
        hasName "app-deployment-app-egress" cnps
        && hasName "appns-default-deny" cnps
        && hasName "dbns-default-deny" cnps
        && callerIngress != null
        && callerIngress.metadata.namespace == "dbns"
      )
      || throw "unexpected CNP set: ${builtins.toJSON (namesOf cnps)}";

    # netpol enabled without an enforcer must fail the cluster eval
    # (checks channel), not silently emit nothing.
    t04-netpol-on-no-enforcer-throws = evalFails (mkCluster [
      baseInstances
      { networkPolicy.enable = true; }
    ]);

    # clusterProcessors run in priority order, not attr-name order:
    # zzz (priority 10) must land its resource before aaa (priority 20).
    t05-hook-priority-order =
      let
        marker = name: ctx: {
          resources = [
            (k8s.mkResource {
              apiVersion = "v1";
              kind = "ConfigMap";
              inherit name;
              namespace = ctx.nsResources.appns;
              # Bare core mkResource stamps nothing; real hooks emit through
              # the labelled facade. The cross-resource checks require it.
              labels."app.kubernetes.io/managed-by" = "kix";
            })
          ];
        };
        ms = manifests (mkCluster [
          baseInstances
          {
            hooks.clusterProcessors.zzz-early = {
              priority = 10;
              fn = marker "marker-early";
            };
            hooks.clusterProcessors.aaa-late = {
              priority = 20;
              fn = marker "marker-late";
            };
          }
        ]);
      in
      (indexOfName "marker-early" ms < indexOfName "marker-late" ms)
      || throw "priority order violated: early=${toString (indexOfName "marker-early" ms)} late=${toString (indexOfName "marker-late" ms)}";

    # A hook returning keys outside its channel contract must throw.
    t06-hook-bad-result-throws = evalFails (mkCluster [
      baseInstances
      { hooks.workloadInterceptors.bogus = _ctx: { nonsense = true; }; }
    ]);

    # hostNetwork workloads get no CNPs (policies have no effect on them).
    t07-hostnetwork-no-cnps =
      let
        ms = manifests (mkCluster [
          baseInstances
          netpolOn
          {
            instances.appns.app.package = lib.mkForce (mkAppPackage {
              hostNetwork = true;
            });
          }
        ]);
        cnps = ofKind "CiliumNetworkPolicy" ms;
      in
      (!(hasName "app-deployment-app-egress" cnps) && hasName "db-deployment-db-egress" cnps)
      || throw "hostNetwork CNP handling wrong: ${builtins.toJSON (namesOf cnps)}";

    # directions = "egress": no ingress CNPs anywhere; default-deny spec
    # carries only the egress leg.
    t08-directions-egress-only =
      let
        ms = manifests (mkCluster [
          baseInstances
          netpolOn
          { networkPolicy.directions = "egress"; }
        ]);
        cnps = ofKind "CiliumNetworkPolicy" ms;
        ingressNamed = builtins.filter (n: lib.hasSuffix "-ingress" n) (namesOf cnps);
        deny = byName "appns-default-deny" cnps;
      in
      (ingressNamed == [ ] && deny.spec ? egress && !(deny.spec ? ingress))
      || throw "directions=egress leaked ingress policies: ${builtins.toJSON ingressNamed}";

    # defaultDeny = false: no default-deny policies, workload CNPs remain.
    t09-default-deny-off =
      let
        ms = manifests (mkCluster [
          baseInstances
          netpolOn
          { networkPolicy.defaultDeny = false; }
        ]);
        denies = builtins.filter (n: lib.hasSuffix "-default-deny" n) (
          namesOf (ofKind "CiliumNetworkPolicy" ms)
        );
      in
      denies == [ ] || throw "defaultDeny=false still emitted: ${builtins.toJSON denies}";

    # instanceProcessors receive the emit facade; emit.inNamespace parents
    # a resource into a foreign namespace with this instance as owner.
    t10-emit-in-namespace =
      let
        ms = manifests (mkCluster [
          baseInstances
          {
            hooks.instanceProcessors.test-probe = ctx: {
              resources = lib.optional (ctx.instanceName == "app") (
                (ctx.emit.inNamespace "dbns").mkResource {
                  apiVersion = "v1";
                  kind = "ConfigMap";
                  name = "probe-from-app";
                }
              );
            };
          }
        ]);
        probe = byName "probe-from-app" (ofKind "ConfigMap" ms);
      in
      (probe != null && probe.metadata.namespace == "dbns")
      || throw "emit.inNamespace probe wrong: ${builtins.toJSON probe}";

    # Platform intents materialize and follow the canonical cluster-hook
    # resource order: all default-deny policies precede platform intents.
    t11-platform-intent-order =
      let
        ms = manifests (mkCluster [
          baseInstances
          netpolOn
          { networkPolicy.platformIntents.test-intent.namespace = "dbns"; }
        ]);
        intentIdx = indexOfName "test-intent" ms;
        denyIdxs = map (n: indexOfName n ms) (
          builtins.filter (n: lib.hasSuffix "-default-deny" n) (namesOf ms)
        );
      in
      (denyIdxs != [ ] && builtins.all (i: i < intentIdx) denyIdxs)
      || throw "platform intent ordered before default-deny: intent=${toString intentIdx} denies=${builtins.toJSON denyIdxs}";

    # The package-facing enforcer handle is gated on networkPolicy.enable:
    # enforcer declared but netpol disabled → packages must see null.
    t12a-enforcer-handle-gated-off =
      let
        ms = manifests (mkCluster [
          {
            instances.probens.probe = {
              package = probePackage;
            };
            instances.infra.cilium = {
              package = stubEnforcer;
            };
          }
        ]);
        probe = byName "enforcer-probe" (ofKind "ConfigMap" ms);
      in
      probe.data.enforcer == "unset"
      || throw "netpol disabled but scope.networkPolicyEnforcer was non-null";

    t12b-enforcer-handle-set-on =
      let
        ms = manifests (mkCluster [
          {
            networkPolicy.enable = true;
            instances.probens.probe = {
              package = probePackage;
            };
            instances.infra.cilium = {
              package = stubEnforcer;
            };
          }
        ]);
        probe = byName "enforcer-probe" (ofKind "ConfigMap" ms);
      in
      probe.data.enforcer == "set" || throw "netpol enabled but scope.networkPolicyEnforcer was null";

    # Sentinel namespaces (`_`-prefixed) evaluate but emit no Namespace.
    t13-sentinel-namespace =
      let
        ms = manifests (mkCluster [
          baseInstances
          { instances._cluster.probe.package = probePackage; }
        ]);
      in
      (!(hasName "_cluster" (ofKind "Namespace" ms)) && hasName "enforcer-probe" (ofKind "ConfigMap" ms))
      || throw "sentinel namespace emitted a Namespace resource";

    # --- role model (v2_discussions/127) ---

    # A typo'd role name throws at eval instead of silently never matching.
    t14-unknown-role-throws = evalFails (mkCluster [
      baseInstances
      {
        instances.infra.bad.package = mkCmPackage {
          name = "bad-role";
          metaExtra.roles = [ "storag" ];
        };
      }
    ]);

    # Two managed instances claiming the same role throw eagerly — even
    # with nothing looking the role up (netpol stays disabled here).
    t15-duplicate-role-throws = evalFails (mkCluster [
      baseInstances
      {
        instances.infra.cilium.package = stubEnforcer;
        instances.infra2.cilium2.package = stubEnforcer;
      }
    ]);

    # A managed instance claiming a role the environment owns exclusively
    # (stock kind's kindnet) is a duplicate-symbol error at eval.
    t16-exclusive-binding-throws = evalFails (mkCluster [
      baseInstances
      {
        cluster.roles.cni = {
          binding = "exclusive";
          provider = "kindnet";
        };
        instances.infra.cni.package = mkCmPackage {
          name = "managed-cni";
          metaExtra.roles = [ "cni" ];
        };
      }
    ]);

    # Substrate axiom declared false → hard error (three-valued gate).
    t17-substrate-false-throws = evalFails (mkCluster [
      baseInstances
      {
        cluster.capabilities.daemonSets = false;
        instances.agents.agent.package = dsPackage;
      }
    ]);

    # Substrate axiom unknown (null, the default) → warning only; the
    # cluster still evaluates.
    t18-substrate-null-passes =
      let
        ms = manifests (mkCluster [
          baseInstances
          { instances.agents.agent.package = dsPackage; }
        ]);
      in
      hasName "agent" (ofKind "DaemonSet" ms) || throw "DaemonSet missing under unknown substrate axiom";

    # A role name is a DI alias: a package declaring meta.roles resolves
    # for consumers taking the role name as a dep arg — no instance-level
    # aliases needed.
    t19-role-is-di-alias =
      let
        storageStub = mkCmPackage {
          name = "storage-stub";
          metaExtra.roles = [ "storageClasses" ];
          out.storageClassName = "stub-sc";
        };
        consumer = {
          meta.version = "test";
          build =
            {
              self,
              scope,
              storageClasses,
              ...
            }:
            {
              cm = scope.mkResource {
                apiVersion = "v1";
                kind = "ConfigMap";
                name = "sc-consumer";
                extra.data.sc = storageClasses.out.storageClassName;
              };
              root = self.cm;
            };
        };
        ms = manifests (mkCluster [
          baseInstances
          {
            instances.storage.provider.package = storageStub;
            instances.appns.consumer.package = consumer;
          }
        ]);
        probe = byName "sc-consumer" (ofKind "ConfigMap" ms);
      in
      (probe != null && probe.data.sc == "stub-sc")
      || throw "role-as-alias resolution failed: ${builtins.toJSON probe}";

    # --- stock catalogs / weak role demand (doc 127 §5) ---

    # An OPTIONAL dep on a role name pulls the role provider from
    # availablePackages when nothing else provides it.
    t20-weak-role-demand-pulls-stock =
      let
        ms = manifests (mkCluster [
          baseInstances
          {
            availablePackages.stock-storage.package = stockStorage;
            instances.appns.consumer.package = optionalScConsumer;
          }
        ]);
        probe = byName "sc-consumer" (ofKind "ConfigMap" ms);
      in
      (hasName "stock-sc" (ofKind "ConfigMap" ms) && probe != null && probe.data.sc == "stock-sc-name")
      || throw "stock not pulled by weak role demand: ${builtins.toJSON probe}";

    # No demand → the catalog entry stays on the shelf (demand-rooted
    # closure: nothing is installed because a flavor bundled it).
    t21-no-demand-no-stock =
      let
        ms = manifests (mkCluster [
          baseInstances
          { availablePackages.stock-storage.package = stockStorage; }
        ]);
      in
      !(hasName "stock-sc" (ofKind "ConfigMap" ms)) || throw "stock instantiated without any demand";

    # An optional platform import providing the role suppresses the stock
    # pull — existing environment-provided resolution stays unchanged
    # (the ludo-kind case).
    t22-import-suppresses-stock =
      let
        ms = manifests (mkCluster [
          baseInstances
          {
            availablePackages.stock-storage.package = stockStorage;
            instances.platform.storage = {
              package = eval.mkImport {
                roles = [ "storageClasses" ];
                out.storageClassName = "import-sc";
              };
              optional = true;
            };
            instances.appns.consumer.package = optionalScConsumer;
          }
        ]);
        probe = byName "sc-consumer" (ofKind "ConfigMap" ms);
      in
      (!(hasName "stock-sc" (ofKind "ConfigMap" ms)) && probe != null && probe.data.sc == "import-sc")
      || throw "import did not suppress stock pull: ${builtins.toJSON probe}";

    # The real lithus flavor: preset + catalog. A PVC-shaped demand pulls
    # the whole OpenEBS stock (StorageClasses, per-worker DiskPools) and
    # the consumer resolves the default class through the role.
    t23-lithus-stock-on-demand =
      let
        ms = manifests (mkCluster [
          ../flavors/lithus.nix
          { cluster.flavor.lithus.workers = [ "w1" ]; }
          { instances.appns.consumer.package = optionalScConsumer; }
        ]);
        probe = byName "sc-consumer" (ofKind "ConfigMap" ms);
      in
      (
        hasName "lbs1-pool1-2x" (ofKind "StorageClass" ms)
        && hasName "w1-pool1" (ofKind "DiskPool" ms)
        && probe != null
        && probe.data.sc == "lbs1-pool1-2x"
      )
      || throw "lithus stock not pulled on demand: ${builtins.toJSON (namesOf ms)}";

    # lithus with no storage demand compiles WITHOUT OpenEBS in the
    # artifact — the doc-127 proof case.
    t24-lithus-no-demand-no-openebs =
      let
        ms = manifests (mkCluster [
          ../flavors/lithus.nix
          { cluster.flavor.lithus.workers = [ "w1" ]; }
          { instances.appns.probe.package = probePackage; }
        ]);
      in
      (ofKind "StorageClass" ms == [ ] && ofKind "DiskPool" ms == [ ])
      || throw "lithus emitted storage stock without demand: ${builtins.toJSON (namesOf ms)}";

    # --- capability-ownership decomposition (v2_discussions/128) ---

    # A raw PersistentVolumeClaim from a package build is an eval error.
    t25-raw-pvc-throws = evalFails (mkCluster [
      baseInstances
      { instances.appns.claims.package = mkPvcPackage { }; }
    ]);

    # The explicit meta.unsafe grant is the only way through.
    t26-raw-pvc-unsafe-grant-passes =
      let
        ms = manifests (mkCluster [
          baseInstances
          {
            instances.appns.claims.package = mkPvcPackage {
              metaExtra.unsafe = [ "raw-pvc" ];
            };
          }
        ]);
      in
      hasName "data" (ofKind "PersistentVolumeClaim" ms)
      || throw "granted raw-pvc package did not emit its claim";

    # Kubernetes validates metadata.name in the API server, not in the
    # OpenAPI schema, so kubeconform passes an illegal name and only a real
    # apply refuses it. These run the check at eval instead. The camelCase
    # case is the one that reached a published how-to guide.
    t27a-camelcase-resource-name-throws = evalFails (mkCluster [
      baseInstances
      { instances.appns.bad.package = mkCmPackage { name = "ingressNginx"; }; }
    ]);

    t27b-underscore-resource-name-throws = evalFails (mkCluster [
      baseInstances
      { instances.appns.bad.package = mkCmPackage { name = "my_config"; }; }
    ]);

    # A Service is RFC 1035, not RFC 1123: it must start with a letter, so a
    # name a ConfigMap could carry is still refused here.
    t27c-service-name-starting-with-a-digit-throws = evalFails (mkCluster [
      baseInstances
      {
        instances.appns.svc.package = {
          meta.version = "test";
          build =
            { self, scope, ... }:
            {
              s = scope.mkResource {
                apiVersion = "v1";
                kind = "Service";
                name = "8080-proxy";
                spec.selector.app = "x";
                spec.ports = [ { port = 80; } ];
              };
              root = self.s;
            };
        };
      }
    ]);

    # RBAC names are path segments in the API server, not DNS names, which is
    # why upstream charts ship roles like `prometheus-operator:leader-election`.
    t27d-rbac-name-with-a-colon-passes =
      let
        ms = manifests (mkCluster [
          baseInstances
          {
            instances.appns.rb.package = {
              meta.version = "test";
              build =
                { self, scope, ... }:
                {
                  r = scope.mkResource {
                    apiVersion = "rbac.authorization.k8s.io/v1";
                    kind = "Role";
                    name = "operator:leader-election";
                  };
                  root = self.r;
                };
            };
          }
        ]);
      in
      hasName "operator:leader-election" (ofKind "Role" ms)
      || throw "a Role named with a colon should be accepted";

    # The unsafe vocabulary is closed: a typo'd grant fails the cluster
    # even though the package never builds a PVC (mkCmPackage builds none).
    t27-unknown-unsafe-grant-throws = evalFails (mkCluster [
      baseInstances
      {
        instances.appns.bad.package = mkCmPackage {
          name = "bad-grant";
          metaExtra.unsafe = [ "raw-pvcs" ];
        };
      }
    ]);

    # Two packages declaring the same annotation domain is an eager
    # duplicate-symbol error, scorecard on or off.
    t28-duplicate-annotation-domain-throws = evalFails (mkCluster [
      baseInstances
      {
        instances.infra.op1.package = mkCmPackage {
          name = "op1";
          metaExtra.annotationDomains = [ "example.io" ];
        };
        instances.infra2.op2.package = mkCmPackage {
          name = "op2";
          metaExtra.annotationDomains = [ "example.io" ];
        };
      }
    ]);

    # Annotations under a declared domain without a DI dep on the declarer
    # warn; every other resource in the cluster (all stamped with reserved
    # kix.run annotations) stays silent.
    t29-annotation-domain-missing-dep-warns =
      let
        cluster = mkCluster [
          baseInstances
          scorecardOn
          {
            instances.infra.operator.package = mkCmPackage {
              name = "operator-cm";
              metaExtra.annotationDomains = [ "example.io" ];
            };
            instances.appns.writer.package = mkAnnotatedCmPackage {
              key = "example.io/managed";
            };
          }
        ];
        findings = domainFindings cluster;
      in
      (
        builtins.length findings == 1
        && (builtins.head findings).instance == "writer"
        && lib.hasInfix "example.io" (builtins.head findings).message
        && lib.hasInfix "infra/operator" (builtins.head findings).message
      )
      || throw "expected exactly one missing-dep finding for writer, got: ${builtins.toJSON findings}";

    # A DI dep on the declarer satisfies the lint, and the declarer's own
    # resources may carry its domain freely (self-exemption).
    t30-annotation-domain-dep-satisfies =
      let
        cluster = mkCluster [
          baseInstances
          scorecardOn
          {
            # The declarer itself writes under its domain — must not warn.
            instances.infra.operator.package = mkAnnotatedCmPackage {
              key = "example.io/managed";
              name = "operator-cm";
              metaExtra.annotationDomains = [ "example.io" ];
            };
            # The consumer links the operator via DI — must not warn.
            instances.appns.writer.package = mkAnnotatedCmPackage {
              key = "example.io/managed";
              withOperatorDep = true;
            };
          }
        ];
        findings = domainFindings cluster;
      in
      findings == [ ] || throw "dep/self exemptions failed: ${builtins.toJSON findings}";

    # A domain nobody declares is a dead annotation and warns — unless the
    # operator lists it in scorecard.knownAnnotationDomains.
    t31-annotation-domain-unknown-warns =
      let
        mkGhost =
          extraScorecard:
          mkCluster [
            baseInstances
            (lib.recursiveUpdate scorecardOn extraScorecard)
            {
              instances.appns.writer.package = mkAnnotatedCmPackage {
                key = "ghost.example.com/x";
              };
            }
          ];
        unknownFindings = domainFindings (mkGhost { });
        knownFindings = domainFindings (mkGhost {
          scorecard.knownAnnotationDomains = [ "ghost.example.com" ];
        });
      in
      (
        builtins.length unknownFindings == 1
        && lib.hasInfix "no package in this cluster declares" (builtins.head unknownFindings).message
        && knownFindings == [ ]
      )
      || throw "unknown-domain lint wrong: unknown=${builtins.toJSON unknownFindings} known=${builtins.toJSON knownFindings}";

    # --- weak-role wiring (PR 29 review findings 2-5) ---

    # Role providers are cluster-scoped: weak demand from two namespaces
    # shares ONE stock instance instead of instantiating two strong
    # providers of the same role (which would be a duplicate-role error).
    t32-weak-role-multi-namespace-shares-stock =
      let
        ms = manifests (mkCluster [
          baseInstances
          {
            availablePackages.stock-storage.package = stockStorage;
            instances.ns1.consumer1.package = optionalScConsumer;
            instances.ns2.consumer2.package = optionalScConsumer;
          }
        ]);
        stockCms = builtins.filter (m: (m.metadata.name or "") == "stock-sc") (ofKind "ConfigMap" ms);
        probes = builtins.filter (m: (m.metadata.name or "") == "sc-consumer") (ofKind "ConfigMap" ms);
      in
      (
        builtins.length stockCms == 1
        && builtins.length probes == 2
        && builtins.all (p: p.data.sc == "stock-sc-name") probes
      )
      || throw "multi-namespace weak demand not deduped: stock=${toString (builtins.length stockCms)} probes=${
        builtins.toJSON (map (p: p.data.sc) probes)
      }";

    # An environment binding suppresses the stock pull even without an
    # import instance — flavors declare `cni` exclusively this way. The
    # compiler must not instantiate stock and then refuse its own work.
    t33-env-exclusive-binding-suppresses-stock =
      let
        ms = manifests (mkCluster [
          baseInstances
          {
            cluster.roles.storageClasses.binding = "exclusive";
            availablePackages.stock-storage.package = stockStorage;
            instances.appns.consumer.package = optionalScConsumer;
          }
        ]);
        probe = byName "sc-consumer" (ofKind "ConfigMap" ms);
      in
      (!(hasName "stock-sc" (ofKind "ConfigMap" ms)) && probe != null && probe.data.sc == "missing")
      || throw "exclusive binding did not suppress stock pull: ${builtins.toJSON probe}";

    # Shadowable: the environment default is the provider — pulling stock
    # would silently shadow it, so the shelf entry stays untouched.
    t34-env-shadowable-binding-suppresses-stock =
      let
        ms = manifests (mkCluster [
          baseInstances
          {
            cluster.roles.storageClasses.binding = "shadowable";
            availablePackages.stock-storage.package = stockStorage;
            instances.appns.consumer.package = optionalScConsumer;
          }
        ]);
      in
      !(hasName "stock-sc" (ofKind "ConfigMap" ms))
      || throw "shadowable binding did not suppress stock pull";

    # A never-activated optional instance claiming a role a mandatory
    # instance also provides is NOT a conflict — it emits nothing this
    # eval, so it must neither win the role nor trip the eager check.
    t35-inactive-optional-role-is-not-a-conflict =
      let
        ms = manifests (mkCluster [
          baseInstances
          {
            instances.storage.provider.package = stockStorage;
            instances.shelf.spare = {
              package = stockStorage;
              optional = true;
            };
            instances.appns.consumer.package = optionalScConsumer;
          }
        ]);
        stockCms = builtins.filter (m: (m.metadata.name or "") == "stock-sc") (ofKind "ConfigMap" ms);
        probe = byName "sc-consumer" (ofKind "ConfigMap" ms);
      in
      (builtins.length stockCms == 1 && probe != null && probe.data.sc == "stock-sc-name")
      || throw "inactive optional treated as role conflict: stock=${toString (builtins.length stockCms)} probe=${builtins.toJSON probe}";

    # Weak role demand propagates transitively: a catalog package pulled in
    # by a REQUIRED dep has its own weak storageClasses demand honored.
    t36-weak-role-demand-transitive =
      let
        ms = manifests (mkCluster [
          baseInstances
          {
            availablePackages.middle.package = weakMiddlePackage;
            availablePackages.stock-storage.package = stockStorage;
            instances.appns.top.package = weakMiddleConsumer;
          }
        ]);
        middleCm = byName "middle" (ofKind "ConfigMap" ms);
      in
      (
        hasName "stock-sc" (ofKind "ConfigMap" ms)
        && middleCm != null
        && middleCm.data.sc == "stock-sc-name"
      )
      || throw "transitive weak demand not honored: ${builtins.toJSON middleCm}";

    # A typo'd role on a shelf entry throws (same closed vocabulary as
    # instantiated meta.roles) instead of silently never matching.
    t37-catalog-role-typo-throws = evalFails (mkCluster [
      baseInstances
      {
        availablePackages.bad-storage.package = mkCmPackage {
          name = "bad";
          metaExtra.roles = [ "storageClases" ];
        };
        instances.appns.consumer.package = optionalScConsumer;
      }
    ]);

    # Directly wired deps (deps.operator = ref...) count as linking against
    # the declarer — the domain lint must not false-warn on explicit wiring.
    t38-annotation-domain-direct-dep-satisfies =
      let
        cluster = mkCluster [
          baseInstances
          scorecardOn
          {
            instances.infra.operator.package = mkCmPackage {
              name = "operator-cm";
              metaExtra.annotationDomains = [ "example.io" ];
            };
          }
          (
            { ref, ... }:
            {
              instances.appns.writer = {
                package = mkAnnotatedCmPackage {
                  key = "example.io/managed";
                  withOperatorDep = true;
                };
                deps.operator = ref.infra.operator;
              };
            }
          )
        ];
        findings = domainFindings cluster;
      in
      findings == [ ]
      || throw "direct-wired dep did not satisfy domain lint: ${builtins.toJSON findings}";

    # ---- typed-facts edge semantics (core/facts.nix) ----------------------

    # out.name alone is structural: no endpoint fact flows, so netpol derives
    # NO edge to db (no caller-ingress CNP) — but the identity hit keeps the
    # conservative DNS-ordering dep, and the derivation record (depends-on)
    # is untouched.
    t39-name-only-no-netpol-edge =
      let
        nameOnly = {
          instances.appns.app.package = lib.mkForce (mkAppPackage {
            wireDb = db: db.out.name;
          });
        };
        cluster = mkCluster [
          baseInstances
          netpolOn
          nameOnly
        ];
        ms = manifests cluster;
        cnps = ofKind "CiliumNetworkPolicy" ms;
        appDeployment = byName "app" (ofKind "Deployment" ms);
        dnsHash = k8s.extractStoreHash cluster.instances.dns.dns.root.outPath;
        annot = dependsOn appDeployment;
      in
      (
        !(hasName "app-deployment-app-to-db-ingress" cnps)
        && hasName "app-deployment-app-egress" cnps
        && lib.hasInfix dnsHash annot
      )
      || throw "name-only wiring should drop the netpol edge but keep DNS dep; CNPs: ${builtins.toJSON (namesOf cnps)}, depends-on: ${annot}";

    # db.out.fqdn embedded in a ConfigMap, workload only references the CM:
    # the endpoint fact conducts through the carrier's seal, so the full CNP
    # set appears exactly as if the workload dialed directly.
    t40-configmap-indirection-edge =
      let
        indirect = {
          instances.appns.app.package = lib.mkForce indirectAppPackage;
        };
        ms = manifests (mkCluster [
          baseInstances
          netpolOn
          indirect
        ]);
        cnps = ofKind "CiliumNetworkPolicy" ms;
        callerIngress = byName "app-deployment-app-to-db-ingress" cnps;
      in
      (callerIngress != null && callerIngress.metadata.namespace == "dbns")
      || throw "endpoint fact did not conduct through ConfigMap; CNPs: ${builtins.toJSON (namesOf cnps)}";

    # facts.refOnly is the per-use escape hatch: identity (ordering) kept,
    # dialing claim stripped — fqdn used as a display string derives no edge.
    t41-refonly-strips-edge =
      let
        refOnlyWired = {
          instances.appns.app.package = lib.mkForce (mkAppPackage {
            wireDb = db: k8s.facts.refOnly db.out.fqdn;
          });
        };
        cluster = mkCluster [
          baseInstances
          netpolOn
          refOnlyWired
        ];
        ms = manifests cluster;
        cnps = ofKind "CiliumNetworkPolicy" ms;
        appDeployment = byName "app" (ofKind "Deployment" ms);
        dbSvcHash = k8s.extractStoreHash cluster.instances.dbns.db.raw.service.outPath;
      in
      (
        !(hasName "app-deployment-app-to-db-ingress" cnps)
        && lib.hasInfix dbSvcHash (dependsOn appDeployment)
      )
      || throw "refOnly should strip the edge but keep the identity dep; CNPs: ${builtins.toJSON (namesOf cnps)}";

    # ---- meta.factBehavior (terminate/conduct table for CRDs) -------------

    # A terminate-declared CR absorbing an endpoint fact: netpol opens holes
    # for the OPERAND pods (podSelector over the raw manifest), from the
    # instance phase — egress in the CR's namespace, caller-ingress into the
    # target's. The consumer deployment (which only names the CR) gets none.
    t42-cr-terminate-operand-cnps =
      let
        withCr = {
          instances.opns.test-operator.package = mkOperatorPackage { factBehavior = testClusterBehavior; };
          instances.appns.app.package = lib.mkForce crConsumerPackage;
        };
        ms = manifests (mkCluster [
          baseInstances
          netpolOn
          withCr
        ]);
        cnps = ofKind "CiliumNetworkPolicy" ms;
        operandEgress = byName "app-testcluster-mycluster-egress" cnps;
        callerIngress = byName "app-testcluster-mycluster-to-db-ingress" cnps;
      in
      (
        operandEgress != null
        && operandEgress.spec.endpointSelector.matchLabels."test.io/cluster" == "mycluster"
        && callerIngress != null
        && callerIngress.metadata.namespace == "dbns"
        && !(hasName "app-deployment-consumer-to-db-ingress" cnps)
      )
      || throw "operand CNPs wrong; CNPs: ${builtins.toJSON (namesOf cnps)}";

    # Without a declaration, an unknown CR kind conducts (default): the fact
    # flows through the CR's out.* to the deployment that references it, so
    # the WORKLOAD gets the db edge. (An eval-time warning names the gap.)
    t43-undeclared-cr-conducts =
      let
        withCr = {
          instances.appns.app.package = lib.mkForce rawCrConsumerPackage;
        };
        ms = manifests (mkCluster [
          baseInstances
          netpolOn
          withCr
        ]);
        cnps = ofKind "CiliumNetworkPolicy" ms;
      in
      hasName "app-deployment-consumer-to-db-ingress" cnps
      || throw "undeclared CR should conduct the fact to the workload; CNPs: ${builtins.toJSON (namesOf cnps)}";

    # cluster.factBehavior (keyed "group/Kind") covers builder-less CRs and
    # overrides CRD declarations: the raw-built CR terminates, operand CNPs
    # appear, and the workload edge from conduction disappears.
    t44-cluster-fact-behavior-override =
      let
        withCr = {
          instances.appns.app.package = lib.mkForce rawCrConsumerPackage;
          cluster.factBehavior."test.io/TestCluster" = testClusterBehavior;
        };
        ms = manifests (mkCluster [
          baseInstances
          netpolOn
          withCr
        ]);
        cnps = ofKind "CiliumNetworkPolicy" ms;
      in
      (
        hasName "app-testcluster-mycluster-egress" cnps
        && !(hasName "app-deployment-consumer-to-db-ingress" cnps)
      )
      || throw "cluster override should terminate the raw CR; CNPs: ${builtins.toJSON (namesOf cnps)}";

    # untrackedRef's marker is proof of a deliberate opt-out, not a resource.
    # Stamping it into depends-on yields a hash nothing can ever resolve, and
    # `kix health` reports the consumer as depending on a MISSING resource
    # forever. The marker's context must reach the validators and stop there.
    t45-untracked-ref-not-a-dep =
      let
        secretName = k8s.markers.mkUntrackedRef "operator-minted-certs";
        markerHash = k8s.extractStoreHash (
          builtins.head (builtins.attrNames (builtins.getContext secretName))
        );
        deployment = k8s.mkResource {
          apiVersion = "apps/v1";
          kind = "Deployment";
          name = "consumer";
          namespace = {
            name = "appns";
            outPath = "/nix/store/${builtins.substring 0 32 (builtins.hashString "sha256" "ns")}-ns";
          };
          spec.template.spec.volumes = [ { secret = { inherit secretName; }; } ];
        };
        annot = dependsOn deployment.rawManifest;
      in
      (builtins.getContext secretName != { } && !(lib.hasInfix markerHash annot))
      || throw "untracked-ref marker ${markerHash} leaked into depends-on: '${annot}'";

    # ------------------------------------------------------------------
    # Collapse-rule normalization + kix.keep (kixpkgs#9).

    # A literal `{ }`/`[ ]` is an intentional Kubernetes value (emptyDir
    # volume source, select-everything selector, default-deny rule list)
    # and must reach the output.
    t46-collapse-keeps-literal-empties =
      let
        m = k8s.normalize.normalizeManifest {
          volumes = [
            {
              name = "tmp";
              emptyDir = { };
            }
          ];
          ingress = [ ];
        };
      in
      (
        m.volumes == [
          {
            name = "tmp";
            emptyDir = { };
          }
        ]
        && m.ingress == [ ]
      )
      || throw "literal empties must survive normalization: ${builtins.toJSON m}";

    # A container whose members are all null is the shape merged unset
    # options produce. It collapses to absent, and the collapse cascades
    # upward through wrapper attrsets.
    t47-collapse-drops-null-containers =
      let
        m = k8s.normalize.normalizeManifest {
          resources = {
            limits = null;
            requests = null;
          };
          metadata = {
            annotations = {
              a = null;
            };
          };
          kind = "Pod";
        };
      in
      (m == { kind = "Pod"; })
      || throw "all-null containers must collapse to absent: ${builtins.toJSON m}";

    # kix.keep protects a constructor whose optional arguments are all
    # null: the container renders as an empty shell instead of vanishing.
    t48-keep-protects-all-null-constructor =
      let
        m = k8s.normalize.normalizeManifest {
          emptyDir = k8s.normalize.keep {
            medium = null;
            sizeLimit = null;
          };
          matchExprs = k8s.normalize.keep [
            null
            null
          ];
        };
      in
      (m.emptyDir == { } && m.matchExprs == [ ])
      || throw "keep must render the empty shell: ${builtins.toJSON m}";

    # The marker survives a later merge that introduces fresh nulls; the
    # eager form of keep lost this case (a kept { } re-filled with nulls
    # collapsed again).
    t49-keep-survives-null-merge =
      let
        merged = lib.recursiveUpdate {
          emptyDir = k8s.normalize.keep { sizeLimit = null; };
        } { emptyDir.medium = null; };
        m = k8s.normalize.normalizeManifest merged;
      in
      (m.emptyDir or null == { })
      || throw "keep must survive a null-introducing merge: ${builtins.toJSON m}";

    # The marker never reaches the output. Schema subtrees (attrsets with a
    # `type` key) are normalized like everything else: there is no field-name
    # carve-out passing them verbatim, because the collapse rule already
    # keeps the literal empties such a shield would exist to protect.
    t50-keep-marker-never-leaks =
      let
        m = k8s.normalize.normalizeManifest {
          a = k8s.normalize.keep { x = 1; };
          schema = k8s.normalize.keep { type = "object"; };
          crdSchema = {
            type = "object";
            properties.spec = {
              type = "object";
              properties = { };
              default = null;
            };
          };
        };
        json = builtins.toJSON m;
      in
      (
        !(lib.hasInfix "_kixKeep" json)
        && m.a == { x = 1; }
        && m.schema == { type = "object"; }
        &&
          m.crdSchema.properties.spec == {
            type = "object";
            properties = { };
          }
      )
      || throw "keep marker leaked or schema subtree mishandled: ${json}";

    # mkResource resolves keeps at the boundary: rawManifest carries no
    # marker and is byte-identical to the literal form, so switching a
    # constructor to keep cannot churn resource identity hashes.
    t51-mkresource-resolves-keeps =
      let
        mk =
          src:
          k8s.mkResource {
            apiVersion = "apps/v1";
            kind = "Deployment";
            name = "kept";
            namespace = {
              name = "appns";
              outPath = "/nix/store/${builtins.substring 0 32 (builtins.hashString "sha256" "ns")}-ns";
            };
            spec.template.spec.volumes = [
              {
                name = "tmp";
                emptyDir = src;
              }
            ];
          };
        viaKeep = (mk (k8s.normalize.keep { medium = null; })).rawManifest;
        viaLiteral = (mk { }).rawManifest;
      in
      (
        viaKeep == viaLiteral
        &&
          viaKeep.spec.template.spec.volumes == [
            {
              name = "tmp";
              emptyDir = { };
            }
          ]
      )
      || throw "mkResource must resolve keeps to the literal form: ${builtins.toJSON viaKeep}";

    # Lists: null elements are dropped, and an element that collapses
    # entirely is removed from its list.
    t52-collapse-list-semantics =
      let
        m = k8s.normalize.normalizeManifest {
          containers = [
            { name = "app"; }
            { env = null; }
          ];
          args = [
            null
            "x"
            null
          ];
        };
      in
      (m.containers == [ { name = "app"; } ] && m.args == [ "x" ])
      || throw "list normalization wrong: ${builtins.toJSON m}";

    # The volumeHasSource rule sees volumes the way the renderer will: a
    # source that collapses (all-null members) is flagged, a literal { }
    # passes.
    t53-volume-source-rule =
      let
        rules = import ../rules { inherit lib; };
        rule = rules.reliability.volumeHasSource;
        bad = {
          kind = "Deployment";
          spec.template.spec.volumes = [
            {
              name = "b";
              emptyDir = {
                medium = null;
              };
            }
          ];
        };
        good = {
          kind = "Deployment";
          spec.template.spec.volumes = [
            {
              name = "g";
              emptyDir = { };
            }
          ];
        };
      in
      (rule.check { resource = bad; } != [ ] && rule.check { resource = good; } == [ ])
      || throw "volumeHasSource rule misjudged: bad=${builtins.toJSON (rule.check { resource = bad; })}";

    # monitorSelectorMatchesService sees a ServiceRef marker that declares its
    # Service's labels as that Service, so a self-monitor over an
    # operator-created Service can be checked. Labels that match nothing still
    # fail.
    t54-monitor-rule-sees-service-refs =
      let
        rule = (import ../rules/architecture.nix { inherit lib; }).monitorSelectorMatchesService;
        marker = {
          kind = "PackageInstance";
          metadata = {
            name = "service-ref-am-alertmanager-operated";
            namespace = "mon";
            annotations = {
              ${kixKeys.mode} = "import";
              ${kixKeys.importKind} = "Service";
              ${kixKeys.importName} = "alertmanager-operated";
              ${kixKeys.serviceLabels} = builtins.toJSON { operated-alertmanager = "true"; };
              ${kixKeys.servicePorts} = builtins.toJSON [
                {
                  name = "web";
                  port = 9093;
                }
              ];
            };
          };
        };
        monitor = labels: {
          kind = "ServiceMonitor";
          metadata = {
            name = "am-self";
            namespace = "mon";
          };
          spec = {
            selector.matchLabels = labels;
            namespaceSelector.matchNames = [ "mon" ];
            endpoints = [ { port = "web"; } ];
          };
        };
        run =
          labels:
          rule.check {
            allInstances.mon = { };
            allResources = [
              marker
              (monitor labels)
            ];
          };
        good = run { operated-alertmanager = "true"; };
        bad = run { "app.kubernetes.io/name" = "alertmanager"; };
      in
      (good == [ ] && bad != [ ])
      || throw "monitor rule vs ServiceRef: good=${builtins.toJSON good} bad=${builtins.toJSON bad}";

    # A ServiceRef's out.fqdn has the same form as a rendered Service's:
    # `<name>.<ns>.svc.<clusterDomain>`. It used to stop at `.svc`, which
    # only resolves through the pod's DNS search path.
    t57-service-ref-fqdn-carries-cluster-domain =
      let
        refPackage = {
          build =
            { self, scope, ... }:
            {
              ref = scope.mkServiceRef {
                name = "operated";
                selector.app = "op";
                ports = [
                  {
                    name = "http";
                    port = 80;
                  }
                ];
              };
              cm = scope.mkResource {
                apiVersion = "v1";
                kind = "ConfigMap";
                name = "wiring";
                data.url = "http://${self.ref.out.fqdn}:${self.ref.out.port}/";
              };
              root = self.cm;
            };
        };
        urlWith =
          extraModule:
          let
            ms = manifests (
              mkCluster (
                [
                  baseInstances
                  { instances.infra.op.package = refPackage; }
                ]
                ++ extraModule
              )
            );
            cm = lib.findFirst (m: (m.metadata.name or "") == "wiring") null ms;
          in
          cm.data.url;
        dflt = urlWith [ ];
        custom = urlWith [ { clusterDomain = "k8s.example"; } ];
      in
      (
        dflt == "http://operated.infra.svc.cluster.local:80/"
        && custom == "http://operated.infra.svc.k8s.example:80/"
      )
      || throw "ref fqdn: default=${dflt} custom=${custom}";
    # Two same-named Services are a name collision, not a label question:
    # the rule must say so instead of prescribing a label fix that cannot
    # converge (kixpkgs#71 item 14).
    t55-distinct-labels-rule-names-a-collision =
      let
        rule = (import ../rules/architecture.nix { inherit lib; }).distinctSameKindLabels;
        svc = labels: {
          kind = "Service";
          metadata = {
            name = "same";
            namespace = "ns";
            inherit labels;
          };
        };
        findings = rule.check {
          instanceName = "inst";
          resources = [
            (svc { a = "1"; })
            (svc { a = "2"; })
          ];
        };
        msg = builtins.concatStringsSep " " (map (f: f.message) findings);
      in
      (
        builtins.length findings == 1
        && lib.hasInfix "name collision" msg
        && !(lib.hasInfix "own label" msg)
      )
      || throw "expected one collision finding, got: ${msg}";

    # A chart-rendered workload gets the pod-spec validators (kixpkgs#71
    # item 13): a probe naming a port the container does not declare fails
    # the eval; the same workload without it builds.
    t56-helm-workload-runs-validators =
      let
        chartWorkload = probe: {
          build =
            { self, scope, ... }:
            {
              web = scope.mkHelmWorkload {
                apiVersion = "apps/v1";
                kind = "Deployment";
                name = "chart-web";
                spec = {
                  selector.matchLabels.app = "chart-web";
                  template = {
                    metadata.labels.app = "chart-web";
                    spec.containers = [
                      (
                        {
                          name = "c";
                          image = "img:1";
                          ports = [
                            {
                              name = "http";
                              containerPort = 80;
                            }
                          ];
                        }
                        // probe
                      )
                    ];
                  };
                };
              };
              root = self.web;
            };
        };
        bad = evalFails (mkCluster [
          baseInstances
          { instances.infra.chart.package = chartWorkload { readinessProbe.httpGet.port = "nope"; }; }
        ]);
        good = manifests (mkCluster [
          baseInstances
          { instances.infra.chart.package = chartWorkload { }; }
        ]);
      in
      (bad && builtins.any (m: (m.metadata.name or "") == "chart-web") good)
      || throw "helm workload validators: bad=${toString bad}";

    # Shapes valid Kubernetes charts really render must pass the validators
    # (red team on #75): null list fields from an unset toYaml value, a
    # duplicate env name (the API server warns, last wins), and a fieldRef
    # into a label (the allow clause used to throw "invalid regular
    # expression" on exactly that path).
    t58-helm-workload-accepts-real-chart-shapes =
      let
        chartPackage = {
          build =
            { self, scope, ... }:
            {
              web = scope.mkHelmWorkload {
                apiVersion = "apps/v1";
                kind = "Deployment";
                name = "chart-real";
                spec = {
                  selector.matchLabels.app = "chart-real";
                  template = {
                    metadata.labels.app = "chart-real";
                    spec = {
                      volumes = null;
                      initContainers = null;
                      containers = [
                        {
                          name = "c";
                          image = "img:1";
                          envFrom = null;
                          env = [
                            {
                              name = "MODE";
                              value = "default";
                            }
                            {
                              name = "MODE";
                              value = "override";
                            }
                            {
                              name = "APP";
                              valueFrom.fieldRef.fieldPath = "metadata.labels['app']";
                            }
                            {
                              name = "HOST_IPS";
                              valueFrom.fieldRef.fieldPath = "status.hostIPs";
                            }
                          ];
                        }
                      ];
                    };
                  };
                };
              };
              root = self.web;
            };
        };
        ms = manifests (mkCluster [
          baseInstances
          { instances.infra.chart.package = chartPackage; }
        ]);
      in
      builtins.any (m: (m.metadata.name or "") == "chart-real") ms || throw "chart-real missing";

    # The same fieldRef path passes the kix-native constructor too.
    t59-native-workload-accepts-label-fieldref =
      let
        pkg = {
          build =
            { self, scope, ... }:
            {
              web = scope.mkDeployment {
                name = "native-fr";
                spec = {
                  selector.matchLabels.app = "native-fr";
                  template.spec.containers = [
                    {
                      name = "c";
                      image = "img:1";
                      env = [
                        {
                          name = "APP";
                          valueFrom.fieldRef.fieldPath = "metadata.annotations['x/y']";
                        }
                      ];
                    }
                  ];
                };
              };
              root = self.web;
            };
        };
        ms = manifests (mkCluster [
          baseInstances
          { instances.infra.fr.package = pkg; }
        ]);
      in
      builtins.any (m: (m.metadata.name or "") == "native-fr") ms || throw "native-fr missing";

    # ------------------------------------------------------- kix.healthCheck
    #
    # A package with a Deployment, a Service over the package's selector
    # labels, and a probe Job that dials the Service. `wire` chooses how
    # the probe gets the address; `script` is the probe body.
    t60-healthcheck-identity-follows-target =
      let
        cluster =
          target:
          mkCluster [
            baseInstances
            {
              instances.appns.app.package = lib.mkForce (mkProbedPackage {
                targetPort = target;
              });
            }
          ];
        a = cluster 8080;
        b = cluster 9090;
        jobA = byName "app-health" (ofKind "Job" (manifests a));
        jobB = byName "app-health" (ofKind "Job" (manifests b));
      in
      (
        jobA != null
        && jobB != null
        && partHash a "healthCheck" != partHash b "healthCheck"
        && jobA.metadata.name == jobB.metadata.name
        && (jobA.metadata.annotations.${kixKeys.rerun} or "") == "on-change"
      )
      || throw "probe identity did not follow its target";

    # The probe reads a dependency-injected package through `deps` and the
    # Job's depends-on carries that package's Service.
    t61-healthcheck-deps-arg =
      let
        cluster = mkCluster [
          baseInstances
          { instances.appns.app.package = lib.mkForce depsProbePackage; }
        ];
        ms = manifests cluster;
        job = byName "app-health" (ofKind "Job" ms);
        dbSvcHash = builtins.unsafeDiscardStringContext cluster.instances.dbns.db.raw.service.out.identityHash;
        env = builtins.head (job.spec.template.spec.containers or [ ]);
        dbUrl = builtins.head (builtins.filter (e: e.name == "DB_URL") (env.env or [ ]));
      in
      (
        job != null
        && lib.hasInfix dbSvcHash (dependsOn job)
        && dbUrl.value == "http://db.dbns.svc.cluster.local:5432"
      )
      || throw "probe did not read the db Service through deps; depends-on: ${dependsOn job}";

    # Under an enforcer the probe Job gets the same egress edge any
    # consumer gets: a CNP named after the Job whose endpoint selector is
    # the probe pod's labels, listed in the Job's requires.
    t62-healthcheck-job-egress =
      let
        cluster = mkCluster [
          baseInstances
          netpolOn
          { instances.appns.app.package = lib.mkForce (mkProbedPackage { }); }
        ];
        ms = manifests cluster;
        cnp = byName "app-job-app-health-egress" (ofKind "CiliumNetworkPolicy" ms);
        cnpHash =
          builtins.unsafeDiscardStringContext
            (lib.findFirst (
              r: (r.kind or "") == "CiliumNetworkPolicy" && r.name == "app-job-app-health-egress"
            ) (throw "CNP not in the Job's requires") cluster.instances.appns.app.raw.healthCheck.requires)
            .out.identityHash;
        job = byName "app-health" (ofKind "Job" ms);
        egress = builtins.filter (r: (r.stubRule or "") == "service-egress") (cnp.spec.egress or [ ]);
        rule = builtins.head egress;
        podLabels = job.spec.template.metadata.labels;
        refOnlyMs = manifests (mkCluster [
          baseInstances
          netpolOn
          {
            instances.appns.app.package = lib.mkForce (mkProbedPackage {
              wire = svc: k8s.facts.refOnly (svc.out.url { });
            });
          }
        ]);
      in
      (
        cnp != null
        && job != null
        && builtins.length egress == 1
        && rule.namespace == "appns"
        &&
          rule.selector == {
            "app.kubernetes.io/name" = "app";
            "app.kubernetes.io/instance" = "app";
          }
        && cnp.spec.endpointSelector.matchLabels == podLabels
        && lib.hasInfix "requires:${cnpHash}" (dependsOn job)
        && hasName "app-job-app-health-to-app-ingress" (ofKind "CiliumNetworkPolicy" ms)
        && !(hasName "app-job-app-health-to-app-ingress" (ofKind "CiliumNetworkPolicy" refOnlyMs))
        && builtins.all (r: (r.stubRule or "") != "service-egress") (
          (byName "app-job-app-health-egress" (ofKind "CiliumNetworkPolicy" refOnlyMs)).spec.egress or [ ]
        )
      )
      || throw "probe egress edge wrong; CNPs: ${builtins.toJSON (namesOf (ofKind "CiliumNetworkPolicy" ms))}";

    # The default runtime is the slim Python image pinned by digest; a
    # package-supplied runtime renders as given.
    t63-healthcheck-runtime-default =
      let
        container =
          pkg:
          builtins.head (
            (byName "app-health" (
              ofKind "Job" (
                manifests (mkCluster [
                  baseInstances
                  { instances.appns.app.package = lib.mkForce pkg; }
                ])
              )
            )).spec.template.spec.containers
          );
        dflt = container (mkProbedPackage { });
        custom = container (mkProbedPackage {
          runtime = {
            image = {
              repository = "example/probe";
              tag = "1";
              digest = null;
            };
            file = "probe.sh";
            interpreter = [
              "/bin/sh"
              "-eu"
            ];
            env = { };
          };
        });
      in
      (
        dflt.image
        == "docker.io/library/python:3.13-slim@sha256:9d2e5553305c7c7b0097999bb17187c69b921ccd6bc9d40e4bb5ebe652c00285"
        &&
          dflt.command == [
            "python3"
            "/probe/health-check.py"
          ]
        && dflt.terminationMessagePolicy == "FallbackToLogsOnError"
        && custom.image == "example/probe:1"
        &&
          custom.command == [
            "/bin/sh"
            "-eu"
            "/probe/probe.sh"
          ]
      )
      || throw "runtime rendering wrong: ${
        builtins.toJSON [
          dflt.image
          dflt.command
          custom.image
          custom.command
        ]
      }";

    # The script lives in a stable-name ConfigMap the Job mounts; a script
    # change changes the Job's identity hash but not its name.
    t64-healthcheck-script-configmap =
      let
        build =
          script:
          mkCluster [
            baseInstances
            {
              instances.appns.app.package = lib.mkForce (mkProbedPackage {
                inherit script;
              });
            }
          ];
        a = build "print('a')";
        b = build "print('b')";
        cmA = byName "app-health-script" (ofKind "ConfigMap" (manifests a));
        cmB = byName "app-health-script" (ofKind "ConfigMap" (manifests b));
        jobA = byName "app-health" (ofKind "Job" (manifests a));
        jobB = byName "app-health" (ofKind "Job" (manifests b));
        volume = builtins.head (jobA.spec.template.spec.volumes or [ ]);
      in
      (
        cmA != null
        && cmA.data."health-check.py" == "print('a')"
        && cmB.data."health-check.py" == "print('b')"
        && volume.configMap.name == "app-health-script"
        && lib.hasInfix (partHash a "healthCheckScript") (dependsOn jobA)
        && partHash a "healthCheck" != partHash b "healthCheck"
        && jobA.metadata.name == jobB.metadata.name
      )
      || throw "script ConfigMap wiring wrong";

    # The probe pod carries its own labels: the package's Service, which
    # selects the package's selector labels, must not select it.
    t65-healthcheck-pod-not-in-service =
      let
        ms = manifests (mkCluster [
          baseInstances
          { instances.appns.app.package = lib.mkForce (mkProbedPackage { }); }
        ]);
        job = byName "app-health" (ofKind "Job" ms);
        svc = byName "app" (ofKind "Service" ms);
        podLabels = job.spec.template.metadata.labels;
        selected = builtins.all (k: (podLabels.${k} or null) == svc.spec.selector.${k}) (
          builtins.attrNames svc.spec.selector
        );
      in
      (job != null && svc != null && !selected)
      || throw "the package Service selects the probe pod: ${builtins.toJSON podLabels}";

    # The probe waits for the package root without being told: a Job whose
    # env dials nothing of the package still lists the root in requires.
    # When the env already dials the root, it is not listed twice.
    t67-healthcheck-waits-for-root =
      let
        depsCluster = mkCluster [
          baseInstances
          { instances.appns.app.package = lib.mkForce depsProbePackage; }
        ];
        depsJob = byName "app-health" (ofKind "Job" (manifests depsCluster));
        rootHash = builtins.unsafeDiscardStringContext depsCluster.instances.appns.app.raw.deployment.out.identityHash;
        dialCluster = mkCluster [
          baseInstances
          { instances.appns.app.package = lib.mkForce (mkProbedPackage { }); }
        ];
        dialJob = byName "app-health" (ofKind "Job" (manifests dialCluster));
        svcHash = builtins.unsafeDiscardStringContext dialCluster.instances.appns.app.raw.svc.out.identityHash;
      in
      (
        depsJob != null
        && lib.hasInfix "requires:${rootHash}" (dependsOn depsJob)
        && dialJob != null
        && lib.hasInfix svcHash (dependsOn dialJob)
        && !(lib.hasInfix "requires:${svcHash}" (dependsOn dialJob))
      )
      || throw "root ordering wrong; deps probe: ${dependsOn depsJob}; dialing probe: ${dependsOn dialJob}";

    # The helper owns the time budget: RETRY_FOR is handed to the script,
    # the deadline is sized from it, and a deadline with no room for a
    # round after the window fails the build.
    t68-healthcheck-time-budget =
      let
        job =
          extra:
          byName "app-health" (
            ofKind "Job" (
              manifests (mkCluster [
                baseInstances
                {
                  instances.appns.app.package = lib.mkForce {
                    meta.version = "test";
                    options.healthCheck = kixlib.options.healthCheck;
                    build = [
                      (
                        { self, scope, ... }:
                        {
                          root = self.cm;
                          cm = scope.mkResource {
                            apiVersion = "v1";
                            kind = "ConfigMap";
                            name = "app";
                            data.k = "v";
                          };
                        }
                      )
                      (kixlib.healthCheck ({ script = "print('ok')"; } // extra))
                    ];
                  };
                  instances.appns.app.config.healthCheck = {
                    enable = true;
                    retryFor = 40;
                  };
                }
              ])
            )
          );
        dflt = job { };
        given = job { activeDeadlineSeconds = 200; };
        env = builtins.head (builtins.head dflt.spec.template.spec.containers).env;
        retryEnv = builtins.filter (e: e.name == "RETRY_FOR") (
          (builtins.head dflt.spec.template.spec.containers).env
        );
        tooShort = mkCluster [
          baseInstances
          {
            instances.appns.app.package = lib.mkForce (
              mkProbedPackage { }
              // {
                build = (mkProbedPackage { }).build ++ [
                  (kixlib.healthCheck {
                    script = "print('ok')";
                    partName = "second";
                    activeDeadlineSeconds = 100;
                  })
                ];
              }
            );
          }
        ];
      in
      builtins.seq env (
        (
          dflt != null
          && dflt.spec.activeDeadlineSeconds == 40 + kixlib.healthCheck.roundBudget
          && (builtins.head retryEnv).value == "40"
          && given.spec.activeDeadlineSeconds == 200
          && evalFails tooShort
        )
        || throw "time budget wrong: deadline ${toString dflt.spec.activeDeadlineSeconds}, RETRY_FOR ${builtins.toJSON retryEnv}"
      );

    # A structural output is read, not dialed: the consumer gets the
    # ordering edge and no egress rule, and the identity lint stays quiet.
    t69-structural-output =
      let
        cluster = mkCluster [
          baseInstances
          netpolOn
          {
            instances.appns.app.package = lib.mkForce {
              meta.version = "test";
              build =
                { self, scope, ... }:
                {
                  root = self.deployment;
                  svc = scope.mkResource {
                    apiVersion = "v1";
                    kind = "Service";
                    name = "app";
                    spec = {
                      selector = scope.selectorLabels;
                      ports = [
                        {
                          name = "http";
                          port = 80;
                        }
                      ];
                    };
                    outputs.replicas = k8s.facts.structural "2";
                  };
                  deployment = scope.mkDeployment {
                    name = "app";
                    spec = {
                      selector.matchLabels = scope.selectorLabels;
                      template = {
                        metadata.labels = scope.selectorLabels;
                        spec.containers = [
                          (
                            {
                              name = "app";
                              image = "example/app:1";
                              env = [
                                {
                                  name = "REPLICAS";
                                  value = self.svc.out.replicas;
                                }
                              ];
                            }
                            // containerBase
                          )
                        ];
                      };
                    };
                  };
                };
            };
          }
        ];
        ms = manifests cluster;
        dep = byName "app" (ofKind "Deployment" ms);
        svcHash = builtins.unsafeDiscardStringContext cluster.instances.appns.app.raw.svc.out.identityHash;
        env = builtins.head (builtins.head dep.spec.template.spec.containers).env;
        cnp = byName "app-deployment-app-egress" (ofKind "CiliumNetworkPolicy" ms);
        egress =
          if cnp == null then
            [ ]
          else
            builtins.filter (r: (r.stubRule or "") == "service-egress") (cnp.spec.egress or [ ]);
      in
      (dep != null && env.value == "2" && lib.hasInfix svcHash (dependsOn dep) && egress == [ ])
      || throw "structural output wrong: env ${builtins.toJSON env}, depends-on ${dependsOn dep}, egress ${builtins.toJSON egress}";

    # The probe Job passes the stock security rules at error severity.
    t66-healthcheck-passes-security-rules =
      let
        cluster = mkCluster [
          {
            scorecard = {
              enable = true;
              rules.security = import ../rules/security.nix { inherit lib; };
            };
            instances.appns.app.package = mkProbedPackage { };
          }
        ];
        findings = builtins.filter (f: lib.hasInfix "app-health" (toString (f.resource or ""))) (
          (cluster.scorecardReport or { findings = [ ]; }).findings
        );
      in
      builtins.seq (manifests cluster) (
        findings == [ ] || throw "security findings on the probe Job: ${builtins.toJSON findings}"
      );

    # kix.image.ref renders the digest when there is one and omits it when
    # there is not, so an unresolved pin stays deployable and an unresolved
    # reference is visibly different from a resolved one.
    t70-image-ref-renders-digest =
      let
        pinned = kixlib.image.ref {
          repository = "reg.example/app";
          tag = "v1";
          digest = "sha256:${lib.concatStrings (lib.genList (_: "ab") 32)}";
        };
        loose = kixlib.image.ref {
          repository = "reg.example/app";
          tag = "v1";
        };
      in
      (
        pinned == "reg.example/app:v1@sha256:${lib.concatStrings (lib.genList (_: "ab") 32)}"
        && loose == "reg.example/app:v1"
        && kixlib.image.isPinned {
          repository = "r";
          tag = "t";
          digest = "d";
        }
        && !(kixlib.image.isPinned {
          repository = "r";
          tag = "t";
        })
      )
      || throw "image.ref wrong: pinned=${pinned} loose=${loose}";

    # kix.pins refuses a malformed pin at evaluation, and its refusals name a
    # command the reader can run. A missing key is the case that matters: it
    # is what a fresh checkout hits.
    t71-pins-refuse-with-a-remedy =
      let
        pins = kixlib.pins {
          web = {
            repository = "reg.example/web";
            tag = "v1";
          };
          noTag.repository = "reg.example/x";
          badDigest = {
            repository = "reg.example/x";
            tag = "v1";
            digest = "sha256:nothex";
          };
          unknownField = {
            repository = "reg.example/x";
            tag = "v1";
            colour = "blue";
          };
        };
        msgOf = expr: (builtins.tryEval expr).success;
        missingMsg = builtins.tryEval (pins.get "absent");
      in
      (
        pins.ref "web" == "reg.example/web:v1"
        && !(msgOf (builtins.deepSeq (pins.get "absent") null))
        && !(msgOf (builtins.deepSeq (pins.get "noTag") null))
        && !(msgOf (builtins.deepSeq (pins.get "badDigest") null))
        && !(msgOf (builtins.deepSeq (pins.get "unknownField") null))
        && !missingMsg.success
      )
      || throw "pins accepted something it should have refused";

    # The placeholder ratchet fires on the spellings that have actually
    # shipped, and stays quiet on an ordinary sha tag. `sha-REPLACE_ME` is the
    # case this exists for: it passes noLatestTag and every other check.
    t72-placeholder-ratchet =
      let
        rule = (import ../rules/security.nix { inherit lib; }).noUnresolvedPlaceholder;
        judge =
          img:
          rule.check {
            resource = {
              kind = "Deployment";
              spec.template.spec.containers = [
                {
                  name = "c";
                  image = img;
                }
              ];
            };
          };
        caught = [
          "reg/app:sha-REPLACE_ME"
          "reg/app:CHANGEME"
          "reg/app:v1-PLACEHOLDER"
          "reg/app:\${IMAGE_TAG}"
        ];
        clean = [
          "reg/app:sha-0e8423e"
          "reg/app:v1.2.3"
          "reg/app:v1@sha256:${lib.concatStrings (lib.genList (_: "ab") 32)}"
        ];
      in
      (
        builtins.all (i: judge i != [ ]) caught
        && builtins.all (i: judge i == [ ]) clean
        # It only applies to workloads, like every other manifest rule here.
        && !(rule.appliesTo { resource.kind = "ConfigMap"; })
      )
      || throw "placeholder ratchet misjudged: caught=${builtins.toJSON (map judge caught)} clean=${builtins.toJSON (map judge clean)}";

    # ---------------------------------------------------------------
    # The public export surface (kix/lib/default.nix)
    #
    # These go through `publicKix` rather than the subtree imports the rest
    # of the matrix uses, because the bug they cover was an export never
    # made, not an implementation that was wrong.

    t73-public-export-has-mergefragments =
      publicKix ? mergeFragments
      || throw (
        "kix.mergeFragments is documented (HANDBOOK, FEATURE-CATALOG) but not exported; "
        + "public surface is: "
        + builtins.concatStringsSep ", " (builtins.attrNames publicKix)
      );

    # Two fragments contributing to one namespace merge key by key, at any
    # depth, rather than one winning wholesale.
    t74-mergefragments-merges-namespaces-recursively =
      let
        merged = publicKix.mergeFragments {
          fragments = [
            { namespaces.apps.labels.tier = "web"; }
            { namespaces.apps.labels.owner = "platform"; }
            { namespaces.other.labels.tier = "batch"; }
          ];
        };
      in
      merged.namespaces == {
        apps.labels = {
          tier = "web";
          owner = "platform";
        };
        other.labels.tier = "batch";
      }
      || throw "namespaces did not deep-merge: ${builtins.toJSON merged.namespaces}";

    # `namespacePolicies` lands over the merged fragments, which is how a
    # platform owner keeps the last word.
    t75-mergefragments-applies-namespace-policies =
      let
        merged = publicKix.mergeFragments {
          fragments = [ { namespaces.apps.labels.tier = "web"; } ];
          namespacePolicies.apps.labels.managed = "platform";
        };
      in
      merged.namespaces.apps.labels == {
        tier = "web";
        managed = "platform";
      }
      || throw "policies did not apply: ${builtins.toJSON merged.namespaces}";

    # The same (namespace, instance) from two fragments is a composition
    # mistake. Picking one silently would be the worst outcome.
    t76-mergefragments-refuses-instance-collision =
      let
        merged = publicKix.mergeFragments {
          fragments = [
            { instances.apps.web.package = dnsPackage; }
            { instances.apps.web.package = dnsPackage; }
          ];
        };
      in
      !(builtins.tryEval (builtins.deepSeq (merged.instances { }) true)).success
      || throw "two fragments defined apps.web and the collision was not caught";

    # Two fragments setting one namespace leaf to different values is the
    # policy conflict the deep merge exists to catch.
    t77-mergefragments-refuses-namespace-leaf-conflict =
      let
        merged = publicKix.mergeFragments {
          fragments = [
            { namespaces.apps.labels.tier = "web"; }
            { namespaces.apps.labels.tier = "batch"; }
          ];
        };
      in
      !(builtins.tryEval (builtins.deepSeq merged.namespaces true)).success
      || throw "conflicting values for apps.labels.tier were merged instead of refused";

    # The point of the whole thing: a composition goes straight into a
    # cluster through the public API and evaluates. `instances` is a
    # function so a fragment can take `ref`; calling it with `{ }` is the
    # shape the handbook documents.
    t78-mergefragments-composes-a-buildable-cluster =
      let
        composition = publicKix.mergeFragments {
          fragments = [
            {
              namespaces.fragns.labels.tier = "web";
              instances.fragns.dns.package = dnsPackage;
            }
          ];
        };
        cluster = publicKix.buildCluster {
          name = "fragment-composition";
          modules = [
            {
              namespaces = composition.namespaces;
              instances = composition.instances { };
            }
          ];
        };
        ms = manifests cluster;
      in
      hasName "dns" ms
      || throw "composed cluster produced no dns resource; got: ${builtins.toJSON (namesOf ms)}";
    # mkEnv, through the public export
    #
    # `mkEnv` output only meets the instance submodule inside
    # `buildCluster`, so these build clusters rather than inspecting the
    # attrset. Inspecting the attrset is exactly what would have missed
    # `_envScope`.

    # The bug: every generated instance carried `_envScope`, which the
    # instance submodule does not declare, so assigning a `mkEnv` result to
    # `instances` failed with "The option ... does not exist".
    t79-mkenv-output-is-assignable-to-instances =
      let
        application =
          { env, ... }:
          {
            web = {
              package = envProbePackage;
              config.message = "hello from ${env.name}";
            };
          };
        cluster = publicKix.buildCluster {
          name = "mkenv-two-envs";
          modules = [
            {
              instances =
                publicKix.mkEnv "development" { } { app = application; }
                // publicKix.mkEnv "production" { } { app = application; };
            }
          ];
        };
        ms = manifests cluster;
        nsOf = name: (byName name (ofKind "Namespace" ms)) != null;
        msg =
          ns:
          (lib.findFirst (m: (m.kind or "") == "ConfigMap" && (m.metadata.namespace or "") == ns) null ms)
          .data.message or null;
      in
      (
        nsOf "development-app"
        && nsOf "production-app"
        # The same instance-set function, evaluated once per environment,
        # so `env.name` must differ between the two.
        && msg "development-app" == "hello from development"
        && msg "production-app" == "hello from production"
      )
      || throw "mkEnv did not produce two independent environments: ${builtins.toJSON (namesOf ms)}";

    # `overrides.<set>.<instance>.config` merges into the generated config
    # rather than replacing the instance.
    t80-mkenv-per-instance-overrides-merge =
      let
        application =
          { env, ... }:
          {
            web = {
              package = envProbePackage;
              config = {
                message = "from ${env.name}";
                keep = "me";
              };
            };
          };
        cluster = publicKix.buildCluster {
          name = "mkenv-overrides";
          modules = [
            {
              instances = publicKix.mkEnv "production" {
                overrides.app.web.config.message = "overridden";
              } { app = application; };
            }
          ];
        };
        cm = byName "probe" (ofKind "ConfigMap" (manifests cluster));
      in
      # `message` overridden, `keep` surviving from the generated config:
      # the override merges into it rather than replacing it.
      (cm.data.message == "overridden" && cm.data.keep == "me")
      || throw "override did not merge over the generated config: ${builtins.toJSON cm.data}";

    # A plain auto-instantiated dependency resolves into the *requesting*
    # namespace, which under mkEnv is the environment. The namespace is the
    # isolation; there is no second scoping mechanism, and this is what
    # `_envScope` would have been for had it ever been read.
    t81-mkenv-isolates-plain-auto-instantiated-packages =
      let
        application =
          { ... }:
          {
            consumer.package = envSidecarConsumer;
          };
        cluster = publicKix.buildCluster {
          name = "mkenv-auto";
          modules = [
            {
              availablePackages.envSidecar.package = envSidecarPackage;
              instances =
                publicKix.mkEnv "development" { } { app = application; }
                // publicKix.mkEnv "production" { } { app = application; };
            }
          ];
        };
        sidecarNamespaces = builtins.sort (a: b: a < b) (
          map (m: m.metadata.namespace or "-") (
            builtins.filter (m: (m.kind or "") == "ConfigMap" && (m.metadata.name or "") == "env-sidecar") (
              manifests cluster
            )
          )
        );
      in
      sidecarNamespaces == [
        "development-app"
        "production-app"
      ]
      || throw "plain auto dep not scoped per environment: ${builtins.toJSON sidecarNamespaces}";

    # The deliberate exception, pinned so nobody "fixes" it into the rule
    # above. A role-named dep is keyed by the role, never by the requesting
    # namespace, so two environments share one provider on purpose
    # (`eval/auto.nix`: "two consumers in two namespaces share one provider
    # instead of instantiating two strong symbols of the same role").
    t82-mkenv-shares-one-role-provider-across-environments =
      let
        application =
          { ... }:
          {
            consumer.package = optionalScConsumer;
          };
        cluster = publicKix.buildCluster {
          name = "mkenv-role";
          modules = [
            {
              availablePackages.stock-storage.package = stockStorage;
              instances =
                publicKix.mkEnv "development" { } { app = application; }
                // publicKix.mkEnv "production" { } { app = application; };
            }
          ];
        };
        stock = builtins.filter (
          m: (m.kind or "") == "ConfigMap" && (m.metadata.name or "") == "stock-sc"
        ) (manifests cluster);
      in
      builtins.length stock == 1
      || throw "expected one shared role provider, got ${toString (builtins.length stock)}";

    # ── envoy-gateway: data-plane parameters ───────────────────────────
    # Real clusters keep Envoy Gateway's defaults, so an instance that
    # says nothing about the proxy must emit no EnvoyProxy and hang no
    # parametersRef off the class.
    t83-envoy-gateway-default-emits-no-proxy =
      let
        ms = manifests (mkGatewayCluster { });
        gc = byName "gateway" (ofKind "GatewayClass" ms);
      in
      (ofKind "EnvoyProxy" ms == [ ] && gc != null && !(gc.spec ? parametersRef))
      || throw "default envoy-gateway instance leaked proxy parameters: ${
        builtins.toJSON (gc.spec or null)
      }";

    # Opting in emits the EnvoyProxy verbatim and points the class at it
    # by group/kind/name/namespace — the four fields Envoy Gateway's
    # processGatewayClassParamsRef resolves.
    t84-envoy-gateway-proxyspec-wires-parametersref =
      let
        ms = manifests (mkGatewayCluster {
          proxySpec = kindProxySpec;
        });
        ep = byName "gateway-proxy" (ofKind "EnvoyProxy" ms);
        gc = byName "gateway" (ofKind "GatewayClass" ms);
      in
      (
        ep != null
        && ep.apiVersion == "gateway.envoyproxy.io/v1alpha1"
        && ep.metadata.namespace == "gwns"
        && ep.spec == kindProxySpec
        &&
          gc.spec.parametersRef == {
            group = "gateway.envoyproxy.io";
            kind = "EnvoyProxy";
            name = "gateway-proxy";
            namespace = "gwns";
          }
      )
      || throw "unexpected EnvoyProxy wiring: proxy=${builtins.toJSON ep} class=${builtins.toJSON gc}";

    # The parametersRef is resolved by name at admission time, so the
    # EnvoyProxy has to land first. Referencing it through out.name is
    # what buys that edge; this asserts the edge exists rather than
    # trusting the reference style.
    t85-envoy-gateway-proxy-orders-before-class =
      let
        cluster = mkGatewayCluster { proxySpec = kindProxySpec; };
        ms = manifests cluster;
        raw = cluster.instances.gwns.gateway.raw;
        proxyHash = k8s.extractStoreHash raw.envoyProxy.outPath;
        classHash = k8s.extractStoreHash raw.gatewayClass.outPath;
        gc = byName "gateway" (ofKind "GatewayClass" ms);
        gw = byName "gateway" (ofKind "Gateway" ms);
      in
      (lib.hasInfix proxyHash (dependsOn gc) && lib.hasInfix classHash (dependsOn gw))
      || throw "ordering edges missing: class depends-on '${dependsOn gc}', gateway depends-on '${dependsOn gw}'";

    # EnvoyProxy is an Envoy Gateway extension. Pointing a class at
    # another implementation's controller and still handing it a
    # proxySpec is a silent no-op in the cluster, so it fails eval.
    t86-envoy-gateway-proxyspec-needs-envoy-controller = evalFails (mkGatewayCluster {
      controllerName = "gateway.nginx.org/nginx-gateway-controller";
      proxySpec = kindProxySpec;
    });
  }
  // import ./validate.nix {
    inherit
      lib
      k8s
      mkCluster
      baseInstances
      manifests
      evalFails
      ;
    validate = import ../eval/validate.nix { inherit lib; };
  };

  failures = lib.filterAttrs (
    _: v: (builtins.tryEval (builtins.deepSeq v v)).value or false != true
  ) tests;
in
{
  inherit tests;
  # Internal poke-hole for diagnosing test failures interactively.
  _debug = {
    inherit
      mkCluster
      baseInstances
      netpolOn
      k8s
      probePackage
      stubEnforcer
      mkProbedPackage
      partHash
      manifests
      ;
  };
  result =
    if failures == { } then
      {
        ok = true;
        passed = builtins.attrNames tests;
      }
    else
      throw (
        "kix/lib tests FAILED: "
        + builtins.concatStringsSep ", " (builtins.attrNames failures)
        + " — re-run a single test for its detailed message, e.g. "
        + "nix eval --impure --expr '(import ./kix/lib/tests { }).tests.<name>'"
      );
}

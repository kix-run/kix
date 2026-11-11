# Evaluation-only regression matrix for kix/lib.
#
# homelab-kind is the golden *build* check, but it pins one topology (netpol
# enabled, cilium enforcer present, no sentinel instances, no hostNetwork
# apps). This matrix evaluates tiny synthetic clusters across the
# configurations homelab-kind does NOT exercise: netpol off, missing enforcer,
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
#
# Each file in ./units is loaded into the same matrix. Add tests for a new
# feature there as `units/<topic>.nix`, with test names `<topic>-<what>`.

{
  # Default: the exact nixpkgs the clusters flake pins (read from its lock
  # file, fetched by narHash: pure, no registry/channel needed).
  lib ? (
    let
      lock = builtins.fromJSON (builtins.readFile ../../../clusters/flake.lock);
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
  # `self` is this repository, so image sources name files by their path
  # in it, as for a cluster in a consuming flake.
  eval = import ../eval {
    inherit lib k8s;
    self = ../../..;
  };
  kixlib = import ../vocab { inherit lib; };

  # The *public* surface, as a consuming flake sees it through `mkFlake`.
  # The rest of this matrix imports subtrees directly, which is how
  # `mergeFragments` managed to be implemented, documented and unreachable
  # all at once: no test ever looked at what `kix/lib/default.nix` exports.
  # `pkgs` is forced only by the manifest-writing attributes, so a stub
  # keeps this eval-only like the rest of the file.
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
  # (collectResources excludes the `root` key). See the latent-quirk note
  # in architecture.md.
  dnsPackage = {
    meta = {
      version = "test";
      # Every namespace resolves the implicit `dns` dependency to it.
      scope = "cluster";
    };
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
    meta = {
      version = "test";
      # baseInstances consumes it from another namespace by name, so the
      # cross-namespace edge tests need no `ref` module.
      scope = "cluster";
    };
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

  # v2_discussions/143/145 fixtures: a dep-free multi-replica Deployment, with
  # optional pod-spec extras (explicit placement rules) and an optional
  # author-written PDB over the same selector.
  mkReplicatedPackage =
    {
      replicas ? 3,
      templateExtra ? { },
      withPdb ? false,
      metaExtra ? { },
      helm ? false,
    }:
    {
      meta = {
        version = "test";
      }
      // metaExtra;
      build =
        { self, scope, ... }:
        let
          body = {
            name = "web";
            spec = {
              inherit replicas;
              selector.matchLabels = scope.selectorLabels;
              template = {
                metadata.labels = scope.selectorLabels;
                spec = {
                  containers = [
                    (
                      {
                        name = "web";
                        image = "example/web:1";
                      }
                      // containerBase
                    )
                  ];
                }
                // templateExtra;
              };
            };
          };
        in
        {
          root = self.deployment;
          deployment =
            if helm then
              scope.mkHelmWorkload (
                body
                // {
                  apiVersion = "apps/v1";
                  kind = "Deployment";
                }
              )
            else
              scope.mkDeployment body;
        }
        // lib.optionalAttrs withPdb {
          pdb = scope.mkResource {
            apiVersion = "policy/v1";
            kind = "PodDisruptionBudget";
            name = "web-pdb";
            spec = {
              minAvailable = 2;
              selector.matchLabels = scope.selectorLabels;
            };
          };
        };
    };

  multiZone = {
    cluster.capabilities.multiNode = true;
    cluster.capabilities.availabilityZones = [
      "a"
      "b"
      "c"
    ];
  };

  singleNode = {
    cluster.capabilities.multiNode = false;
  };

  hardHostnameAntiAffinity = {
    affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution = [
      {
        labelSelector.matchLabels.app = "web";
        topologyKey = "kubernetes.io/hostname";
      }
    ];
  };

  # The derived constraints of the fixture's Deployment, or [ ] when none.
  # A package that takes the level as an argument and maps it, the way
  # every replica-shaped option is expected to (145 §5). Also emits the
  # level it saw into a ConfigMap so a test can read it.
  mkLevelPackage =
    {
      metaExtra ? { },
      table ? {
        none = 1;
        pod = 2;
        node = 2;
        zone = 3;
      },
    }:
    {
      scope,
      lib,
      kix,
      availability,
      ...
    }:
    {
      meta = {
        version = "test";
      }
      // metaExtra;
      options.replicas = lib.mkOption {
        type = lib.types.ints.positive;
        default = kix.availability.pick availability table;
      };
      build =
        {
          self,
          scope,
          config,
          availability,
          ...
        }:
        {
          root = self.deployment;
          deployment = scope.mkDeployment {
            name = "web";
            spec = {
              replicas = config.replicas;
              selector.matchLabels = scope.selectorLabels;
              template = {
                metadata.labels = scope.selectorLabels;
                spec.containers = [
                  (
                    {
                      name = "web";
                      image = "example/web:1";
                    }
                    // containerBase
                  )
                ];
              };
            };
          };
          seen = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "level";
            data.level = availability;
          };
        };
    };

  # The level an instance named `capped` in namespace `appns` saw, or, when
  # no such instance is given, the level a fresh one sees under `mods`.
  levelSeenBy =
    mods:
    let
      hasCapped = builtins.any (
        m: builtins.isAttrs m && (((m.instances or { }).appns or { }).capped or { }) ? package
      ) mods;
      cluster = mkCluster (
        mods ++ lib.optional (!hasCapped) { instances.appns.capped.package = mkLevelPackage { }; }
      );
    in
    (byName "level" (ofKind "ConfigMap" (manifests cluster))).data.level;

  spreadOf =
    cluster:
    let
      web = byName "web" (ofKind "Deployment" (manifests cluster));
    in
    web.spec.template.spec.topologySpreadConstraints or [ ];

  spreadKeys = cs: map (c: "${c.topologyKey}=${c.whenUnsatisfiable}") cs;

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
  # carrier's seal; indirection is the default case, not a special one
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
  # builder chain: mkCRDRef → out.crds → consumer's scope.mkCR).
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
        # Like a real operator, one instance serves every namespace.
        scope = "cluster";
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
            version = "v1";
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

  # same consumer but builder-less: raw mkResource with a kind string;
  # no behavior arrives unless cluster.factBehavior supplies it. Its own
  # CRD ref, without factBehavior, gives the CR the declaration the cluster
  # build requires (check 21).
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
        testClusterCrd = scope.mkCRDRef {
          group = "test.io";
          kind = "TestCluster";
          plural = "testclusters";
          version = "v1";
        };
        cluster = scope.mkResource {
          apiVersion = "test.io/v1";
          kind = "TestCluster";
          name = "mycluster";
          spec.connection = db.out.fqdn;
          requires = [ self.testClusterCrd ];
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
  # seals a CNP-shaped resource through whatever mkResource it is handed,
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
          holdsData = false;
        };

        rule = kind: extra: { stubRule = kind; } // extra;

        netpolApi = {
          policyKinds = [ "CiliumNetworkPolicy" ];
          mkPolicy = { mkResource, extraArgs }: mkResource (crdRef.out.cr extraArgs);
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
          mkHostNetworkEgressRule = { ports }: rule "host-network-egress" { inherit ports; };
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
          # Echo each intent rule, so a test can assert its target and ports.
          translateIntentRules =
            { intents }:
            let
              all = builtins.attrValues intents;
            in
            {
              egressRules = builtins.concatMap (i: map (r: rule "intent-egress" r) (i.egress or [ ])) all;
              ingressRules = builtins.concatMap (i: map (r: rule "intent-ingress" r) (i.ingress or [ ])) all;
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
              requires = [ crdRef ];
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

  # An import of a StorageClass the environment provides, as an instance
  # value. It is not optional, so its marker is in every build, and claims
  # that name the class resolve (check 20).
  storageClassImport = name: {
    package = eval.mkImport {
      kind = "StorageClass";
      apiVersion = "storage.k8s.io/v1";
      out = {
        inherit name;
        storageClassName = name;
      };
    };
  };

  # A prometheus provider whose builders render their arguments as
  # prometheus-operator custom resources. Each kind comes from a
  # scope.mkCRDRef part, so a resource built through the stub depends on a
  # declaration of its kind, as one built through the real package does.
  prometheusStub = {
    meta = {
      version = "test";
      defaultAliases = [ "prometheus" ];
      # Like prometheus-operator, one instance serves every namespace.
      scope = "cluster";
    };
    build =
      { self, scope, ... }:
      let
        ref =
          kind: plural:
          scope.mkCRDRef {
            group = "monitoring.coreos.com";
            inherit kind plural;
            version = "v1";
            holdsData = false;
          };
        as =
          crd: consumerScope: args:
          crd.out.mkCR consumerScope args;
      in
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "prometheus";
        };
        serviceMonitorCrd = ref "ServiceMonitor" "servicemonitors";
        podMonitorCrd = ref "PodMonitor" "podmonitors";
        prometheusRuleCrd = ref "PrometheusRule" "prometheusrules";
        root = {
          resource = self.cm;
          out = {
            mkServiceMonitor = as self.serviceMonitorCrd;
            mkPodMonitor = as self.podMonitorCrd;
            mkPrometheusRule = as self.prometheusRuleCrd;
          };
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
  # `operator` dep; dep args are discovered from literal functionArgs, so
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

  # A Deployment built with raw scope.mkResource, the shape every package
  # carried before the seal became the only way to build a workload.
  mkRawDeploymentPackage = {
    meta = {
      version = "test";
    };
    build =
      { self, scope, ... }:
      {
        deployment = scope.mkResource {
          apiVersion = "apps/v1";
          kind = "Deployment";
          name = "raw";
          spec = {
            replicas = 1;
            selector.matchLabels = {
              app = "raw";
            };
            template = {
              metadata.labels = {
                app = "raw";
              };
              spec.containers = [
                {
                  name = "c";
                  image = "img";
                }
              ];
            };
          };
        };
        root = self.deployment;
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

  # Stock-catalog fixtures: a role-claiming shelf package and two consumers
  # that write the class they resolved into ConfigMap `sc-consumer`, one
  # with an OPTIONAL storageClasses dep (like persistent-volume-claim) and
  # one with a REQUIRED one.
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

  requiredScConsumer = {
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

  # Contested-alias fixtures: shelf packages answering `x`, and a consumer
  # requiring `x` that records which one it got.
  shelfX =
    who:
    mkCmPackage {
      name = "shelf-${who}";
      metaExtra.defaultAliases = [ "x" ];
      out = { inherit who; };
    };

  xConsumer = {
    meta.version = "test";
    build =
      {
        self,
        scope,
        x,
        ...
      }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "x-consumer";
          extra.data.who = x.out.who;
        };
        root = self.cm;
      };
  };

  whoOf = ms: (byName "x-consumer" ms).data.who or "missing";

  # A package with no alias that requires `z` and reports it as `who`.
  zRequirer = {
    meta.version = "test";
    build =
      {
        self,
        scope,
        z,
        ...
      }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "z-requirer";
        };
        root = {
          resource = self.cm;
          out.who = "via-${z.out.who}";
        };
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

  # The rules of the `<instance>-alerts` resource of `kind` (PrometheusRule
  # or VMRule) in `ms`, keyed by alert name, or null when none rendered.
  alertRulesOf =
    kind: instance: ms:
    let
      rule = byName "${instance}-alerts" (ofKind kind ms);
    in
    if rule == null then
      null
    else
      lib.listToAttrs (
        map (r: lib.nameValuePair r.alert r) (lib.concatMap (g: g.rules) rule.spec.groups)
      );

  # Whether every rule in `rules` (from alertRulesOf) selects on `selector`.
  allSelect =
    selector: rules: rules != { } && lib.all (r: lib.hasInfix selector r.expr) (lib.attrValues rules);

  scorecardOn = {
    scorecard = {
      enable = true;
      rules.architecture = import ../rules/architecture.nix { inherit lib; };
    };
  };

  _validScorecardRule = {
    description = "a rule that reports nothing";
    level = "manifest";
    severity = "warning";
    check = _: [ ];
  };

  domainFindings =
    cluster:
    builtins.filter (f: lib.hasSuffix "annotationDomainOwnership" (f.rule or "")) (
      (cluster.scorecardReport or { findings = [ ]; }).findings
    );

  # The real kix/packages/experimental/envoy-gateway, not a synthetic stand-in: its
  # EnvoyProxy/GatewayClass/Gateway wiring is what decides whether a
  # Gateway can program on a cluster with no LoadBalancer, so the tests
  # want the shipped package, field names and all.
  envoyGatewayPackage = import ../../packages/experimental/envoy-gateway;

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

  # Arguments each file under ./units receives. A unit file is a function
  # `{ lib, mkCluster, ... }:` that returns tests named `<unit>-<what>`.
  unitHelpers = {
    inherit
      lib
      k8s
      eval
      kixlib
      publicKix
      kixKeys
      mkCluster
      baseInstances
      netpolOn
      mkCmPackage
      manifests
      ofKind
      namesOf
      hasName
      byName
      evalFails
      alertRulesOf
      allSelect
      prometheusStub
      storageClassImport
      requiredScConsumer
      containerBase
      mkReplicatedPackage
      mkLevelPackage
      levelSeenBy
      singleNode
      multiZone
      ;
  };

  # Merges test sets and throws on a repeated name, which `//` would
  # otherwise resolve by dropping one of the tests.
  mergeTests =
    source: acc: more:
    let
      repeated = builtins.attrNames (builtins.intersectAttrs acc more);
    in
    if repeated == [ ] then
      acc // more
    else
      throw "kix/lib tests: ${source} repeats test names already defined: ${builtins.concatStringsSep ", " repeated}";

  # Every ./units/*.nix, in file-name order.
  unitTestFiles = lib.attrNames (
    lib.filterAttrs (n: type: type == "regular" && lib.hasSuffix ".nix" n) (builtins.readDir ./units)
  );

  tests = lib.foldl' (
    acc: file: mergeTests "units/${file}" acc (import (./units + "/${file}") unitHelpers)
  ) inlineTests unitTestFiles;

  inlineTests = {
    # netpol disabled: no policies of any kind, interceptor pipeline inert.
    t01-netpol-off-no-cnps =
      let
        ms = manifests (mkCluster [ baseInstances ]);
      in
      ofKind "CiliumNetworkPolicy" ms == [ ]
      || throw "expected no CNPs, got: ${builtins.toJSON (namesOf (ofKind "CiliumNetworkPolicy" ms))}";

    # DNS dep injection is core and unconditional: even with netpol
    # disabled, a workload with a cross-instance Service edge must depend
    # on the DNS provider's root resource, not on its PackageInstance.
    t02-netpol-off-dns-dep =
      let
        cluster = mkCluster [ baseInstances ];
        appDeployment = byName "app" (ofKind "Deployment" (manifests cluster));
        dnsHash = k8s.extractStoreHash cluster.instances.dns.dns.raw.root.outPath;
        dnsPiHash = k8s.extractStoreHash cluster.instances.dns.dns.root.outPath;
        dbSvcHash = k8s.extractStoreHash cluster.instances.dbns.db.raw.service.outPath;
        annot = dependsOn appDeployment;
      in
      (lib.hasInfix dnsHash annot && lib.hasInfix dbSvcHash annot && !(lib.hasInfix dnsPiHash annot))
      || throw "app depends-on missing dns/db edge; annotation: ${annot}";

    # An optional DNS import that nothing demands, as most flavours declare
    # platform-dns, emits no marker, so no workload may depend on it.
    t02b-optional-dns-import-adds-no-edge =
      let
        cluster = mkCluster [
          {
            instances.dbns.db = baseInstances.instances.dbns.db;
            instances.appns.app = baseInstances.instances.appns.app;
            instances.kube-system.platform-dns = {
              package = eval.mkImport {
                kind = "Deployment";
                apiVersion = "apps/v1";
                roles = [ "dns" ];
                out.name = "coredns";
              };
              optional = true;
            };
          }
        ];
        ms = manifests cluster;
        markerHash = k8s.extractStoreHash cluster.instances.kube-system.platform-dns.root.outPath;
        annot = dependsOn (byName "app" (ofKind "Deployment" ms));
      in
      (!(lib.hasInfix markerHash annot) && !(hasName "platform-dns" (ofKind "PackageInstance" ms)))
      || throw "app depends on the inactive platform-dns marker; annotation: ${annot}";

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

    # Two managed instances claiming the same role throw eagerly, even
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
    # for consumers taking the role name as a dep arg. No instance-level
    # aliases needed.
    t19-role-is-di-alias =
      let
        storageStub = mkCmPackage {
          name = "storage-stub";
          metaExtra.roles = [ "storageClasses" ];
          out.storageClassName = "stub-sc";
        };
        ms = manifests (mkCluster [
          baseInstances
          {
            instances.storage.provider.package = storageStub;
            instances.appns.consumer.package = requiredScConsumer;
          }
        ]);
        probe = byName "sc-consumer" (ofKind "ConfigMap" ms);
      in
      (probe != null && probe.data.sc == "stub-sc")
      || throw "role-as-alias resolution failed: ${builtins.toJSON probe}";

    # --- stock catalogs (doc 127 §5) ---

    # An optional dependency places no demand, even on a role name: the
    # role provider on the shelf stays there and the dependency is null.
    t20-optional-role-dep-does-not-pull-stock =
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
      (!(hasName "stock-sc" (ofKind "ConfigMap" ms)) && probe != null && probe.data.sc == "missing")
      || throw "optional role dependency pulled stock: ${builtins.toJSON probe}";

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

    # An optional dependency on a role resolves to a platform import that
    # provides it, as the kind flavour's platform-storage import does for
    # homelab-kind, and the shelf provider is not pulled. An optional import
    # that nothing demands stays inactive and answers nothing.
    t22-optional-role-dep-resolves-import =
      let
        sc =
          optional:
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
                  inherit optional;
                };
                instances.appns.consumer.package = optionalScConsumer;
              }
            ]);
          in
          lib.optionalString (hasName "stock-sc" (ofKind "ConfigMap" ms)) "stock+"
          + (byName "sc-consumer" (ofKind "ConfigMap" ms)).data.sc or "no-consumer";
      in
      (sc false == "import-sc" && sc true == "missing")
      || throw "optional role dependency: active import ${sc false}, inactive import ${sc true}";

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

    # The OpenAPI schema does not constrain metadata.name, so check the API
    # server's naming rules during evaluation.
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

    # Reject unknown scorecard levels and severities before evaluating rules.
    t27e-scorecard-valid-rule-passes =
      let
        c = mkCluster [
          baseInstances
          {
            scorecard = {
              enable = true;
              rules.cat.r = _validScorecardRule;
            };
          }
        ];
      in
      builtins.length (manifests c) > 0 || throw "a valid scorecard rule should not break the cluster";

    t27f-scorecard-unknown-level-throws = evalFails (mkCluster [
      baseInstances
      {
        scorecard = {
          enable = true;
          rules.cat.r = _validScorecardRule // {
            level = "resource";
          };
        };
      }
    ]);

    t27g-scorecard-unknown-severity-throws = evalFails (mkCluster [
      baseInstances
      {
        scorecard = {
          enable = true;
          rules.cat.r = _validScorecardRule // {
            severity = "critical";
          };
        };
      }
    ]);

    t27h-scorecard-unknown-override-severity-throws = evalFails (mkCluster [
      baseInstances
      {
        scorecard = {
          enable = true;
          rules.cat.r = _validScorecardRule;
          ruleOverrides.byRule."cat.r".severity = "fatal";
        };
      }
    ]);

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
            # The declarer itself writes under its domain; must not warn.
            instances.infra.operator.package = mkAnnotatedCmPackage {
              key = "example.io/managed";
              name = "operator-cm";
              metaExtra = {
                annotationDomains = [ "example.io" ];
                scope = "cluster";
              };
            };
            # The consumer links the operator via DI; must not warn.
            instances.appns.writer.package = mkAnnotatedCmPackage {
              key = "example.io/managed";
              withOperatorDep = true;
            };
          }
        ];
        findings = domainFindings cluster;
      in
      findings == [ ] || throw "dep/self exemptions failed: ${builtins.toJSON findings}";

    # A domain nobody declares is a dead annotation and warns, unless the
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

    # --- role demand wiring (PR 29 review findings 2-5) ---

    # Role providers are cluster-scoped: demand from two namespaces shares
    # ONE stock instance instead of instantiating two strong providers of
    # the same role (which would be a duplicate-role error).
    t32-role-demand-multi-namespace-shares-stock =
      let
        ms = manifests (mkCluster [
          baseInstances
          {
            availablePackages.stock-storage.package = stockStorage;
            instances.ns1.consumer1.package = requiredScConsumer;
            instances.ns2.consumer2.package = requiredScConsumer;
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
      || throw "multi-namespace role demand not deduped: stock=${toString (builtins.length stockCms)} probes=${
        builtins.toJSON (map (p: p.data.sc) probes)
      }";

    # A never-activated optional instance claiming a role a mandatory
    # instance also provides is NOT a conflict: it emits nothing this
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

    # A typo'd role on a shelf entry throws (same closed vocabulary as
    # instantiated meta.roles) instead of silently never matching. The shelf
    # is read only when something demands from it, so the consumer's
    # storageClasses dependency is required, and stock-storage answers it
    # once the typo'd entry is gone.
    t37-catalog-role-typo-throws =
      let
        shelf = extra: [
          baseInstances
          {
            availablePackages = {
              stock-storage.package = stockStorage;
            }
            // extra;
            instances.appns.consumer.package = requiredScConsumer;
          }
        ];
      in
      (
        builtins.length (manifests (mkCluster (shelf { }))) > 0
        && evalFails (
          mkCluster (shelf {
            bad-storage.package = mkCmPackage {
              name = "bad";
              metaExtra.roles = [ "storageClases" ];
            };
          })
        )
      )
      || throw "a typo'd role on a shelf entry did not throw, or the control cluster failed";

    # Directly wired deps (deps.operator = ref...) count as linking against
    # the declarer. The domain lint must not false-warn on explicit wiring.
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
    # NO edge to db (no caller-ingress CNP), but the identity hit keeps the
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
        dnsHash = k8s.extractStoreHash cluster.instances.dns.dns.raw.root.outPath;
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
    # dialing claim stripped. An fqdn used as a display string derives no edge.
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
    # instance phase: egress in the CR's namespace, caller-ingress into the
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

    # The labels match but no port does: the monitor finds the Service and
    # then drops every endpoint. Harbor shipped this shape and the rule
    # passed it, because the no-match and over-match branches were the only
    # two (2026-09-18).
    t54b-monitor-rule-matched-but-unscraped =
      let
        rule = (import ../rules/architecture.nix { inherit lib; }).monitorSelectorMatchesService;
        service = {
          kind = "Service";
          metadata = {
            name = "cache";
            namespace = "app";
            labels.app = "cache";
          };
          spec.ports = [
            {
              name = "redis";
              port = 6379;
            }
          ];
        };
        monitor = port: {
          kind = "ServiceMonitor";
          metadata = {
            name = "cache";
            namespace = "app";
          };
          spec = {
            selector.matchLabels.app = "cache";
            namespaceSelector.matchNames = [ "app" ];
            endpoints = [ { inherit port; } ];
          };
        };
        run =
          port:
          rule.check {
            allInstances.app = { };
            allResources = [
              service
              (monitor port)
            ];
          };
        good = run "redis";
        bad = run "http-metrics";
        mentionsPort = builtins.any (
          f: builtins.match ".*none of its ports match.*http-metrics.*" f.message != null
        ) bad;
      in
      (good == [ ] && builtins.length bad == 1 && mentionsPort)
      || throw "monitor rule matched-but-unscraped: good=${builtins.toJSON good} bad=${builtins.toJSON bad}";

    # fromWorkload writes container port numbers as targetPort. The netpol
    # layer copies targetPort into every consumer's egress rule and cilium
    # drops egress on a named port (seen live on 1.19, 2026-09-19), so a
    # name the author passes is checked against the workload and replaced
    # by its number; extracted ports never carry a name as targetPort.
    t88-from-workload-numeric-target-ports =
      let
        workload = {
          out.selector.app = "web";
          rawManifest.spec.template.spec.containers = [
            {
              name = "web";
              ports = [
                {
                  name = "http";
                  containerPort = 8080;
                }
                {
                  name = "metrics";
                  containerPort = 8001;
                }
              ];
            }
          ];
        };
        named =
          (kixlib.service.fromWorkload {
            name = "web";
            ports = [
              {
                name = "http-web";
                port = 80;
                targetPort = "http";
              }
              {
                name = "http-metrics";
                port = 8001;
                targetPort = "metrics";
              }
            ];
          } workload).spec.ports;
        extracted = (kixlib.service.fromWorkload { name = "web"; } workload).spec.ports;
        targets = map (p: p.targetPort or null) named;
      in
      (
        targets == [
          8080
          8001
        ]
        && builtins.all (p: !(p ? targetPort)) extracted
      )
      || throw "fromWorkload targetPorts: named=${builtins.toJSON targets} extracted=${builtins.toJSON extracted}";

    # BEST-PRACTICES §7.3 offers `workload.rawSelector` as the escape from a
    # Service/workload cycle, and the cycle it escapes from usually runs
    # through the manifest: the pod mounts a ConfigMap that names the
    # Service, so sealing the workload walks to the Service, which is
    # waiting for this selector. The escape therefore has to be readable
    # without sealing the workload (housekeeping 2026-09-18). A regression
    # here is an infinite recursion, which aborts the whole matrix rather
    # than failing this one test.
    t89-raw-selector-readable-through-a-manifest-cycle =
      let
        pkg = {
          build =
            { self, scope, ... }:
            {
              svc = scope.mkResource {
                apiVersion = "v1";
                kind = "Service";
                name = "cycle-web";
                spec = {
                  selector = self.deployment.rawSelector;
                  ports = [
                    {
                      port = 80;
                      targetPort = 80;
                    }
                  ];
                };
              };
              cm = scope.mkResource {
                apiVersion = "v1";
                kind = "ConfigMap";
                name = "cycle-web-config";
                data.upstream = "http://${self.svc.out.fqdn}/";
              };
              deployment = scope.mkDeployment {
                name = "cycle-web";
                spec = {
                  replicas = 1;
                  selector.matchLabels.app = "cycle-web";
                  template.spec = {
                    volumes = [
                      {
                        name = "config";
                        configMap.name = self.cm.out.name;
                      }
                    ];
                    containers = [
                      {
                        name = "web";
                        image = "web:1";
                        ports = [
                          {
                            name = "http";
                            containerPort = 80;
                          }
                        ];
                        volumeMounts = [
                          {
                            name = "config";
                            mountPath = "/etc/web";
                          }
                        ];
                      }
                    ];
                  };
                };
              };
              # Root is the workload: the Service is reached through the
              # ConfigMap the pod mounts, and that is the edge closing the
              # cycle. Nothing points back the other way, which is what
              # `rawSelector` is for.
              root = self.deployment;
            };
        };
        ms = manifests (mkCluster [
          baseInstances
          netpolOn
          { instances.appns.cycle.package = pkg; }
        ]);
        svc = byName "cycle-web" (ofKind "Service" ms);
      in
      (svc.spec.selector.app or null) == "cycle-web"
      || throw "rawSelector through a manifest cycle: ${builtins.toJSON (svc.spec.selector or null)}";

    # An Ingress routes but opens nothing, and under default deny the
    # backend refuses the controller like any other pod in any other
    # namespace: every request through it times out, and no amount of
    # evaluation sees it (housekeeping 2026-09-18). `kix.expose` holds
    # both ends of that edge, so it writes the rule, on the pod port the
    # Service routes to.
    t90-expose-opens-the-ingress-controller-edge =
      let
        stubController = {
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
                out = {
                  ingressClassName = self.class.out.name;
                  podSelector."app.kubernetes.io/name" = "ingress-nginx";
                  podNamespace = "ingressns";
                };
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
        ms = manifests (mkCluster [
          netpolOn
          {
            cluster.domain = "test.local";
            instances.ingressns.ingress-nginx.package = stubController;
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
        ]);
        cnps = ofKind "CiliumNetworkPolicy" ms;
        edge = byName "web-from-ingress-controller" cnps;
      in
      (
        edge != null
        && edge.metadata.namespace == "appns"
        && (edge.spec.endpointSelector.matchLabels."app.kubernetes.io/name" or null) == "web"
        && (builtins.head edge.spec.ingress).stubRule == "caller-ingress"
        && (builtins.head edge.spec.ingress).callerNamespace == "ingressns"
        && (
          let
            port = builtins.head (builtins.head edge.spec.ingress).ports;
          in
          (port.targetPort or port.port) == 8080
        )
      )
      || throw "no ingress-controller edge; CNPs: ${builtins.toJSON (namesOf cnps)}";

    # A ServiceRef's out.fqdn has the same form as a rendered Service's:
    # `<name>.<ns>.svc.<clusterDomain>`. It used to stop at `.svc`, which
    # only resolves through the pod's DNS search path.
    # The declarer two hops away satisfies the lint. cert-manager declares
    # cert-manager.io, the cluster-issuer depends on cert-manager, and the
    # Ingress that carries the annotation depends on the cluster-issuer:
    # the rule follows the chain rather than the first edge only.
    t91-annotation-domain-transitive-dep-satisfies =
      let
        # Depends on `operator` and writes nothing under the domain. Serves
        # the whole cluster, as an issuer does, so `writer` finds it by name.
        intermediary = {
          meta = {
            version = "test";
            scope = "cluster";
          };
          build =
            {
              self,
              scope,
              operator,
              ...
            }:
            {
              cm = scope.mkResource {
                apiVersion = "v1";
                kind = "ConfigMap";
                name = "issuer-cm";
              };
              root = self.cm;
            };
        };
        # Depends on `issuer` only, and writes under the operator's domain.
        writer = {
          meta.version = "test";
          build =
            {
              self,
              scope,
              issuer,
              ...
            }:
            {
              cm = scope.mkResource {
                apiVersion = "v1";
                kind = "ConfigMap";
                name = "writer-cm";
                annotations."example.io/managed" = "true";
              };
              root = self.cm;
            };
        };
        cluster = mkCluster [
          baseInstances
          scorecardOn
          {
            instances.infra.operator.package = mkCmPackage {
              name = "operator-cm";
              metaExtra = {
                annotationDomains = [ "example.io" ];
                scope = "cluster";
              };
            };
            instances.mid.issuer.package = intermediary;
            instances.appns.writer.package = writer;
          }
        ];
        findings = domainFindings cluster;
      in
      findings == [ ] || throw "transitive declarer not found: ${builtins.toJSON findings}";

    # A package that needs a Pod Security level gets it on its namespace;
    # a namespace pinned stricter than an instance needs is an eval error;
    # a namespace nobody asks about carries no label.
    t92-pod-security-level-from-package-meta =
      let
        privileged = mkCmPackage {
          name = "priv-cm";
          metaExtra.podSecurity = "privileged";
        };
        ms = manifests (mkCluster [
          baseInstances
          {
            instances.virt.operator.package = privileged;
            instances.virt.other.package = mkCmPackage { name = "other-cm"; };
            instances.plain.app.package = mkCmPackage { name = "plain-cm"; };
            namespaces.pinned.podSecurity = "restricted";
            instances.pinned.app.package = mkCmPackage { name = "pinned-cm"; };
          }
        ]);
        label =
          ns:
          ((byName ns (ofKind "Namespace" ms)).metadata.labels or { })."pod-security.kubernetes.io/enforce"
            or null;
        conflict = evalFails (mkCluster [
          baseInstances
          {
            namespaces.virt.podSecurity = "restricted";
            instances.virt.operator.package = privileged;
          }
        ]);
      in
      (
        label "virt" == "privileged" && label "plain" == null && label "pinned" == "restricted" && conflict
      )
      || throw "pod security: virt=${toString (label "virt")} plain=${toString (label "plain")} pinned=${toString (label "pinned")} conflict=${toString conflict}";

    # Manifest rules see what the compiler derived, not only what the
    # package wrote: a probe rule that fires on PodDisruptionBudgets fires
    # on the one the availability plugin derived for a replicated workload.
    t93-scorecard-scores-derived-resources =
      let
        probe.seesPdb = {
          description = "probe: a derived PodDisruptionBudget reaches manifest rules";
          level = "manifest";
          severity = "info";
          tags = [ "test" ];
          check =
            { resource, ... }:
            if (resource.kind or "") == "PodDisruptionBudget" then
              [ { message = "derived pdb seen"; } ]
            else
              [ ];
        };
        cluster = mkCluster [
          multiZone
          {
            scorecard = {
              enable = true;
              rules.probe = probe;
            };
            instances.appns.web.package = mkReplicatedPackage { };
          }
        ];
        findings = builtins.filter (f: lib.hasSuffix "seesPdb" (f.rule or "")) (
          (cluster.scorecardReport or { findings = [ ]; }).findings
        );
      in
      (builtins.length findings == 1 && (builtins.head findings).instance == "web")
      || throw "derived PDB not scored: ${builtins.toJSON findings}";

    # The scorecard runs by default, and the cap decides whether an
    # error-severity finding fails the build: at the default cap the
    # finding is reported as a warning and the cluster builds; at "error"
    # the same cluster fails.
    t94-scorecard-default-on-capped-at-warning =
      let
        probe.always = {
          description = "probe: fires on every ConfigMap at error";
          level = "manifest";
          severity = "error";
          tags = [ "test" ];
          check =
            { resource, ... }: if (resource.kind or "") == "ConfigMap" then [ { message = "probe"; } ] else [ ];
        };
        withProbe = {
          scorecard.rules.probe = probe;
          instances.appns.web.package = mkCmPackage { name = "web-cm"; };
        };
        capped = mkCluster [
          baseInstances
          withProbe
        ];
        findings = builtins.filter (f: lib.hasSuffix "always" (f.rule or "") && f.instance == "web") (
          (capped.scorecardReport or { findings = [ ]; }).findings
        );
        strictFails = evalFails (mkCluster [
          baseInstances
          withProbe
          { scorecard.maxSeverity = "error"; }
        ]);
      in
      (
        builtins.length findings == 1
        && (builtins.head findings).severity == "warning"
        && (manifests capped) != [ ]
        && strictFails
      )
      || throw "scorecard default: findings=${builtins.toJSON findings} strictFails=${toString strictFails}";

    # ownership.cede lands as the kix.run/cede-fields annotation, in order,
    # comma separated; anything but a list of strings, or any other key
    # under ownership, is refused at eval.
    t95-ownership-cede-is-stamped =
      let
        pkg = {
          meta.version = "test";
          build =
            { self, scope, ... }:
            {
              cm = scope.mkResource {
                apiVersion = "v1";
                kind = "ConfigMap";
                name = "ceded";
                ownership.cede = [
                  "data.owned"
                  "metadata.labels[*].x"
                ];
              };
              root = self.cm;
            };
        };
        ms = manifests (mkCluster [
          baseInstances
          { instances.appns.a.package = pkg; }
        ]);
        cm = byName "ceded" (ofKind "ConfigMap" ms);
        bad =
          cede:
          evalFails (mkCluster [
            baseInstances
            {
              instances.appns.a.package = {
                meta.version = "test";
                build =
                  { self, scope, ... }:
                  {
                    cm = scope.mkResource {
                      apiVersion = "v1";
                      kind = "ConfigMap";
                      name = "bad";
                      ownership = cede;
                    };
                    root = self.cm;
                  };
              };
            }
          ]);
      in
      (
        cm.metadata.annotations.${kixKeys.cedeFields} == "data.owned,metadata.labels[*].x"
        && bad { cede = "data.owned"; }
        && bad { take = [ "x" ]; }
      )
      || throw "cede annotation: ${builtins.toJSON (cm.metadata.annotations or { })}";

    # `paths` on a Gateway API cluster renders one HTTPRoute with a rule per
    # path, each to its own backend, in the Gateway's path vocabulary.
    t96-expose-paths-render-an-httproute =
      let
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
              let
                mkWeb = n: port: {
                  inherit n;
                  deployment = scope.mkDeployment {
                    name = n;
                    spec = {
                      selector.matchLabels = scope.selectorLabels // {
                        part = n;
                      };
                      template = {
                        metadata.labels = scope.selectorLabels // {
                          part = n;
                        };
                        spec.containers = [
                          (
                            {
                              name = n;
                              image = "example/${n}:1";
                              ports = [ (kix.port "http" port) ];
                            }
                            // containerBase
                          )
                        ];
                      };
                    };
                  };
                };
                a = mkWeb "front" 8080;
                b = mkWeb "api" 9090;
              in
              {
                frontDeployment = a.deployment;
                apiDeployment = b.deployment;
                front = a.deployment |> kix.service.fromWorkload { name = "front"; } |> scope.mkResource;
                api = b.deployment |> kix.service.fromWorkload { name = "api"; } |> scope.mkResource;
                root = {
                  resource = self.frontDeployment;
                  requires = [
                    self.apiDeployment
                    self.route
                  ];
                };
              }
            )
            (kixlib.expose {
              paths = [
                {
                  path = "/";
                  service = "front";
                }
                {
                  path = "/api";
                  pathType = "Exact";
                  service = "api";
                }
              ];
            })
          ];
        };
        ms = manifests (mkCluster [
          {
            cluster.domain = "test.local";
            instances.gwns.gateway = {
              package = envoyGatewayPackage;
              config.proxySpec = kindProxySpec;
            };
            instances.appns.web.package = backend;
          }
        ]);
        route = byName "web" (ofKind "HTTPRoute" ms);
        rules = route.spec.rules;
        rule = i: builtins.elemAt rules i;
      in
      (
        route.spec.hostnames == [ "web.test.local" ]
        && builtins.length rules == 2
        &&
          (builtins.head (rule 0).matches).path == {
            type = "PathPrefix";
            value = "/";
          }
        && (builtins.head (rule 0).backendRefs).name == "front"
        && (builtins.head (rule 0).backendRefs).port == 8080
        &&
          (builtins.head (rule 1).matches).path == {
            type = "Exact";
            value = "/api";
          }
        && (builtins.head (rule 1).backendRefs).name == "api"
        && (builtins.head (rule 1).backendRefs).port == 9090
      )
      || throw "multi-path HTTPRoute: ${builtins.toJSON (route.spec or null)}";

    # An untracked reference that names its creator and kind orders the
    # referring resource after the creator and stamps what it expects;
    # the bare string form stamps nothing, as before. Only the bare form
    # is listed by the untrackedReferences audit.
    t97-untracked-ref-with-creator =
      let
        pkg = {
          meta.version = "test";
          build =
            {
              self,
              scope,
              kix,
              ...
            }:
            {
              minter = scope.mkJob {
                name = "minter";
                spec.template = {
                  metadata.labels = scope.selectorLabels // {
                    part = "minter";
                  };
                  spec = {
                    restartPolicy = "Never";
                    containers = [
                      (
                        {
                          name = "mint";
                          image = "example/mint:1";
                        }
                        // containerBase
                      )
                    ];
                  };
                };
              };
              web = scope.mkDeployment {
                name = "web";
                spec = {
                  replicas = 1;
                  selector.matchLabels = scope.selectorLabels;
                  template = {
                    metadata.labels = scope.selectorLabels;
                    spec = {
                      containers = [
                        (
                          {
                            name = "web";
                            image = "example/web:1";
                            volumeMounts = [
                              {
                                name = "cert";
                                mountPath = "/cert";
                              }
                            ];
                          }
                          // containerBase
                        )
                      ];
                      volumes = [
                        {
                          name = "cert";
                          secret.secretName = kix.untrackedRef {
                            kind = "Secret";
                            name = "minted-cert";
                            by = self.minter;
                          };
                        }
                      ];
                      serviceAccountName = kix.untrackedRef "cluster-provided";
                    };
                  };
                };
              };
              root = self.web;
            };
        };
        cluster = mkCluster [
          baseInstances
          scorecardOn
          { instances.appns.a.package = pkg; }
        ];
        web = byName "web" (ofKind "Deployment" (manifests cluster));
        untrackedFindings = builtins.filter (f: lib.hasSuffix "untrackedReferences" (f.rule or "")) (
          (cluster.scorecardReport or { findings = [ ]; }).findings
        );
        minterHash = k8s.extractStoreHash cluster.instances.appns.a.raw.minter.outPath;
        badBy = evalFails (mkCluster [
          baseInstances
          {
            instances.appns.a.package = {
              meta.version = "test";
              build =
                {
                  self,
                  scope,
                  kix,
                  ...
                }:
                {
                  cm = scope.mkResource {
                    apiVersion = "v1";
                    kind = "ConfigMap";
                    name = "c";
                    data.x = kix.untrackedRef {
                      kind = "Secret";
                      name = "s";
                      by = "not-a-resource";
                    };
                  };
                  root = self.cm;
                };
            };
          }
        ]);
      in
      (
        web.metadata.annotations.${kixKeys.expects} == "v1|Secret|minted-cert"
        && lib.hasInfix minterHash (dependsOn web)
        && badBy
        && map (f: f.resource) untrackedFindings == [ "cluster-provided" ]
      )
      || throw "untracked ref with creator: ${
        builtins.toJSON (web.metadata.annotations or { })
      }, audit: ${builtins.toJSON untrackedFindings}";

    # `by = "self"` on a Deployment's own optional Secret stamps no
    # expectation and no dependency, and the audit does not list it. It is
    # rejected with a kind, and in a ConfigMap. `by` rejects a passive
    # built-in kind (ConfigMap) and accepts a custom kind of the same name
    # as a built-in one (a Knative Service).
    t115-untracked-ref-self-created-and-passive-by =
      let
        deployWith =
          secretName:
          {
            self,
            scope,
            ...
          }:
          {
            operator = scope.mkDeployment {
              name = "operator";
              spec = {
                replicas = 1;
                selector.matchLabels = scope.selectorLabels;
                template = {
                  metadata.labels = scope.selectorLabels;
                  spec = {
                    containers = [
                      (
                        {
                          name = "operator";
                          image = "example/operator:1";
                          volumeMounts = [
                            {
                              name = "certs";
                              mountPath = "/certs";
                            }
                          ];
                        }
                        // containerBase
                      )
                    ];
                    volumes = [
                      {
                        name = "certs";
                        secret = {
                          inherit secretName;
                          optional = true;
                        };
                      }
                    ];
                  };
                };
              };
            };
            root = self.operator;
          };
        clusterWith =
          build:
          mkCluster [
            baseInstances
            scorecardOn
            {
              instances.appns.a.package = {
                meta.version = "test";
                inherit build;
              };
            }
          ];
        cluster = clusterWith (
          {
            self,
            scope,
            kix,
            ...
          }@args:
          deployWith (kix.untrackedRef {
            name = "operator-certs";
            by = "self";
          }) args
        );
        operator = byName "operator" (ofKind "Deployment" (manifests cluster));
        bareOperator = byName "operator" (
          ofKind "Deployment" (
            manifests (
              clusterWith (
                {
                  self,
                  scope,
                  kix,
                  ...
                }@args:
                deployWith (kix.untrackedRef "operator-certs") args
              )
            )
          )
        );
        untrackedFindings = builtins.filter (f: lib.hasSuffix "untrackedReferences" (f.rule or "")) (
          (cluster.scorecardReport or { findings = [ ]; }).findings
        );
        selfWithKind = evalFails (
          clusterWith (
            {
              self,
              scope,
              kix,
              ...
            }@args:
            deployWith (kix.untrackedRef {
              kind = "Secret";
              name = "operator-certs";
              by = "self";
            }) args
          )
        );
        cmWith =
          ref:
          { self, scope, ... }:
          {
            cm = scope.mkResource {
              apiVersion = "v1";
              kind = "ConfigMap";
              name = "c";
              data.x = ref self;
            };
            root = self.cm;
          };
        selfInConfigMap = evalFails (
          clusterWith (
            {
              self,
              scope,
              kix,
              ...
            }@args:
            cmWith (
              _:
              kix.untrackedRef {
                name = "s";
                by = "self";
              }
            ) args
          )
        );
        byWith =
          creator:
          evalFails (
            clusterWith (
              {
                self,
                scope,
                kix,
                ...
              }@args:
              let
                built = cmWith (
                  self:
                  kix.untrackedRef {
                    kind = "Secret";
                    name = "s";
                    by = self.creator;
                  }
                ) args;
              in
              built
              // {
                # A Knative Service is a custom resource, so its build needs
                # a declaration of its kind (check 21).
                knativeCrd = scope.mkCRDRef {
                  group = "serving.knative.dev";
                  kind = "Service";
                  plural = "services";
                  version = "v1";
                };
                creator = scope.mkResource (
                  creator
                  // lib.optionalAttrs (creator.apiVersion == "serving.knative.dev/v1") {
                    requires = [ args.self.knativeCrd ];
                  }
                );
              }
            )
          );
        byConfigMap = byWith {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "other";
        };
        byKnativeService = byWith {
          apiVersion = "serving.knative.dev/v1";
          kind = "Service";
          name = "minter";
        };
        byNamespace = byWith {
          apiVersion = "v1";
          kind = "Namespace";
          name = "other";
        };
        byAPIService = byWith {
          apiVersion = "apiregistration.k8s.io/v1";
          kind = "APIService";
          name = "v1.example.io";
        };
      in
      (
        !(operator.metadata.annotations ? ${kixKeys.expects})
        && dependsOn operator == dependsOn bareOperator
        && untrackedFindings == [ ]
        && selfWithKind
        && selfInConfigMap
        && byConfigMap
        && !byKnativeService
        && !byNamespace
        && byAPIService
      )
      || throw "untracked ref by self: ${
        builtins.toJSON {
          annotations = operator.metadata.annotations or { };
          audit = untrackedFindings;
          inherit
            selfWithKind
            selfInConfigMap
            byConfigMap
            byKnativeService
            byNamespace
            byAPIService
            ;
        }
      }";

    # A `by = "self"` reference names its creator only while one resource
    # carries it: a second Deployment mounting the same name puts it in the
    # untrackedReferences audit. A workload that requires the object (a
    # Secret volume without `optional = true`, serviceAccountName) is
    # rejected. An optional secretKeyRef and a plain env value build.
    t125-untracked-ref-self-binds-to-one-carrier =
      let
        deployment =
          scope: name: podSpec:
          scope.mkDeployment {
            inherit name;
            spec = {
              replicas = 1;
              selector.matchLabels.app = name;
              template = {
                metadata.labels.app = name;
                spec = {
                  containers = [
                    (
                      {
                        name = "c";
                        image = "example/${name}:1";
                      }
                      // containerBase
                      // (podSpec.container or { })
                    )
                  ];
                }
                // removeAttrs podSpec [ "container" ];
              };
            };
          };
        certsVolume = ref: optional: {
          volumes = [
            {
              name = "certs";
              secret = {
                secretName = ref;
              }
              // lib.optionalAttrs optional { inherit optional; };
            }
          ];
        };
        clusterWith =
          operator: consumer:
          mkCluster [
            baseInstances
            scorecardOn
            {
              instances.appns.a.package = {
                meta.version = "test";
                build =
                  {
                    self,
                    scope,
                    kix,
                    ...
                  }:
                  let
                    ref = kix.untrackedRef {
                      name = "operator-certs";
                      by = "self";
                    };
                  in
                  {
                    operator = deployment scope "operator" (operator ref);
                    root = self.operator;
                  }
                  // lib.optionalAttrs (consumer != null) {
                    consumer = deployment scope "consumer" (consumer ref);
                  };
              };
            }
          ];
        auditOf =
          cluster:
          map (f: f.resource) (
            builtins.filter (f: lib.hasSuffix "untrackedReferences" (f.rule or "")) (
              (cluster.scorecardReport or { findings = [ ]; }).findings
            )
          );
        builds = cluster: !(evalFails cluster);
        operatorMounts = ref: certsVolume ref true;
        secondCarrier = clusterWith operatorMounts (ref: certsVolume ref true);
        required = evalFails (clusterWith operatorMounts (ref: certsVolume ref false));
        serviceAccount = evalFails (
          clusterWith operatorMounts (ref: {
            serviceAccountName = ref;
          })
        );
        optionalKeyRef = clusterWith operatorMounts (ref: {
          container.env = [
            {
              name = "CERT";
              valueFrom.secretKeyRef = {
                name = ref;
                key = "tls.crt";
                optional = true;
              };
            }
          ];
        });
        envValue = clusterWith (
          ref:
          certsVolume ref true
          // {
            container.env = [
              {
                name = "CERT_SECRET";
                value = ref;
              }
            ];
          }
        ) null;
      in
      (
        builds secondCarrier
        && auditOf secondCarrier == [ "operator-certs" ]
        && required
        && serviceAccount
        && builds optionalKeyRef
        && builds envValue
        && auditOf envValue == [ ]
      )
      || throw "untracked ref self carriers: ${
        builtins.toJSON {
          secondCarrierAudit = auditOf secondCarrier;
          inherit required serviceAccount;
        }
      }";

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
    # The velero shape: a Deployment selecting on the instance labels alone
    # while a DaemonSet's pod template carries those plus its own name. The
    # Deployment's selector matches both pod sets, so `kix deploy` judged it
    # from a node-agent pod.
    t55b-workload-selector-claims-another-pod-set =
      let
        rule = (import ../rules/architecture.nix { inherit lib; }).distinctWorkloadSelectors;
        shared = {
          "app.kubernetes.io/instance" = "velero";
        };
        workload = kind: name: selector: podLabels: {
          inherit kind;
          metadata = {
            inherit name;
            namespace = "ns";
          };
          spec = {
            selector.matchLabels = selector;
            template.metadata.labels = podLabels;
          };
        };
        findings = rule.check {
          instanceName = "velero";
          resources = [
            (workload "Deployment" "velero" shared shared)
            (workload "DaemonSet" "node-agent" (shared // { name = "node-agent"; }) (
              shared // { name = "node-agent"; }
            ))
          ];
        };
        msg = builtins.concatStringsSep " " (map (f: f.message) findings);
      in
      (builtins.length findings == 1 && lib.hasInfix "also matches the pods of" msg)
      || throw "expected one selector-overlap finding, got: ${msg}";

    # Each workload carrying its own label is the fix, and passes.
    t55c-distinct-workload-selectors-pass =
      let
        rule = (import ../rules/architecture.nix { inherit lib; }).distinctWorkloadSelectors;
        workload = kind: name: labels: {
          inherit kind;
          metadata = {
            inherit name;
            namespace = "ns";
          };
          spec = {
            selector.matchLabels = labels;
            template.metadata.labels = labels;
          };
        };
        findings = rule.check {
          instanceName = "velero";
          resources = [
            (workload "Deployment" "velero" { name = "velero"; })
            (workload "DaemonSet" "node-agent" { name = "node-agent"; })
          ];
        };
      in
      findings == [ ] || throw "expected no findings, got: ${builtins.toJSON findings}";

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
        && lib.hasInfix "duplicate name" msg
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
                    enabled = true;
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
            consumer.package = requiredScConsumer;
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
    # by group/kind/name/namespace, the four fields Envoy Gateway's
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

    # A workload kind through raw scope.mkResource never reaches sealWorkload
    # (no validators, no derived spread, no netpol edges), so it is refused.
    t87-raw-workload-kind-throws = evalFails (mkCluster [
      baseInstances
      { instances.appns.raw.package = mkRawDeploymentPackage; }
    ]);

    # A CronJob used to slip past the refusal list, so its pods got no
    # pod-spec validators, no DNS ordering and no network-policy edges.
    t87b-raw-cronjob-kind-throws = evalFails (mkCluster [
      baseInstances
      {
        instances.appns.rawcj.package = {
          build =
            { self, scope, ... }:
            {
              cj = scope.mkResource {
                apiVersion = "batch/v1";
                kind = "CronJob";
                name = "raw-cronjob";
                extra.spec.schedule = "* * * * *";
              };
              root = self.cj;
            };
        };
      }
    ]);

    # ---------------------------------------------------- v2_discussions/145
    # The availability level: derived from the substrate, overridable per
    # instance, capped by the package, refused above the substrate. Spread
    # strictness is a lowering of the level; constraints and the PDB are
    # derived for every workload above one replica (mechanism from 143).

    # Two or more zones derive "zone": hard on the zone key, best effort on
    # hostname.
    a01-level-zone-derived-from-zones =
      let
        keys = spreadKeys (
          spreadOf (mkCluster [
            multiZone
            { instances.appns.web.package = mkReplicatedPackage { }; }
          ])
        );
      in
      keys == [
        "topology.kubernetes.io/zone=DoNotSchedule"
        "kubernetes.io/hostname=ScheduleAnyway"
      ]
      || throw "zone-level spread wrong: ${builtins.toJSON keys}";

    # multiNode with zones unknown derives "node": hard on hostname only.
    a02-level-node-derived-when-zones-unknown =
      let
        keys = spreadKeys (
          spreadOf (mkCluster [
            { cluster.capabilities.multiNode = true; }
            { instances.appns.web.package = mkReplicatedPackage { }; }
          ])
        );
      in
      keys == [ "kubernetes.io/hostname=DoNotSchedule" ]
      || throw "node-level spread wrong: ${builtins.toJSON keys}";

    # multiNode = false derives "none": nothing derived, no PDB either, and
    # the level is visible to the package.
    a03-level-none-on-single-node =
      let
        cluster = mkCluster [
          singleNode
          { instances.appns.web.package = mkReplicatedPackage { }; }
        ];
      in
      (
        spreadOf cluster == [ ]
        && ofKind "PodDisruptionBudget" (manifests cluster) == [ ]
        && levelSeenBy [ singleNode ] == "none"
      )
      || throw "single node still derived spread or a PDB";

    a04-single-replica-untouched =
      let
        cluster = mkCluster [
          multiZone
          { instances.appns.web.package = mkReplicatedPackage { replicas = 1; }; }
        ];
      in
      (spreadOf cluster == [ ] && ofKind "PodDisruptionBudget" (manifests cluster) == [ ])
      || throw "single-replica workload got spread or a PDB";

    # Author-written topologySpreadConstraints win whole: nothing is merged
    # in and no PDB is derived (one signal, one meaning).
    a05-author-placement-wins-whole =
      let
        mine = [
          {
            topologyKey = "example.com/rack";
            maxSkew = 2;
            whenUnsatisfiable = "ScheduleAnyway";
            labelSelector.matchLabels.app = "web";
          }
        ];
        cluster = mkCluster [
          multiZone
          {
            instances.appns.web.package = mkReplicatedPackage {
              templateExtra.topologySpreadConstraints = mine;
            };
          }
        ];
      in
      (spreadOf cluster == mine && ofKind "PodDisruptionBudget" (manifests cluster) == [ ])
      || throw "author-written spread was merged with or a PDB was added";

    # instances.<ns>.<inst>.availability = "none" with an explicit replica
    # count above one: the count is a request for availability, so the pods
    # still get best-effort spread and a PDB.
    a06-instance-none-keeps-soft-spread-for-explicit-replicas =
      let
        cluster = mkCluster [
          multiZone
          {
            instances.appns.web = {
              package = mkReplicatedPackage { };
              availability = "none";
            };
          }
        ];
        keys = spreadKeys (spreadOf cluster);
      in
      (
        keys == [
          "topology.kubernetes.io/zone=ScheduleAnyway"
          "kubernetes.io/hostname=ScheduleAnyway"
        ]
        && namesOf (ofKind "PodDisruptionBudget" (manifests cluster)) == [ "web" ]
      )
      || throw "availability=none spread wrong: ${builtins.toJSON keys}";

    # An instance may exceed the cluster default up to the substrate.
    a07-instance-may-exceed-cluster-default =
      let
        keys = spreadKeys (
          spreadOf (mkCluster [
            multiZone
            { cluster.availability.default = "node"; }
            {
              instances.appns.web = {
                package = mkReplicatedPackage { };
                availability = "zone";
              };
            }
          ])
        );
      in
      keys == [
        "topology.kubernetes.io/zone=DoNotSchedule"
        "kubernetes.io/hostname=ScheduleAnyway"
      ]
      || throw "instance override above cluster default wrong: ${builtins.toJSON keys}";

    # "node" on a zoned cluster: hard on hostname, best effort on the zone.
    a08-level-node-on-zoned-cluster =
      let
        keys = spreadKeys (
          spreadOf (mkCluster [
            multiZone
            { cluster.availability.default = "node"; }
            { instances.appns.web.package = mkReplicatedPackage { }; }
          ])
        );
      in
      keys == [
        "topology.kubernetes.io/zone=ScheduleAnyway"
        "kubernetes.io/hostname=DoNotSchedule"
      ]
      || throw "node-level spread on zoned cluster wrong: ${builtins.toJSON keys}";

    # With maxSkew = 1 a DoNotSchedule constraint is even distribution, not
    # one pod per domain: five replicas across three zones is 2/2/1 and
    # legal, so there is no replica-count arithmetic to refuse.
    a09-hard-spread-tolerates-more-replicas-than-domains =
      let
        cs = spreadOf (mkCluster [
          multiZone
          { instances.appns.web.package = mkReplicatedPackage { replicas = 5; }; }
        ]);
      in
      builtins.length cs == 2 || throw "zone level with replicas > zones was refused";

    # The substrate caps every level: a request above a known substrate is
    # an error, above an unknown one it builds with a warning.
    a10-substrate-caps-the-level =
      evalFails (mkCluster [
        { cluster.capabilities.availabilityZones = [ "only" ]; }
        { cluster.capabilities.multiNode = true; }
        { cluster.availability.default = "zone"; }
        { instances.appns.web.package = mkReplicatedPackage { }; }
      ])
      && evalFails (mkCluster [
        singleNode
        {
          instances.appns.web = {
            package = mkReplicatedPackage { };
            availability = "node";
          };
        }
      ])
      && hasName "web" (
        ofKind "Deployment" (
          manifests (mkCluster [
            { cluster.availability.default = "zone"; }
            { instances.appns.web.package = mkReplicatedPackage { }; }
          ])
        )
      );

    # meta.availability.max caps the level for one package, with a warning
    # this matrix cannot observe; the package then runs at its ceiling.
    a11-package-ceiling-caps-the-level =
      let
        keys = spreadKeys (
          spreadOf (mkCluster [
            multiZone
            { instances.appns.web.package = mkReplicatedPackage { metaExtra.availability.max = "pod"; }; }
          ])
        );
      in
      (
        keys == [
          "topology.kubernetes.io/zone=ScheduleAnyway"
          "kubernetes.io/hostname=ScheduleAnyway"
        ]
        &&
          levelSeenBy [
            multiZone
            {
              # Constant above "pod": the package never sees a higher level.
              instances.appns.capped.package = mkLevelPackage {
                metaExtra.availability.max = "pod";
                table = {
                  none = 1;
                  pod = 2;
                  node = 2;
                  zone = 2;
                };
              };
            }
          ] == "pod"
      )
      || throw "ceiling not applied: ${builtins.toJSON keys}";

    # An explicit hard placement rule on a multi-replica workload cannot
    # be satisfied on one node: refused when multiNode is declared false.
    s12-single-node-refuses-hard-anti-affinity = evalFails (mkCluster [
      singleNode
      { instances.appns.web.package = mkReplicatedPackage { templateExtra = hardHostnameAntiAffinity; }; }
    ]);

    s12b-single-node-refuses-hard-spread = evalFails (mkCluster [
      singleNode
      {
        instances.appns.web.package = mkReplicatedPackage {
          templateExtra.topologySpreadConstraints = [
            {
              topologyKey = "kubernetes.io/hostname";
              maxSkew = 1;
              whenUnsatisfiable = "DoNotSchedule";
              labelSelector.matchLabels.app = "web";
            }
          ];
        };
      }
    ]);

    # Preferred rules and single replicas are fine on one node.
    s13-single-node-soft-anti-affinity-passes =
      hasName "web" (
        ofKind "Deployment" (
          manifests (mkCluster [
            singleNode
            {
              instances.appns.web.package = mkReplicatedPackage {
                templateExtra.affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution = [
                  {
                    weight = 1;
                    podAffinityTerm = {
                      labelSelector.matchLabels.app = "web";
                      topologyKey = "kubernetes.io/hostname";
                    };
                  }
                ];
              };
            }
          ])
        )
      )
      || throw "soft anti-affinity on one node was refused";

    s13b-single-node-hard-rule-one-replica-passes =
      hasName "web" (
        ofKind "Deployment" (
          manifests (mkCluster [
            singleNode
            {
              instances.appns.web.package = mkReplicatedPackage {
                replicas = 1;
                templateExtra = hardHostnameAntiAffinity;
              };
            }
          ])
        )
      )
      || throw "hard anti-affinity with one replica was refused";

    # multiNode unknown: the hard rule warns and the cluster still builds.
    s14-multinode-unknown-hard-anti-affinity-warns-only =
      hasName "web" (
        ofKind "Deployment" (
          manifests (mkCluster [
            { instances.appns.web.package = mkReplicatedPackage { templateExtra = hardHostnameAntiAffinity; }; }
          ])
        )
      )
      || throw "hard anti-affinity under unknown multiNode was refused";

    # A PDB rides the same gate, named after the workload, in its
    # namespace, selecting what the workload selects.
    a15-pdb-derived =
      let
        ms = manifests (mkCluster [
          multiZone
          { instances.appns.web.package = mkReplicatedPackage { }; }
        ]);
        pdbs = ofKind "PodDisruptionBudget" ms;
        pdb = byName "web" pdbs;
        web = byName "web" (ofKind "Deployment" ms);
      in
      (
        builtins.length pdbs == 1
        && pdb.metadata.namespace == "appns"
        && pdb.spec.maxUnavailable == 1
        && pdb.spec.selector.matchLabels == web.spec.selector.matchLabels
      )
      || throw "derived PDB wrong: ${builtins.toJSON pdbs}";

    # An author-written PDB over the same pods is kept and nothing is added.
    a16-pdb-author-wins =
      let
        pdbs = ofKind "PodDisruptionBudget" (
          manifests (mkCluster [
            multiZone
            { instances.appns.web.package = mkReplicatedPackage { withPdb = true; }; }
          ])
        );
      in
      namesOf pdbs == [ "web-pdb" ] || throw "author PDB not honoured: ${builtins.toJSON (namesOf pdbs)}";

    # Helm-imported workloads go through the same seal and get the same spread.
    a17-helm-workload-gets-spread =
      let
        keys = spreadKeys (
          spreadOf (mkCluster [
            multiZone
            { instances.appns.web.package = mkReplicatedPackage { helm = true; }; }
          ])
        );
      in
      keys == [
        "topology.kubernetes.io/zone=DoNotSchedule"
        "kubernetes.io/hostname=ScheduleAnyway"
      ]
      || throw "helm workload spread wrong: ${builtins.toJSON keys}";

    # The failure-domain keys and the substrate level are readable cluster
    # facts for packages whose pods an operator renders.
    a18-failure-domain-keys-are-a-cluster-fact =
      let
        keysProbe = {
          meta.version = "test";
          build =
            {
              self,
              scope,
              clusterConfig,
              ...
            }:
            {
              root = self.cm;
              cm = scope.mkResource {
                apiVersion = "v1";
                kind = "ConfigMap";
                name = "keys";
                data.keys = builtins.concatStringsSep "," clusterConfig.cluster.topology.failureDomainKeys;
                data.substrate = clusterConfig.cluster.availability.substrate;
              };
            };
        };
        probe =
          mods:
          byName "keys" (
            ofKind "ConfigMap" (manifests (mkCluster (mods ++ [ { instances.p.probe.package = keysProbe; } ])))
          );
        keysOf = mods: builtins.filter (k: k != "") (lib.splitString "," (probe mods).data.keys);
      in
      (
        keysOf [ multiZone ] == [
          "topology.kubernetes.io/zone"
          "kubernetes.io/hostname"
        ]
        && keysOf [ singleNode ] == [ ]
        &&
          keysOf [ { cluster.capabilities.availabilityZones = [ "only" ]; } ] == [ "kubernetes.io/hostname" ]
        && (probe [ multiZone ]).data.substrate == "zone"
        && (probe [ singleNode ]).data.substrate == "none"
      )
      || throw "failureDomainKeys or substrate wrong";

    # The labels that name a zone and a host are cluster facts too: a
    # hand-labelled substrate sets its own and every derived constraint,
    # the strictness lowering and failureDomainKeys follow.
    a18b-topology-keys-are-configurable =
      let
        customKeys = {
          cluster.topology.zoneKey = "topology.example.com/rack";
          cluster.topology.hostKey = "example.com/host";
        };
        cluster = mkCluster [
          multiZone
          customKeys
          { instances.appns.web.package = mkReplicatedPackage { }; }
        ];
        keys = spreadKeys (spreadOf cluster);
        keysProbe = {
          meta.version = "test";
          build =
            {
              self,
              scope,
              clusterConfig,
              ...
            }:
            {
              root = self.cm;
              cm = scope.mkResource {
                apiVersion = "v1";
                kind = "ConfigMap";
                name = "keys";
                data.keys = builtins.concatStringsSep "," clusterConfig.cluster.topology.failureDomainKeys;
              };
            };
        };
        seen =
          (byName "keys" (
            ofKind "ConfigMap" (
              manifests (mkCluster [
                multiZone
                customKeys
                { instances.p.probe.package = keysProbe; }
              ])
            )
          )).data.keys;
        nodeKeys = spreadKeys (
          spreadOf (mkCluster [
            { cluster.capabilities.multiNode = true; }
            customKeys
            { instances.appns.web.package = mkReplicatedPackage { }; }
          ])
        );
      in
      (
        keys == [
          "topology.example.com/rack=DoNotSchedule"
          "example.com/host=ScheduleAnyway"
        ]
        && seen == "topology.example.com/rack,example.com/host"
        && nodeKeys == [ "example.com/host=DoNotSchedule" ]
      )
      || throw "custom topology keys not honoured: ${builtins.toJSON keys} ${seen} ${builtins.toJSON nodeKeys}";

    # The package receives the resolved level as its `availability`
    # argument and maps it through kix.availability.pick; an explicit
    # instance value still wins over the mapped default.
    a19-package-maps-the-level =
      let
        replicasUnder =
          mods:
          (byName "web" (
            ofKind "Deployment" (
              manifests (mkCluster (mods ++ [ { instances.appns.web.package = mkLevelPackage { }; } ]))
            )
          )).spec.replicas;
      in
      (
        replicasUnder [ singleNode ] == 1
        && replicasUnder [ { cluster.capabilities.multiNode = true; } ] == 2
        && replicasUnder [ multiZone ] == 3
        &&
          replicasUnder [
            multiZone
            { instances.appns.web.config.replicas = 7; }
          ] == 7
        &&
          levelSeenBy [
            multiZone
            { instances.appns.capped.availability = "pod"; }
          ] == "pod"
      )
      || throw "package did not receive or map the level";

    # kix.availability.pick refuses an incomplete table, so a package's
    # mapping is complete by construction.
    # A ceiling on one workload lowers that workload only: the controller
    # declares availability.max = "pod" and spreads best-effort, the
    # quorum store beside it keeps the hard zone constraint, and the
    # package's `availability` argument still says "zone". The instance
    # ceiling would have lowered all three.
    a21-workload-ceiling-lowers-one-workload =
      let
        pkg = {
          meta.version = "test";
          build =
            {
              self,
              scope,
              availability,
              ...
            }:
            let
              body =
                name: extra:
                {
                  inherit name;
                  spec = {
                    replicas = 3;
                    selector.matchLabels = scope.selectorLabels // {
                      part = name;
                    };
                    template = {
                      metadata.labels = scope.selectorLabels // {
                        part = name;
                      };
                      spec.containers = [
                        (
                          {
                            inherit name;
                            image = "example/${name}:1";
                          }
                          // containerBase
                        )
                      ];
                    };
                  };
                }
                // extra;
            in
            {
              controller = scope.mkDeployment (body "controller" { availability.max = "pod"; });
              quorum = scope.mkStatefulSet (body "quorum" { });
              seen = scope.mkResource {
                apiVersion = "v1";
                kind = "ConfigMap";
                name = "level";
                data.level = availability;
              };
              root = {
                resource = self.controller;
                requires = [
                  self.quorum
                  self.seen
                ];
              };
            };
        };
        ms = manifests (mkCluster [
          multiZone
          { instances.appns.mixed.package = pkg; }
        ]);
        keysOf =
          kind: name:
          spreadKeys ((byName name (ofKind kind ms)).spec.template.spec.topologySpreadConstraints or [ ]);
        controllerKeys = keysOf "Deployment" "controller";
        quorumKeys = keysOf "StatefulSet" "quorum";
        seen = (byName "level" (ofKind "ConfigMap" ms)).data.level;
        notInManifest = !((byName "controller" (ofKind "Deployment" ms)) ? availability);
      in
      (
        controllerKeys == [
          "topology.kubernetes.io/zone=ScheduleAnyway"
          "kubernetes.io/hostname=ScheduleAnyway"
        ]
        &&
          quorumKeys == [
            "topology.kubernetes.io/zone=DoNotSchedule"
            "kubernetes.io/hostname=ScheduleAnyway"
          ]
        && seen == "zone"
        && notInManifest
      )
      || throw "workload ceiling: controller=${builtins.toJSON controllerKeys} quorum=${builtins.toJSON quorumKeys} seen=${seen}";

    a20-pick-refuses-incomplete-table =
      !(builtins.tryEval (
        kixlib.availability.pick "zone" {
          none = 1;
          zone = 3;
        }
      )).success
      && kixlib.availability.atLeast "node" "zone"
      && !(kixlib.availability.atLeast "node" "pod");

    # Two instances answer the dep's name from two namespaces, and the
    # consumer in a third names the one it wants. The first resolution
    # pass cannot see explicit wiring and used to throw "ambiguous" before
    # the pass that can got a turn.
    t98-explicit-dep-wins-over-ambiguous-name =
      let
        cluster = mkCluster [
          baseInstances
          {
            instances.infra.operator.package = mkCmPackage { name = "operator-a"; };
            instances.infra2.operator.package = mkCmPackage { name = "operator-b"; };
          }
          (
            { ref, ... }:
            {
              instances.appns.writer = {
                package = mkAnnotatedCmPackage {
                  key = "example.test/x";
                  withOperatorDep = true;
                };
                deps.operator = ref.infra2.operator;
              };
            }
          )
        ];
      in
      builtins.deepSeq (manifests cluster) true;

    # Without the explicit wiring the same cluster is still an error.
    t99-ambiguous-dep-still-refused = evalFails (mkCluster [
      baseInstances
      {
        instances.infra.operator.package = mkCmPackage { name = "operator-a"; };
        instances.infra2.operator.package = mkCmPackage { name = "operator-b"; };
        instances.appns.writer.package = mkAnnotatedCmPackage {
          key = "example.test/x";
          withOperatorDep = true;
        };
      }
    ]);

    # A consumer's `deps.<arg>.config` lands on the instance the consumer
    # wired, and not on the one that merely answers the name in the
    # consumer's namespace.
    t100-injection-follows-explicit-wiring =
      let
        target = {
          meta.version = "test";
          options.marker = lib.mkOption {
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
                name = "target-cm";
                extra.data.marker = config.marker;
              };
              root = self.cm;
            };
        };
        consumer = {
          meta.version = "test";
          deps.target.config.marker = "injected";
          build =
            {
              self,
              scope,
              target,
              ...
            }:
            {
              cm = scope.mkResource {
                apiVersion = "v1";
                kind = "ConfigMap";
                name = "consumer-cm";
                extra.data.dep = target.out.name;
              };
              root = self.cm;
            };
        };
        cluster = mkCluster [
          baseInstances
          {
            # One in the consumer's own namespace: the name alone would
            # pick this one.
            instances.appns.target.package = target;
            instances.infra.target.package = target;
          }
          (
            { ref, ... }:
            {
              instances.appns.consumer = {
                package = consumer;
                deps.target = ref.infra.target;
              };
            }
          )
        ];
        markerIn =
          ns:
          (lib.findFirst (
            m: (m.kind or "") == "ConfigMap" && m.metadata.name == "target-cm" && m.metadata.namespace == ns
          ) (throw "no target-cm in ${ns}") (manifests cluster)).data.marker;
      in
      (markerIn "infra" == "injected" && markerIn "appns" == "unset")
      || throw "injection went to infra=${markerIn "infra"} appns=${markerIn "appns"}";

    # ------------------------------------------------------ kix.mergeGuarded
    t101-merge-guarded =
      let
        guard = kixlib.mergeGuarded {
          who = "pkg (x)";
          locked = [
            [
              "a"
              "b"
            ]
            [ "c" ]
          ];
        };
        base = {
          a.b = 1;
          a.z = 1;
          c = 1;
        };
        merged = guard base { a.z = 2; };
        refused = spec: !(builtins.tryEval (builtins.deepSeq (guard base spec) true)).success;
      in
      (
        merged == {
          a.b = 1;
          a.z = 2;
          c = 1;
        }
      )
      && refused { a.b = 2; }
      && refused { c = 2; }
      || throw "mergeGuarded: ${builtins.toJSON merged}";

    # ------------------------------------------------------- kix.mkEnvVars
    #
    # A value is a string or a `valueFrom` source (what
    # `secret.out.keyRef` returns). Any other attrset would render as an
    # env var whose value is an object, which the API server rejects at
    # apply time, so it is refused here.
    t102-mkenvvars-accepts-value-from =
      let
        source = {
          # A stray `name` in the source must not rename the variable.
          name = "not-the-env-name";
          valueFrom.secretKeyRef = {
            name = "creds";
            key = "password";
          };
        };
        rendered = kixlib.mkEnvVars {
          A_PLAIN = "x";
          B_DROPPED = null;
          C_SECRET = source;
        };
      in
      rendered == [
        {
          name = "A_PLAIN";
          value = "x";
        }
        (source // { name = "C_SECRET"; })
      ]
      || throw "mkEnvVars rendered: ${builtins.toJSON rendered}";

    t103-mkenvvars-refuses-object-value =
      !(builtins.tryEval (builtins.deepSeq (kixlib.mkEnvVars { BAD.nested = "x"; }) true)).success
      || throw "mkEnvVars accepted an attrset with no valueFrom";

    # kix.options.image keeps the package's digest while the instance leaves
    # `tag` at the package's tag, and drops it when the tag changes.
    t104-image-option-keeps-digest-with-its-tag =
      let
        digestOf = c: "sha256:${lib.concatStrings (lib.genList (_: c) 64)}";
        eval =
          defs:
          (lib.evalModules {
            modules = [
              {
                options.image = kixlib.options.image {
                  repository = "reg.example/app";
                  tag = "v1";
                  digest = digestOf "a";
                };
              }
            ]
            ++ map (d: { config.image = d; }) defs;
          }).config.image.digest;
        cases = {
          none = eval [ ] == digestOf "a";
          pullPolicy = eval [ { pullPolicy = "Always"; } ] == digestOf "a";
          repository = eval [ { repository = "mirror.example/app"; } ] == digestOf "a";
          tag = eval [ { tag = "v2"; } ] == null;
          tagAndDigest =
            eval [
              {
                tag = "v2";
                digest = digestOf "b";
              }
            ] == digestOf "b";
        };
      in
      builtins.all lib.id (builtins.attrValues cases)
      || throw "options.image digest default wrong: ${builtins.toJSON cases}";

    # --- contested shelf keys (v2_discussions/151) ---

    t105-uncontested-alias-pulls-its-claimant =
      let
        ms = manifests (mkCluster [
          baseInstances
          {
            availablePackages.a.package = shelfX "a";
            instances.appns.consumer.package = xConsumer;
          }
        ]);
      in
      whoOf ms == "a" || throw "uncontested alias not auto-instantiated: ${whoOf ms}";

    t106-contested-alias-without-demand-builds =
      let
        ms = manifests (mkCluster [
          baseInstances
          {
            availablePackages.a.package = shelfX "a";
            availablePackages.b.package = shelfX "b";
          }
        ]);
      in
      !(hasName "shelf-a" ms || hasName "shelf-b" ms)
      || throw "contested shelf key instantiated without demand";

    t107-contested-alias-with-demand-throws = evalFails (mkCluster [
      baseInstances
      {
        availablePackages.a.package = shelfX "a";
        availablePackages.b.package = shelfX "b";
        instances.appns.consumer.package = xConsumer;
      }
    ]);

    # An optional instance answering the key is the selection: it is
    # activated and neither shelf claimant is instantiated.
    t108-optional-instance-selects-contested-alias =
      let
        ms = manifests (mkCluster [
          baseInstances
          {
            availablePackages.a.package = shelfX "a";
            availablePackages.b.package = shelfX "b";
            instances.infra.x = {
              package = shelfX "chosen";
              optional = true;
            };
            instances.appns.consumer.package = xConsumer;
          }
        ]);
      in
      (whoOf ms == "chosen" && !(hasName "shelf-a" ms || hasName "shelf-b" ms))
      || throw "optional instance did not select the contested alias: ${whoOf ms}";

    # A package named `x` gets no priority over a package aliased `x`.
    t109-package-name-does-not-outrank-alias = evalFails (mkCluster [
      baseInstances
      {
        availablePackages.x.package = shelfX "named";
        availablePackages.b.package = shelfX "b";
        instances.appns.consumer.package = xConsumer;
      }
    ]);

    t110-two-optional-instances-for-one-key-throw = evalFails (mkCluster [
      baseInstances
      {
        instances.infra.x = {
          package = shelfX "one";
          optional = true;
        };
        instances.other.x = {
          package = shelfX "two";
          optional = true;
        };
        instances.appns.consumer.package = xConsumer;
      }
    ]);

    # An optional import yields to a managed optional instance for the
    # same key, so the pair is not a conflict.
    t111-managed-optional-outranks-optional-import =
      let
        ms = manifests (mkCluster [
          baseInstances
          {
            instances.platform.x = {
              package = eval.mkImport { out.who = "import"; };
              optional = true;
            };
            instances.infra.x = {
              package = shelfX "managed";
              optional = true;
            };
            instances.appns.consumer.package = xConsumer;
          }
        ]);
      in
      whoOf ms == "managed" || throw "managed optional did not outrank the import: ${whoOf ms}";

    # `deps.x = ref...` wires the dependency, so the consumer places no
    # demand on the shelf, contested or not.
    t114-explicit-deps-wiring-places-no-shelf-demand =
      let
        ms = manifests (mkCluster [
          baseInstances
          (
            { ref, ... }:
            {
              availablePackages.a.package = shelfX "a";
              availablePackages.b.package = shelfX "b";
              instances.infra.wired.package = mkCmPackage {
                name = "wired";
                out.who = "wired";
              };
              instances.appns.consumer = {
                package = xConsumer;
                deps.x = ref.infra.wired;
              };
            }
          )
        ]);
      in
      (whoOf ms == "wired" && !(hasName "shelf-a" ms || hasName "shelf-b" ms))
      || throw "explicitly wired dep still demanded the shelf: ${whoOf ms}";

    # `deps.x = ref...` to an optional instance activates it, and the
    # activated instance's own demands are walked.
    t119-explicit-ref-activates-optional-instance =
      let
        ms = manifests (mkCluster [
          baseInstances
          (
            { ref, ... }:
            {
              instances.infra.x = {
                package = zRequirer;
                optional = true;
              };
              instances.infra.z = {
                package = mkCmPackage {
                  name = "opt-z";
                  out.who = "z";
                };
                optional = true;
              };
              instances.appns.consumer = {
                package = xConsumer;
                deps.x = ref.infra.x;
              };
            }
          )
        ]);
      in
      (whoOf ms == "via-z" && hasName "z-requirer" ms && hasName "opt-z" ms)
      || throw "explicit ref did not activate the optional instance: ${whoOf ms}";

    t120-explicit-ref-activates-optional-of-another-name =
      let
        ms = manifests (mkCluster [
          baseInstances
          (
            { ref, ... }:
            {
              instances.infra.y = {
                package = mkCmPackage {
                  name = "opt-y";
                  out.who = "y";
                };
                optional = true;
              };
              instances.appns.consumer = {
                package = xConsumer;
                deps.x = ref.infra.y;
              };
            }
          )
        ]);
      in
      (whoOf ms == "y" && hasName "opt-y" ms)
      || throw "explicit ref to another name did not activate it: ${whoOf ms}";

    # `deps.x = null` leaves the dependency to normal resolution.
    t121-null-deps-entry-keeps-shelf-demand =
      let
        ms = manifests (mkCluster [
          baseInstances
          {
            availablePackages.a.package = shelfX "a";
            instances.appns.consumer = {
              package = xConsumer;
              deps.x = null;
            };
          }
        ]);
      in
      whoOf ms == "a" || throw "deps.x = null suppressed the shelf demand: ${whoOf ms}";

    # Optional instances follow resolveArg's ladder: the one in the
    # requester's namespace wins over one elsewhere.
    t122-optional-in-requester-namespace-wins =
      let
        ms = manifests (mkCluster [
          baseInstances
          {
            instances.appns.x = {
              package = shelfX "near";
              optional = true;
            };
            instances.infra.x = {
              package = shelfX "far";
              optional = true;
            };
            instances.appns.consumer.package = xConsumer;
          }
        ]);
      in
      (whoOf ms == "near" && !(hasName "shelf-far" ms))
      || throw "same-namespace optional did not win: ${whoOf ms}";

    # A `deps` entry under `mkIf false` is absent.
    t123-mkif-false-deps-entry-is-absent =
      let
        ms = manifests (mkCluster [
          baseInstances
          (
            { ref, ... }:
            {
              availablePackages.a.package = shelfX "a";
              instances.infra.wired.package = mkCmPackage {
                name = "wired";
                out.who = "wired";
              };
              instances.appns.consumer = {
                package = xConsumer;
                deps.x = lib.mkIf false ref.infra.wired;
              };
            }
          )
        ]);
      in
      whoOf ms == "a" || throw "mkIf false deps entry was not dropped: ${whoOf ms}";

    # `ref` covers every name auto-instantiation could create; a ref to one
    # it did not create is refused with a Kix error.
    t124-ref-to-uncreated-shelf-name-throws = evalFails (mkCluster [
      baseInstances
      (
        { ref, ... }:
        {
          availablePackages.a.package = shelfX "a";
          instances.appns.consumer = {
            package = xConsumer;
            deps.x = ref.appns.a;
          };
        }
      )
    ]);

    # A package's `config` module defaults `keep` from `message`; an
    # instance that sets `keep` itself overrides that default.
    t116-package-config-defaults-one-option-from-another =
      let
        package = envProbePackage // {
          config =
            { config, ... }:
            {
              keep = lib.mkDefault config.message;
            };
        };
        keepFor =
          config:
          let
            ms = manifests (mkCluster [
              {
                instances.probens.probe = { inherit package config; };
              }
            ]);
          in
          (byName "probe" (ofKind "ConfigMap" ms)).data.keep;
        cases = {
          follows = keepFor { message = "hi"; } == "hi";
          instanceWins =
            keepFor {
              message = "hi";
              keep = "own";
            } == "own";
          packageDefault = keepFor { } == "unset";
        };
      in
      builtins.all lib.id (builtins.attrValues cases)
      || throw "package config defaulting wrong: ${builtins.toJSON cases}";

    # An attrset package `config` sets options by name, including an option
    # that is itself called `config`.
    t117-package-config-attrset-sets-option-named-config =
      let
        config = eval.evaluateInstanceConfig {
          packageOptions.config = lib.mkOption {
            type = lib.types.str;
            default = "declared";
          };
          packageConfig.config = lib.mkDefault "from package";
          instCfg.config.imports = [ ];
        };
      in
      config.config == "from package"
      || throw "package config attrset did not set option 'config': ${builtins.toJSON config}";

    # A component image whose tag follows the main image's tag through the
    # package `config` keeps its own default digest while the main tag is
    # unchanged, and drops it once the main tag moves.
    t118-package-config-tag-follow-drops-digest =
      let
        digestOf = c: "sha256:${lib.concatStrings (lib.genList (_: c) 64)}";
        evalWith =
          defs:
          (eval.evaluateInstanceConfig {
            packageOptions = {
              image = kixlib.options.image {
                repository = "reg.example/app";
                tag = "v1";
                digest = digestOf "a";
              };
              sidecar.image = kixlib.options.image {
                repository = "reg.example/sidecar";
                tag = "v1";
                digest = digestOf "b";
                tagText = "config.image.tag";
              };
            };
            packageConfig =
              { config, ... }:
              {
                sidecar.image.tag = lib.mkDefault config.image.tag;
              };
            instCfg.config.imports = defs;
          }).sidecar.image;
        cases = {
          unchanged =
            let
              img = evalWith [ ];
            in
            img.tag == "v1" && img.digest == digestOf "b";
          moved =
            let
              img = evalWith [ { image.tag = "v2"; } ];
            in
            img.tag == "v2" && img.digest == null;
          pinnedBack =
            let
              img = evalWith [
                {
                  image.tag = "v2";
                  sidecar.image.tag = "v1";
                }
              ];
            in
            img.tag == "v1" && img.digest == digestOf "b";
        };
      in
      builtins.all lib.id (builtins.attrValues cases)
      || throw "package config tag follow and digest wrong: ${builtins.toJSON cases}";

    # A `lib.mkDefault` in the package's `config` sits between an instance
    # or injection `lib.mkDefault` and the option's declared default: the
    # instance and the injection win, plain instance values win, and with
    # neither the package default replaces the declared one.
    t126-package-config-mkdefault-yields-to-instance-and-injection =
      let
        tagWith =
          {
            defs ? [ ],
            injections ? [ ],
          }:
          (eval.evaluateInstanceConfig {
            packageOptions = {
              image = kixlib.options.image {
                repository = "reg.example/app";
                tag = "v1";
              };
              side.image = kixlib.options.image {
                repository = "reg.example/side";
                tag = "v1";
                tagText = "config.image.tag";
              };
            };
            packageConfig =
              { config, ... }:
              {
                side.image.tag = lib.mkDefault config.image.tag;
              };
            instCfg.config.imports = defs;
            configInjections = injections;
          }).side.image.tag;
        cases = {
          packageBeatsDeclared = tagWith { defs = [ { image.tag = "v2"; } ]; } == "v2";
          instanceMkDefault =
            tagWith {
              defs = [
                {
                  image.tag = "v2";
                  side.image.tag = lib.mkDefault "v9";
                }
              ];
            } == "v9";
          injectionMkDefault =
            tagWith {
              defs = [ { image.tag = "v2"; } ];
              injections = [
                {
                  source = "consumer";
                  config.side.image.tag = lib.mkDefault "v8";
                }
              ];
            } == "v8";
          instancePlain =
            tagWith {
              defs = [
                {
                  image.tag = "v2";
                  side.image.tag = "v7";
                }
              ];
            } == "v7";
        };
      in
      builtins.all lib.id (builtins.attrValues cases)
      || throw "package config mkDefault priority wrong: ${builtins.toJSON cases}";

    # The priority rewrite reaches a `lib.mkDefault` under `lib.mkIf` and
    # `lib.mkMerge`, and leaves a `lib.mkForce` in the package's `config`
    # above the instance.
    t127-package-config-priority-through-mkif-mkmerge =
      let
        valueWith =
          packageConfig: defs:
          (eval.evaluateInstanceConfig {
            packageOptions.v = lib.mkOption {
              type = lib.types.str;
              default = "declared";
            };
            inherit packageConfig;
            instCfg.config.imports = defs;
          }).v;
        cases = {
          mkIf =
            valueWith (lib.mkIf true { v = lib.mkDefault "package"; }) [ { v = lib.mkDefault "instance"; } ]
            == "instance";
          mkMerge =
            valueWith (lib.mkMerge [ { v = lib.mkDefault "package"; } ]) [ { v = lib.mkDefault "instance"; } ]
            == "instance";
          aloneBeatsDeclared = valueWith { v = lib.mkDefault "package"; } [ ] == "package";
          mkForceKept = valueWith { v = lib.mkForce "package"; } [ { v = "instance"; } ] == "package";
        };
      in
      builtins.all lib.id (builtins.attrValues cases)
      || throw "package config priority rewrite wrong: ${builtins.toJSON cases}";

    # Every shipped package with a `config` module declares its image
    # options so that the module changes none of them at the defaults. A
    # follower whose declared tag differs from its main tag would render the
    # main tag with no digest; this catches a release bump that updates one
    # declaration and not the other.
    t128-shipped-package-config-keeps-declared-images =
      let
        catalog = (import ../../packages/by-level.nix { inherit lib; }).byName;
        names = builtins.attrNames catalog;
        rawOf =
          n:
          eval.callPackagePhase1 {
            package = catalog.${n};
            scope = {
              instanceName = n;
              namespaceName = "pkgcfg";
            };
          };
        withConfig = builtins.filter (n: (rawOf n) ? config) names;
        # Paths of the options whose declared default is an image
        # (`kix.options.image`); submodule-typed options are not entered.
        imagePaths =
          prefix: opts:
          builtins.concatLists (
            lib.mapAttrsToList (
              k: o:
              if lib.isOption o then
                lib.optional ((builtins.tryEval (
                  o ? default && builtins.isAttrs o.default && o.default ? repository && o.default ? tag
                )).value or false
                ) (prefix ++ [ k ])
              else if builtins.isAttrs o then
                imagePaths (prefix ++ [ k ]) o
              else
                [ ]
            ) opts
          );
        mismatches = builtins.concatMap (
          n:
          let
            raw = rawOf n;
            evalWith =
              packageConfig:
              eval.evaluateInstanceConfig {
                packageOptions = raw.options;
                inherit packageConfig;
                instCfg.config.imports = [ ];
              };
            followed = evalWith raw.config;
            declared = evalWith { };
            fields = img: {
              inherit (img)
                repository
                tag
                digest
                pullPolicy
                ;
            };
          in
          builtins.concatMap (
            path:
            let
              a = fields (lib.getAttrFromPath path followed);
              b = fields (lib.getAttrFromPath path declared);
            in
            lib.optional (
              a != b
            ) "${n}: ${lib.concatStringsSep "." path} is ${builtins.toJSON a}, declared ${builtins.toJSON b}"
          ) (imagePaths [ ] raw.options)
        ) withConfig;
        expected = [
          "cert-manager"
          "clickhouse-operator"
          "prometheus-operator"
          "stackgres-operator"
          "tailscale"
        ];
        missing = lib.subtractLists withConfig expected;
      in
      (mismatches == [ ] && missing == [ ])
      || throw "package config changes a declared image: ${builtins.toJSON mismatches}; packages not checked: ${builtins.toJSON missing}";

    # cert-manager's startupapicheck Job follows the controller's tag and
    # pull policy until the instance sets its own.
    t129-cert-manager-startupapicheck-follows-controller-image =
      let
        jobImage =
          config:
          let
            ms = manifests (mkCluster [
              {
                instances.cert-manager.cert-manager = {
                  package = import ../../packages/experimental/cert-manager;
                  inherit config;
                };
              }
            ]);
            job = lib.findFirst (
              m: m.kind == "Job" && lib.hasInfix "startupapicheck" m.metadata.name
            ) (throw "no startupapicheck Job") ms;
            c = builtins.head job.spec.template.spec.containers;
          in
          {
            inherit (c) image imagePullPolicy;
          };
        cases = {
          follows =
            jobImage {
              image = {
                tag = "v1.21.3";
                pullPolicy = "Always";
              };
            } == {
              image = "quay.io/jetstack/cert-manager-startupapicheck:v1.21.3";
              imagePullPolicy = "Always";
            };
          own =
            (jobImage {
              image.pullPolicy = "Always";
              startupapicheck.image.pullPolicy = "Never";
            }).imagePullPolicy == "Never";
        };
      in
      builtins.all lib.id (builtins.attrValues cases)
      || throw "startupapicheck image does not follow the controller: ${builtins.toJSON cases}";

    # A global overlay and an instance overlay on one instance, read by a
    # consumer through `out`: the global overlay runs first, the instance
    # overlay second, and the consumer sees the `out` both produced.
    parts-overlays-global-then-instance =
      let
        consumerPackage = {
          meta.version = "test";
          build =
            {
              self,
              scope,
              base,
              ...
            }:
            {
              cm = scope.mkResource {
                apiVersion = "v1";
                kind = "ConfigMap";
                name = "consumer-${base.out.greeting}";
              };
              root = self.cm;
            };
        };
        ms = manifests (mkCluster [
          {
            globalPartsOverlays = [
              (
                scope: _self: base:
                if scope.instanceName == "base" then
                  {
                    root = base.root // {
                      out = (base.root.out or { }) // {
                        greeting = "hello";
                      };
                    };
                  }
                else
                  { }
              )
            ];
            instances.ovl.base = {
              package = mkCmPackage {
                name = "base-cm";
                out = { };
              };
              partsOverlays = [
                (scope: _self: base: {
                  extraCm = scope.mkResource {
                    apiVersion = "v1";
                    kind = "ConfigMap";
                    name = "overlay-${base.root.out.greeting}";
                  };
                  root = base.root // {
                    out = base.root.out // {
                      greeting = "${base.root.out.greeting}-again";
                    };
                  };
                })
              ];
            };
            instances.ovl.consumer.package = consumerPackage;
          }
        ]);
        cms = ofKind "ConfigMap" ms;
      in
      (hasName "overlay-hello" cms && hasName "consumer-hello-again" cms)
      || throw "partsOverlays order or out propagation wrong; ConfigMaps: ${builtins.toJSON (namesOf cms)}";
  }
  // import ./validate.nix {
    inherit
      lib
      k8s
      eval
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
      shelfX
      xConsumer
      stockStorage
      optionalScConsumer
      requiredScConsumer
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
        + ". Re-run a single test for its detailed message, e.g. "
        + "nix eval --impure --expr '(import ./kix/lib/tests { }).tests.<name>'"
      );
}

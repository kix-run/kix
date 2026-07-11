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
  k8s = import ../core { inherit lib; };
  eval = import ../eval { inherit lib k8s; };

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
                            value = db.out.name;
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

  dependsOn = m: (m.metadata.annotations or { })."kix.dev/depends-on" or "";

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
    # kix.dev annotations) stays silent.
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

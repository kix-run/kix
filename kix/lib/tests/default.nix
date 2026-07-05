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

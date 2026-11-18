# Tests for kix.operandPolicy, the network policy for pods an operator
# creates, and for kix/packages/experimental/kubevirt and kix/packages/experimental/cdi: the
# VirtualMachine and DataVolume builders, the importer policy builder,
# operand replicas, the extraSpec guard, images, RBAC, the vendored sources'
# release, and operand policies. kubevirt runs in namespace `kubevirt`, cdi
# in `cdi`, and the consumer in `vms`.
#
# Refusals raised with `throw` are checked with evalFails, which uses
# builtins.tryEval and cannot read the message, so each refused case
# differs from an accepted one by the field under test. A failed assertion
# fails the whole cluster before its diagnostics can be read, so assertion
# messages are taken from the package's `assertions` directly.

{
  lib,
  eval,
  kixKeys,
  mkCluster,
  netpolOn,
  multiZone,
  manifests,
  ofKind,
  byName,
  evalFails,
  kixlib,
  ...
}:

let
  operandSpec = {
    endpointSelector.matchLabels.app = "operand";
    ingress = [ { fromEndpoints = [ { matchLabels.app = "operand"; } ]; } ];
  };

  # Renders a ConfigMap standing in for a custom resource, and a policy for
  # the pods an operator would create from it.
  operandPackage =
    { kix, ... }:
    {
      meta.version = "test";
      build =
        { self, scope, ... }:
        {
          cr = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "operand-cr";
          };
          peers = kix.operandPolicy {
            inherit scope;
            name = "operand-peers";
            spec = operandSpec;
          };
          root = {
            resource = self.cr;
            requires = lib.optional (self.peers != null) self.peers;
          };
        };
    };

  instance = {
    instances.app.operand.package = operandPackage;
  };

  policyIn = cluster: byName "operand-peers" (manifests cluster);

  kubevirtPackage = import ../../../packages/experimental/kubevirt;
  cdiPackage = import ../../../packages/experimental/cdi;
  ciliumPackage = import ../../../packages/experimental/cilium;
  metaLib = import ../../meta.nix { inherit lib; };

  # The real cilium package in environment mode, so policies carry the
  # rules Cilium translates intents into.
  ciliumOn = {
    cluster.roles.cni = {
      binding = "shadowable";
      provider = "cilium (environment)";
    };
    networkPolicy.enable = true;
    instances.net.cilium.package = ciliumPackage;
    instances.net.platform-cilium.package = eval.mkImport {
      roles = [ "cni" ];
      out.helmChartConfig = null;
    };
  };

  # A package's top level, as instance `<ns>/<ns>`.
  instantiate =
    package: ns:
    package {
      inherit lib;
      kix = kixlib;
      scope = {
        instanceName = ns;
        namespaceName = ns;
      };
      availability = "none";
    };
  metaOf = package: (instantiate package "test").meta;

  # The messages of the package's failed assertions for `config`, with the
  # package's own `config` module applied.
  failedMessages =
    package: ns: config:
    let
      pkg = instantiate package ns;
      evaluated =
        (lib.evalModules {
          modules = [
            { options = pkg.options; }
            pkg.config
            { inherit config; }
          ];
        }).config;
    in
    map (a: a.message) (builtins.filter (a: !a.assertion) (pkg.assertions { config = evaluated; }));

  # The cluster with `config` on the package's instance fails, and one of
  # the package's failed assertions contains `infix`.
  refusedWith =
    infix: ns: config:
    evalFails (mkVirtCluster {
      ${ns}.config = config;
    })
    && builtins.any (lib.hasInfix infix) (
      failedMessages (if ns == "kubevirt" then kubevirtPackage else cdiPackage) ns config
    );

  # A consumer whose parts are `vms`, a function of the kubevirt and cdi
  # dependencies (cdi may be null) and the consumer's scope. The first part
  # is the root.
  mkConsumer = vms: {
    meta = {
      version = "test";
      description = "kubevirt and cdi consumer";
      owner = "test";
    };
    build =
      {
        self,
        scope,
        kubevirt,
        cdi ? null,
        ...
      }:
      let
        parts = vms { inherit kubevirt cdi scope; };
      in
      parts
      // {
        root = {
          resource = self.${builtins.head (builtins.attrNames parts)};
          requires = map (n: self.${n}) (builtins.attrNames parts);
        };
      };
  };

  mkVirtCluster =
    {
      withCdi ? true,
      kubevirt ? { },
      cdi ? { },
      vms ? null,
      modules ? [ ],
    }:
    mkCluster (
      [
        {
          instances.kubevirt.kubevirt = {
            package = kubevirtPackage;
          }
          // kubevirt;
        }
      ]
      ++ lib.optional withCdi {
        instances.cdi.cdi = {
          package = cdiPackage;
        }
        // cdi;
      }
      ++ lib.optional (vms != null) { instances.vms.consumer.package = mkConsumer vms; }
      ++ modules
    );

  find =
    c: kind: name:
    byName name (ofKind kind (manifests c));
  annotationsOf = m: m.metadata.annotations or { };
  readinessOf = m: (annotationsOf m).${kixKeys.readiness} or null;
  dependsOn = m: lib.splitString "," ((annotationsOf m).${kixKeys.dependsOn} or "");
  envOf =
    c: deployment:
    builtins.listToAttrs (
      map (e: lib.nameValuePair e.name (e.value or e.valueFrom))
        (builtins.head (find c "Deployment" deployment).spec.template.spec.containers).env
    );
  outOf = c: ns: c.instances.${ns}.${ns}.raw.root.out;

  vmSpec =
    strategy:
    {
      template.spec.domain = {
        devices = { };
        resources.requests.memory = "64Mi";
      };
    }
    // strategy;

  vmWith =
    strategy:
    { kubevirt, scope, ... }:
    {
      vm = kubevirt.out.mkVirtualMachine scope {
        name = "vm";
        spec = vmSpec strategy;
        annotations.note = "kept";
      };
    };

  vmReadiness =
    strategy: readinessOf (find (mkVirtCluster { vms = vmWith strategy; }) "VirtualMachine" "vm");
  printable =
    status:
    builtins.toJSON {
      path = "/status/printableStatus";
      equals = status;
    };

  diskTemplate = {
    metadata.name = "disk";
    spec = {
      source.blank = { };
      storage.resources.requests.storage = "64Mi";
    };
  };
in
{
  # Without network policy the helper returns null and nothing renders.
  # With an enforcer the policy carries the name, the derived and
  # policy-type labels, and the spec as given.
  kubevirt-cdi-operand-policy =
    let
      off = policyIn (mkCluster [ instance ]);
      on = policyIn (mkCluster [
        instance
        netpolOn
      ]);
      labels = on.metadata.labels or { };
    in
    (
      off == null
      && on != null
      && on.kind == "CiliumNetworkPolicy"
      && on.metadata.namespace == "app"
      && labels.${kixKeys.derived} or null == "true"
      && labels.${kixKeys.policyType} or null == "operator-managed-workload"
      && on.spec == operandSpec
    )
    || throw "kix.operandPolicy: without enforcer ${builtins.toJSON off}, with enforcer ${builtins.toJSON on}";

  # A section for a direction the cluster does not enforce is dropped, and a
  # spec left with no section gives null.
  kubevirt-cdi-operand-policy-directions =
    let
      bothSpec = operandSpec // {
        egress = [ { toEndpoints = [ { matchLabels.app = "operand"; } ]; } ];
      };
      withSpec = spec: {
        instances.app.operand.package = lib.mkForce (
          { kix, ... }:
          {
            meta.version = "test";
            build =
              { self, scope, ... }:
              {
                cr = scope.mkResource {
                  apiVersion = "v1";
                  kind = "ConfigMap";
                  name = "operand-cr";
                };
                peers = kix.operandPolicy {
                  inherit scope;
                  name = "operand-peers";
                  inherit spec;
                };
                root = {
                  resource = self.cr;
                  requires = lib.optional (self.peers != null) self.peers;
                };
              };
          }
        );
      };
      policyWith =
        directions: spec:
        policyIn (mkCluster [
          instance
          netpolOn
          { networkPolicy.directions = directions; }
          (withSpec spec)
        ]);
      ingressOnly = policyWith "ingress" bothSpec;
      egressOnly = policyWith "egress" bothSpec;
      both = policyWith "both" bothSpec;
      dropped = policyWith "egress" operandSpec;
    in
    (
      ingressOnly.spec == operandSpec
      && egressOnly.spec == removeAttrs bothSpec [ "ingress" ]
      && both.spec == bothSpec
      && dropped == null
    )
    || throw "kix.operandPolicy directions: ingress ${builtins.toJSON ingressOnly}, egress ${builtins.toJSON egressOnly}, dropped ${builtins.toJSON dropped}";

  # runStrategy Always and running = true wait for Running; Halted and
  # running = false for Stopped. The caller's annotations stay.
  kubevirt-cdi-vm-readiness =
    let
      got = {
        always = vmReadiness { runStrategy = "Always"; };
        running = vmReadiness { running = true; };
        halted = vmReadiness { runStrategy = "Halted"; };
        stopped = vmReadiness { running = false; };
      };
      want = {
        always = printable "Running";
        running = printable "Running";
        halted = printable "Stopped";
        stopped = printable "Stopped";
      };
      note =
        (annotationsOf (
          find (mkVirtCluster { vms = vmWith { runStrategy = "Halted"; }; }) "VirtualMachine" "vm"
        )).note or null;
    in
    (got == want && note == "kept")
    || throw "mkVirtualMachine readiness: got ${builtins.toJSON got}, caller annotation ${builtins.toJSON note}";

  # A run strategy whose outcome depends on a user or the guest, an
  # ambiguous or missing strategy, a missing spec, and dataVolumeTemplates
  # without a cdi instance all fail the build.
  kubevirt-cdi-vm-refusals =
    let
      refused = strategy: mkVirtCluster { vms = vmWith strategy; };
      cases = {
        manual = refused { runStrategy = "Manual"; };
        once = refused { runStrategy = "Once"; };
        rerun = refused { runStrategy = "RerunOnFailure"; };
        lowercase = refused { runStrategy = "always"; };
        neither = refused { };
        both = refused {
          runStrategy = "Always";
          running = true;
        };
        noSpec = mkVirtCluster {
          vms =
            { kubevirt, scope, ... }:
            {
              vm = kubevirt.out.mkVirtualMachine scope { name = "vm"; };
            };
        };
        templatesWithoutCdi = mkVirtCluster {
          withCdi = false;
          vms = vmWith {
            runStrategy = "Always";
            dataVolumeTemplates = [ diskTemplate ];
          };
        };
      };
      notFailing = builtins.attrNames (lib.filterAttrs (_: c: !(evalFails c)) cases);
    in
    notFailing == [ ] || throw "mkVirtualMachine accepted: ${builtins.toJSON notFailing}";

  # A VM with dataVolumeTemplates waits for cdi's DataVolume CRD reference;
  # one without does not.
  kubevirt-cdi-vm-datavolume-dependency =
    let
      withTemplates = mkVirtCluster {
        vms = vmWith {
          runStrategy = "Always";
          dataVolumeTemplates = [ diskTemplate ];
        };
      };
      without = mkVirtCluster { vms = vmWith { runStrategy = "Always"; }; };
      marker = c: builtins.unsafeDiscardStringContext (outOf c "cdi").crds.DataVolume.out.identityHash;
      waits = c: builtins.elem "requires:${marker c}" (dependsOn (find c "VirtualMachine" "vm"));
    in
    (waits withTemplates && !(waits without))
    || throw "mkVirtualMachine: with templates ${
      builtins.toJSON (dependsOn (find withTemplates "VirtualMachine" "vm"))
    }, DataVolume marker ${marker withTemplates}";

  # mkDataVolume binds at once and waits for Succeeded, keeping the
  # caller's annotations.
  kubevirt-cdi-datavolume =
    let
      c = mkVirtCluster {
        vms =
          { cdi, scope, ... }:
          {
            disk = cdi.out.mkDataVolume scope {
              name = "disk";
              inherit (diskTemplate) spec;
              annotations.note = "kept";
            };
          };
      };
      got = annotationsOf (find c "DataVolume" "disk");
    in
    (
      got."cdi.kubevirt.io/storage.bind.immediate.requested" or null == "true"
      &&
        got.${kixKeys.readiness} or null == builtins.toJSON {
          path = "/status/phase";
          equals = "Succeeded";
          failed = [
            {
              path = "/status/phase";
              equals = "Failed";
              hint = "The claim behind the DataVolume was lost. Recreate the DataVolume.";
            }
          ];
        }
      && got.note or null == "kept"
    )
    || throw "mkDataVolume annotations: ${builtins.toJSON got}";

  # At `none` KubeVirt runs one virt-api and virt-controller and CDI one of
  # each operand; at `zone` KubeVirt keeps its own counts and CDI runs
  # two. Both CRs wait for phase Deployed.
  kubevirt-cdi-operand-replicas =
    let
      at =
        level:
        mkVirtCluster {
          kubevirt.availability = level;
          cdi.availability = level;
          modules = [ multiZone ];
        };
      kvSpec = c: (find c "KubeVirt" "kubevirt").spec;
      cdiInfra = c: (find c "CDI" "cdi").spec.infra;
      none = at "none";
      zone = at "zone";
      deployed = builtins.toJSON {
        path = "/status/phase";
        equals = "Deployed";
      };
    in
    (
      (kvSpec none).infra.replicas or null == 1
      && !((kvSpec zone) ? infra)
      &&
        cdiInfra none == {
          apiServerReplicas = 1;
          deploymentReplicas = 1;
          uploadProxyReplicas = 1;
        }
      &&
        cdiInfra zone == {
          apiServerReplicas = 2;
          deploymentReplicas = 2;
          uploadProxyReplicas = 2;
        }
      && readinessOf (find none "KubeVirt" "kubevirt") == deployed
      && readinessOf (find none "CDI" "cdi") == deployed
    )
    || throw "operand replicas: kubevirt none ${builtins.toJSON (kvSpec none)}, zone ${builtins.toJSON (kvSpec zone)}; cdi none ${builtins.toJSON (cdiInfra none)}, zone ${builtins.toJSON (cdiInfra zone)}";

  # extraSpec deep-merges beside the package's fields and may move
  # monitorNamespace; the paths the package owns are refused.
  kubevirt-cdi-extra-spec =
    let
      merged = mkVirtCluster {
        kubevirt.config.extraSpec = {
          monitorNamespace = "monitoring";
          configuration.developerConfiguration.featureGates = [ "Snapshot" ];
        };
        cdi.config.extraSpec.config.featureGates = [ "HonorWaitForFirstConsumer" ];
      };
      kvSpec = (find merged "KubeVirt" "kubevirt").spec;
      cdiSpec = (find merged "CDI" "cdi").spec;
      refused = {
        kvReplicas = mkVirtCluster { kubevirt.config.extraSpec.infra.replicas = 3; };
        kvTag = mkVirtCluster { kubevirt.config.extraSpec.imageTag = "v1.9.2"; };
        kvPullPolicy = mkVirtCluster { kubevirt.config.extraSpec.imagePullPolicy = "Always"; };
        cdiReplicas = mkVirtCluster { cdi.config.extraSpec.infra.apiServerReplicas = 3; };
        cdiInfraNull = mkVirtCluster { cdi.config.extraSpec.infra = null; };
      };
      notFailing = builtins.attrNames (lib.filterAttrs (_: c: !(evalFails c)) refused);
    in
    (
      kvSpec.monitorNamespace == "monitoring"
      && kvSpec.configuration.developerConfiguration.featureGates == [ "Snapshot" ]
      && kvSpec.imagePullPolicy == "IfNotPresent"
      && cdiSpec.config.featureGates == [ "HonorWaitForFirstConsumer" ]
      && cdiSpec.infra ? apiServerReplicas
      && notFailing == [ ]
    )
    || throw "extraSpec: kubevirt ${builtins.toJSON kvSpec}, cdi ${builtins.toJSON cdiSpec}, accepted ${builtins.toJSON notFailing}";

  # The ServiceAccount is `kubevirt-operator` for any instance name. The
  # vendored roles are bound to it through role sets named for the
  # instance; nothing binds kubevirt.io:operator.
  kubevirt-cdi-rbac =
    let
      c = mkCluster [ { instances.kv.kv.package = kubevirtPackage; } ];
      ms = manifests c;
      bindings = ofKind "ClusterRoleBinding" ms ++ ofKind "RoleBinding" ms;
      refs = map (b: "${b.kind}/${b.metadata.name}->${b.roleRef.name}") bindings;
      subjects = lib.unique (lib.concatMap (b: map (s: s.name) b.subjects) bindings);
      admin = find c "ClusterRole" "kubevirt.io:operator";
      clusterRole = find c "ClusterRole" "kv-operator";
    in
    (
      find c "ServiceAccount" "kubevirt-operator" != null
      &&
        lib.sort lib.lessThan refs == [
          "ClusterRoleBinding/kv-operator->kv-operator"
          "RoleBinding/kv-operator->kv-operator"
        ]
      && subjects == [ "kubevirt-operator" ]
      && admin.metadata.labels."rbac.authorization.k8s.io/aggregate-to-admin" or null == "true"
      && builtins.length clusterRole.rules == 139
    )
    || throw "kubevirt RBAC: bindings ${builtins.toJSON refs}, subjects ${builtins.toJSON subjects}";

  # Default images carry the release tag and digest everywhere, except
  # VIRT_OPERATOR_IMAGE, which is repo@digest, and the virt-template images,
  # which carry virt-template's own tag. Another patch tag drops every
  # digest that follows image.tag. An older minor on upstream's update path
  # is accepted, and a minor outside it fails. A moved repository moves the
  # operands and keeps their digests.
  kubevirt-cdi-images =
    let
      pinned = lib.hasInfix ":v1.9.1@sha256:";
      defaults = mkVirtCluster { };
      kvEnv = envOf defaults "kubevirt-operator";
      cdiEnv = envOf defaults "cdi-operator";
      imageVars = env: lib.filterAttrs (n: _: lib.hasSuffix "_IMAGE" n) env;
      kvOperands = removeAttrs (imageVars kvEnv) [ "VIRT_OPERATOR_IMAGE" ];
      extraImages = (outOf defaults "kubevirt").extraImages ++ (outOf defaults "cdi").extraImages;

      patch = mkVirtCluster { kubevirt.config.image.tag = "v1.9.2"; };
      patchEnv = envOf patch "kubevirt-operator";
      # An older step of upstream's update path is accepted for walking up.
      walkUpEnv = envOf (mkVirtCluster { kubevirt.config.image.tag = "v1.6.6"; }) "kubevirt-operator";
      templateVars = [
        "VIRT_TEMPLATE_APISERVER_IMAGE"
        "VIRT_TEMPLATE_CONTROLLER_IMAGE"
      ];

      moved = mkVirtCluster {
        kubevirt.config.image.repository = "registry.example/mirror/virt-operator";
      };
      movedEnv = envOf moved "kubevirt-operator";

      releaseMessage = "kubevirt/{crds,rbac} are vendored from v1.9.1";
      refused = {
        older = refusedWith releaseMessage "kubevirt" { image.tag = "v1.4.1"; };
        newer = refusedWith releaseMessage "kubevirt" { image.tag = "v1.10.0"; };
        latest = refusedWith releaseMessage "kubevirt" { image.tag = "latest"; };
        noV = refusedWith releaseMessage "kubevirt" { image.tag = "1.9.1"; };
        cdiMinor = refusedWith "is not a v1.66 release" "cdi" { image.tag = "v1.67.0"; };
        operandPullPolicy = refusedWith "operandImages.cdi-importer.pullPolicy" "cdi" {
          operandImages.cdi-importer.pullPolicy = "Always";
        };
      };
      notFailing = builtins.attrNames (lib.filterAttrs (_: ok: !ok) refused);
    in
    (
      builtins.length (builtins.attrNames kvOperands) == 12
      && lib.all pinned (builtins.attrValues (removeAttrs kvOperands templateVars))
      && lib.all (lib.hasInfix ":v0.2.3@sha256:") (map (n: kvOperands.${n}) templateVars)
      && lib.all (lib.hasInfix ":v1.66.1@sha256:") (builtins.attrValues (imageVars cdiEnv))
      && builtins.length extraImages == 18
      && lib.all (lib.hasInfix "@sha256:") extraImages
      &&
        kvEnv.VIRT_OPERATOR_IMAGE
        == "quay.io/kubevirt/virt-operator@sha256:a8adf7b772e9ce0bf7e2ce889910fc41ebadf552c9dbe843e9b86641e34f5df9"
      && patchEnv.VIRT_OPERATOR_IMAGE == "quay.io/kubevirt/virt-operator:v1.9.2"
      && patchEnv.VIRT_API_IMAGE == "quay.io/kubevirt/virt-api:v1.9.2"
      && lib.all (v: !(lib.hasInfix "@" v)) (
        builtins.attrValues (removeAttrs (imageVars patchEnv) templateVars)
      )
      && walkUpEnv.VIRT_OPERATOR_IMAGE == "quay.io/kubevirt/virt-operator:v1.6.6"
      && walkUpEnv.KUBEVIRT_VERSION == "v1.6.6"
      &&
        movedEnv.VIRT_HANDLER_IMAGE
        == "registry.example/mirror/virt-handler:v1.9.1@sha256:c23b635ea4aff7f0779c6c061c431da0469c7796255e6de90a5970236b5ea61b"
      && notFailing == [ ]
    )
    || throw "images: kubevirt ${builtins.toJSON kvEnv}, v1.5.1 ${builtins.toJSON patchEnv}, moved ${builtins.toJSON movedEnv}, accepted ${builtins.toJSON notFailing}";

  # A second instance of either package is refused, naming the other
  # instance. The meta check is called directly: a failed meta assertion
  # fails the cluster before its diagnostics can be read.
  kubevirt-cdi-singleton =
    let
      conflict =
        package: alias:
        map (a: a.message) (
          builtins.filter (a: !a.assertion)
            (metaLib.checkMetaStatic {
              packageMeta = metaOf package;
              instanceName = alias;
              namespaceName = alias;
              clusterConfig.k8sVersion = null;
              resolvedDepMeta = { };
              resolutionIndex.byKey.${alias} = [
                {
                  instName = alias;
                  namespace = alias;
                }
                {
                  instName = "${alias}2";
                  namespace = "${alias}2";
                }
              ];
            }).assertions
        );
      got = {
        kubevirt = conflict kubevirtPackage "kubevirt";
        cdi = conflict cdiPackage "cdi";
      };
      kv2 = mkVirtCluster { modules = [ { instances.kv2.kv2.package = kubevirtPackage; } ]; };
      # Without kubevirt, whose optional `cdi` dependency would fail first
      # on the two candidates.
      cdi2 = mkCluster [
        {
          instances.cdi.cdi.package = cdiPackage;
          instances.cdi2.cdi2.package = cdiPackage;
        }
      ];
    in
    (
      got.kubevirt == [
        "It conflicts with 'kubevirt' (cluster-wide). Conflicting instances: kubevirt2/kubevirt2"
      ]
      && got.cdi == [ "It conflicts with 'cdi' (cluster-wide). Conflicting instances: cdi2/cdi2" ]
      && evalFails kv2
      && evalFails cdi2
    )
    || throw "singleton: ${builtins.toJSON got}";

  # A cluster that declares a Kubernetes version KubeVirt does not support
  # is refused with the change record's id.
  kubevirt-k8s-range =
    let
      refusals =
        k8sVersion:
        map (a: a.message) (
          builtins.filter (a: !a.assertion)
            (metaLib.checkMetaStatic {
              packageMeta = metaOf kubevirtPackage;
              instanceName = "kubevirt";
              namespaceName = "kubevirt";
              clusterConfig = { inherit k8sVersion; };
              resolvedDepMeta = { };
              resolutionIndex.byKey = { };
            }).assertions
        );
      refused = v: builtins.any (lib.hasInfix "[K0297]") (refusals v);
    in
    (
      refused "1.33"
      && refused "1.37.0"
      && refusals "1.34" == [ ]
      && refusals "1.36.4" == [ ]
      && refusals null == [ ]
    )
    || throw "kubevirt k8s range: 1.33 ${builtins.toJSON (refusals "1.33")}, 1.37.0 ${builtins.toJSON (refusals "1.37.0")}, 1.36.4 ${builtins.toJSON (refusals "1.36.4")}";

  # The tags in crds/sources.txt and rbac/sources.txt are the package's
  # release, so the vendored CRD and roles match the default images.
  kubevirt-cdi-sources-match-release =
    let
      urls =
        file:
        builtins.filter (l: l != "" && !lib.hasPrefix "#" l) (
          map (l: builtins.head (lib.splitString " " (lib.trim l))) (
            lib.splitString "\n" (builtins.readFile file)
          )
        );
      stray =
        package: dir:
        let
          release = (metaOf package).version;
        in
        builtins.filter (u: !(lib.hasInfix "/v${release}/" u)) (
          urls (dir + "/crds/sources.txt") ++ urls (dir + "/rbac/sources.txt")
        );
      got = {
        kubevirt = stray kubevirtPackage ../../../packages/experimental/kubevirt;
        cdi = stray cdiPackage ../../../packages/experimental/cdi;
      };
    in
    got == {
      kubevirt = [ ];
      cdi = [ ];
    }
    || throw "sources.txt URLs not at the package's release: ${builtins.toJSON got}";

  # The importer policy lands in the caller's namespace under a name that
  # carries the caller's instance, so two callers in one namespace do not
  # collide. It selects the importer pods, allows DNS and the given egress,
  # and admits cdi-deployment from cdi's namespace on 8443. Without an
  # enforcer it is null.
  kubevirt-cdi-importer-policy =
    let
      importer =
        { cdi, scope, ... }:
        {
          policy = cdi.out.mkImporterPolicy scope {
            egress = [
              {
                to = "world";
                ports = [
                  {
                    port = 443;
                    protocol = "TCP";
                  }
                ];
              }
            ];
          };
        };
      consumer = {
        meta.version = "test";
        build =
          {
            self,
            scope,
            cdi,
            ...
          }:
          let
            parts = importer { inherit cdi scope; };
          in
          parts
          // {
            cm = scope.mkResource {
              apiVersion = "v1";
              kind = "ConfigMap";
              name = "${scope.instanceName}-cm";
            };
            root = {
              resource = self.cm;
              requires = lib.optional (self.policy != null) self.policy;
            };
          };
      };
      twoCallers = mkCluster [
        ciliumOn
        {
          instances.cdi.cdi.package = cdiPackage;
          instances.vms.a.package = consumer;
          instances.vms.b.package = consumer;
        }
      ];
      off = mkCluster [
        {
          instances.cdi.cdi.package = cdiPackage;
          instances.vms.a.package = consumer;
        }
      ];
      policyOf = c: name: find c "CiliumNetworkPolicy" name;
      a = policyOf twoCallers "a-cdi-importer";
      selectors = (outOf twoCallers "cdi").operandSelectors;
      ingressFrom = (builtins.head a.spec.ingress).fromEndpoints or [ ];
      egressText = builtins.toJSON a.spec.egress;
    in
    (
      a != null
      && policyOf twoCallers "b-cdi-importer" != null
      && a.metadata.namespace == "vms"
      && a.spec.endpointSelector.matchLabels == selectors.importer
      && lib.hasInfix "kube-dns" egressText
      && lib.hasInfix "world" egressText
      && lib.hasInfix "\"443\"" egressText
      &&
        ingressFrom == [
          {
            matchLabels = selectors.deployment // {
              "k8s:io.kubernetes.pod.namespace" = "cdi";
            };
          }
        ]
      && (builtins.head (builtins.head (builtins.head a.spec.ingress).toPorts).ports).port == "8443"
      && policyOf off "a-cdi-importer" == null
      &&
        selectors == {
          importer = {
            app = "containerized-data-importer";
            "cdi.kubevirt.io" = "importer";
          };
          deployment = {
            app = "containerized-data-importer";
            "cdi.kubevirt.io" = "cdi-deployment";
          };
          uploadProxy."cdi.kubevirt.io" = "cdi-uploadproxy";
          uploadServer = {
            app = "containerized-data-importer";
            "cdi.kubevirt.io" = "cdi-upload-server";
          };
          cloner = {
            app = "containerized-data-importer";
            "cdi.kubevirt.io" = "cdi-clone-source";
          };
        }
    )
    || throw "mkImporterPolicy: ${builtins.toJSON a}, selectors ${builtins.toJSON selectors}";

  # A host-assisted clone from `golden` into `vms`: the upload server policy
  # in `vms` admits cdi-uploadproxy and the cloner pods of `golden` on 8443,
  # and the cloner policy in `golden` sends to the upload server pods of
  # `vms` and admits cdi-deployment. Without an enforcer both are null.
  kubevirt-cdi-clone-and-upload-policies =
    let
      consumer = build: {
        meta.version = "test";
        build =
          {
            self,
            scope,
            cdi,
            ...
          }:
          {
            policy = build cdi scope;
            cm = scope.mkResource {
              apiVersion = "v1";
              kind = "ConfigMap";
              name = "${scope.instanceName}-cm";
            };
            root = {
              resource = self.cm;
              requires = lib.optional (self.policy != null) self.policy;
            };
          };
      };
      target = consumer (
        cdi: scope: cdi.out.mkUploadServerPolicy scope { cloneSourceNamespaces = [ "golden" ]; }
      );
      source = consumer (cdi: scope: cdi.out.mkClonerPolicy scope { targetNamespaces = [ "vms" ]; });
      instances = {
        instances.cdi.cdi.package = cdiPackage;
        instances.vms.disk.package = target;
        instances.golden.image.package = source;
      };
      on = mkCluster [
        ciliumOn
        instances
      ];
      off = mkCluster [ instances ];
      selectors = (outOf on "cdi").operandSelectors;
      withNs = sel: ns: sel // { "k8s:io.kubernetes.pod.namespace" = ns; };
      upload = find on "CiliumNetworkPolicy" "disk-cdi-upload-server";
      clonerPolicy = find on "CiliumNetworkPolicy" "image-cdi-cloner";
      fromOf = p: map (r: r.fromEndpoints) p.spec.ingress;
      portsOf = rule: map (p: p.port) (builtins.head rule.toPorts).ports;
      clonerEgressText = builtins.toJSON clonerPolicy.spec.egress;
    in
    (
      upload.metadata.namespace == "vms"
      && upload.spec.endpointSelector.matchLabels == selectors.uploadServer
      &&
        fromOf upload == [
          [ { matchLabels = withNs selectors.uploadProxy "cdi"; } ]
          [ { matchLabels = withNs selectors.cloner "golden"; } ]
        ]
      &&
        map portsOf upload.spec.ingress == [
          [ "8443" ]
          [ "8443" ]
        ]
      && !(upload.spec ? egress)
      && clonerPolicy.metadata.namespace == "golden"
      && clonerPolicy.spec.endpointSelector.matchLabels == selectors.cloner
      && lib.hasInfix "kube-dns" clonerEgressText
      && lib.hasInfix (builtins.toJSON (withNs selectors.uploadServer "vms")) clonerEgressText
      && fromOf clonerPolicy == [ [ { matchLabels = withNs selectors.deployment "cdi"; } ] ]
      && find off "CiliumNetworkPolicy" "disk-cdi-upload-server" == null
      && find off "CiliumNetworkPolicy" "image-cdi-cloner" == null
    )
    || throw "clone and upload policies: ${builtins.toJSON { inherit upload clonerPolicy; }}";

  # A priorityClass dependency names the class in the CDI resource, orders
  # the resource after the class, and locks the field; without one the field
  # is unset.
  kubevirt-cdi-cdi-priority-class =
    let
      classPackage = {
        meta.version = "test";
        build =
          { self, scope, ... }:
          {
            class = scope.mkClusterResource {
              apiVersion = "scheduling.k8s.io/v1";
              kind = "PriorityClass";
              name = "virt-infra";
              extra.value = 1000;
            };
            root = self.class;
          };
      };
      withClass =
        extraSpec:
        mkVirtCluster {
          withCdi = false;
          modules = [
            (
              { ref, ... }:
              {
                instances.cdi.cdi = {
                  package = cdiPackage;
                  deps.priorityClass = ref.cdi.virt-infra;
                  config.extraSpec = extraSpec;
                };
                instances.cdi.virt-infra.package = classPackage;
              }
            )
          ];
        };
      spec = c: (find c "CDI" "cdi").spec;
      classHash =
        builtins.unsafeDiscardStringContext
          (withClass { }).instances.cdi.virt-infra.raw.class.out.identityHash;
    in
    (
      (spec (withClass { })).priorityClass or null == "virt-infra"
      && builtins.elem classHash (dependsOn (find (withClass { }) "CDI" "cdi"))
      && !((spec (mkVirtCluster { })) ? priorityClass)
      && evalFails (withClass {
        priorityClass = "other";
      })
    )
    || throw "CDI priorityClass: ${builtins.toJSON (spec (withClass { }))}";

  # With an enforcer, each operand gets its policy; without one, none
  # renders. The virt-template pods get theirs unless the Template gate is
  # disabled.
  kubevirt-cdi-operand-policies =
    let
      names = [
        "kubevirt-virt-api"
        "kubevirt-virt-controller"
        "kubevirt-virt-handler"
        "kubevirt-strategy-dumper"
        "kubevirt-virt-exportproxy"
        "kubevirt-virt-template-apiserver"
        "kubevirt-virt-template-controller"
        "cdi-cdi-apiserver"
        "cdi-cdi-deployment"
        "cdi-cdi-uploadproxy"
      ];
      on = mkVirtCluster { modules = [ netpolOn ]; };
      off = mkVirtCluster { };
      noTemplate = mkVirtCluster {
        kubevirt.config.extraSpec.configuration.developerConfiguration.disabledFeatureGates = [
          "Template"
        ];
        modules = [ netpolOn ];
      };
      templateOff = mkVirtCluster {
        kubevirt.config.extraSpec.configuration.virtTemplateDeployment.enabled = false;
        modules = [ netpolOn ];
      };
      # The test enforcer's mkEndpointSelector writes `matchLabels` at the
      # top of the spec.
      selectorOf = c: n: (find c "CiliumNetworkPolicy" n).spec.matchLabels or null;
      missing = builtins.filter (n: find on "CiliumNetworkPolicy" n == null) names;
      present = builtins.filter (n: find off "CiliumNetworkPolicy" n != null) names;
    in
    (
      missing == [ ]
      && present == [ ]
      && selectorOf on "kubevirt-virt-exportproxy" == { "kubevirt.io" = "virt-exportproxy"; }
      &&
        selectorOf on "kubevirt-virt-template-apiserver" == {
          "app.kubernetes.io/name" = "virt-template";
          control-plane = "apiserver";
        }
      && find noTemplate "CiliumNetworkPolicy" "kubevirt-virt-template-apiserver" == null
      && find templateOff "CiliumNetworkPolicy" "kubevirt-virt-template-controller" == null
      && selectorOf on "kubevirt-virt-handler" == { "kubevirt.io" = "virt-handler"; }
      &&
        selectorOf on "cdi-cdi-deployment" == {
          app = "containerized-data-importer";
          "cdi.kubevirt.io" = "cdi-deployment";
        }
    )
    || throw "operand policies: missing with enforcer ${builtins.toJSON missing}, present without ${builtins.toJSON present}";
}

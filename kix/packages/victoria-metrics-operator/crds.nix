# VictoriaMetrics Operator CRD definitions.
#
# Two families:
#   VM-native CRDs: every kind in ./kinds.nix, derived from that table so
#     the set stays complete: the operator crashes at startup if any kind
#     it indexes is missing (see the invariant note in kinds.nix; enforced
#     below with an eval-time throw).
#   prometheus-operator compat CRDs: ServiceMonitor, PodMonitor,
#     PrometheusRule, Probe (monitoring.coreos.com). CRDs only, no
#     prometheus-operator controller: the VM operator's built-in converter
#     watches these and materializes VM equivalents, so existing kix.monitor
#     callers and app-package ServiceMonitors work unchanged. On a cluster
#     that already has them, `prometheusOperatorCRDs = "reference"` waits
#     for the real ones instead of declaring a second opinion.
#
# VMSingle / VMAuth and the logs/traces kinds are still not shipped. The
# operator only gates on the indexed set; add the rest when a consumer
# appears (v2_discussions/133).

{
  self,
  config,
  scope,
  lib,
  kix,
  ...
}:
let
  vmGroup = "operator.victoriametrics.com";
  promGroup = "monitoring.coreos.com";
  inherit (import ./kinds.nix) vmCrdDefs indexedKinds promCompatDefs;

  # ── Compile-time guard for the runtime invariant (kinds.nix) ─────────
  shippedKinds = lib.mapAttrsToList (_: def: def.kind) vmCrdDefs;
  missingIndexed = builtins.filter (k: !(builtins.elem k shippedKinds)) indexedKinds;
  guard =
    if missingIndexed == [ ] then
      null
    else
      throw (
        "victoria-metrics-operator: kinds.nix no longer covers the operator's "
        + "startup indexer set. Missing: ${builtins.concatStringsSep ", " missingIndexed}. "
        + "The operator crashes at startup (\"cannot register status condition "
        + "indexers\") when any of these CRDs is absent; restore them in kinds.nix."
      );

  labels = {
    "app.kubernetes.io/part-of" = "victoria-metrics-operator";
    "app.kubernetes.io/version" = config.image.tag;
  };

  annotations = {
    "operator.victoriametrics.com/version" = lib.removePrefix "v" config.image.tag;
  };

  ageColumn = [
    {
      jsonPath = ".metadata.creationTimestamp";
      name = "Age";
      type = "date";
    }
  ];

  mkVMOperatorCRD =
    attrs: scope.mkCRD (attrs |> scope.crd.withLabels labels |> scope.crd.withAnnotations annotations);

  # Per-kind extras merged onto the table-derived base.
  #
  # factBehavior: kinds whose operator-created operand pods dial endpoints
  # embedded in the CR spec declare terminate + the operand podSelector so
  # netpol opens egress for the operands, not for whoever references the CR:
  #   VMAgent         remoteWrite[].url
  #   VMAlert         datasource.url, remoteWrite.url, remoteRead.url,
  #                   notifier[].url
  #   VMAlertmanager  receiver endpoints carried in the routing config
  # VMCluster carries no external endpoints (vminsert/vmselect/vmstorage
  # only dial each other, operator-wired; the doc 96 blindspot): explicit
  # conduct so a fact flowing through the CR never warns as undeclared.
  operandFactBehavior = component: {
    endpoint = "terminate";
    podSelector = cr: {
      "app.kubernetes.io/name" = component;
      "app.kubernetes.io/instance" = cr.metadata.name;
    };
  };

  # Compute the least a VictoriaMetrics app uses. Uses `hpa.minReplicas`
  # (default 1) when an HPA is configured, or `replicaCount` (default 1)
  # otherwise. Each pod has the main `container`, sized by `app.resources`
  # under its entry in `app.containers`, and every other `app.containers`
  # entry, which the operator adds as it is. With a VPA, which can lower
  # requests, only pods are counted. Operator-sized sidecars
  # (`config-reloader`, `vmbackuper`) are left out. The operator makes one
  # Service per app, and one claim per pod when `storage.volumeClaimTemplate`
  # is set without `storage.emptyDir`.
  replicasOf =
    app: if (app.hpa or null) != null then app.hpa.minReplicas or 1 else app.replicaCount or 1;
  appUse =
    container: pods: app:
    let
      patches = app.containers or [ ];
      patch = lib.findFirst (c: (c.name or null) == container) { } patches;
      extra = builtins.filter (
        c:
        !(builtins.elem (c.name or null) [
          container
          "config-reloader"
          "vmbackuper"
        ])
      ) patches;
      storage = app.storage or { };
      claim = if storage ? emptyDir then null else storage.volumeClaimTemplate or null;
    in
    kix.usage.add (
      [
        (kix.usage.times pods (
          if (app.vpa or null) != null then
            { pods = 1; }
          else
            kix.usage.ofPod (
              [ { resources = lib.recursiveUpdate (app.resources or { }) (patch.resources or { }); } ] ++ extra
            )
        ))
        { services = 1; }
      ]
      ++ lib.optional (claim != null) (
        kix.usage.times pods {
          persistentvolumeclaims = 1;
          "requests.storage" = claim.spec.resources.requests.storage or null;
        }
      )
    );
  unlessPaused = cr: use: if cr.spec.paused or false then { } else use;
  singleApp = container: cr: unlessPaused cr (appUse container (replicasOf cr.spec) cr.spec);

  kindExtras = {
    VMCluster = {
      # Count each configured component (`vmstorage`, `vmselect`, and
      # `vminsert`), omitting the optional `requestsLoadBalancer`.
      usesAtLeast =
        cr:
        unlessPaused cr (
          kix.usage.add (
            builtins.concatMap
              (
                name:
                let
                  app = cr.spec.${name} or null;
                in
                lib.optional (app != null) (appUse name (replicasOf app) app)
              )
              [
                "vmstorage"
                "vmselect"
                "vminsert"
              ]
          )
        );
      factBehavior.endpoint = "conduct";
      printerColumns = [
        {
          jsonPath = ".spec.retentionPeriod";
          name = "Retention";
          type = "string";
        }
        {
          jsonPath = ".status.updateStatus";
          name = "Status";
          type = "string";
        }
      ]
      ++ ageColumn;
    };
    VMAgent = {
      factBehavior = operandFactBehavior "vmagent";
      # Count `replicaCount` pods per shard (`shardCount`, default 1, or
      # `hpa.minReplicas` when an HPA scales the shards). Skip
      # `daemonSetMode` because the pod count depends on cluster nodes.
      # `statefulStorage` claims are not counted.
      usesAtLeast =
        cr:
        let
          spec = cr.spec or { };
          shards =
            if (spec.hpa or null) != null then spec.hpa.minReplicas or 1 else lib.max 1 (spec.shardCount or 1);
        in
        if spec.daemonSetMode or false then
          { }
        else
          unlessPaused cr (appUse "vmagent" ((spec.replicaCount or 1) * shards) spec);
    };
    VMAlert = {
      factBehavior = operandFactBehavior "vmalert";
      usesAtLeast = singleApp "vmalert";
    };
    VMAlertmanager = {
      factBehavior = operandFactBehavior "vmalertmanager";
      usesAtLeast = singleApp "alertmanager";
    };
    VMSingle.usesAtLeast =
      cr:
      let
        size = cr.spec.storage.resources.requests.storage or null;
      in
      # VMSingle's `spec.storage` is a claim spec: one claim when it asks for
      # storage.
      kix.usage.add (
        [ (singleApp "vmsingle" (cr // { spec = removeAttrs (cr.spec or { }) [ "storage" ]; })) ]
        ++ lib.optional (!(cr.spec.paused or false) && size != null) {
          persistentvolumeclaims = 1;
          "requests.storage" = size;
        }
      );
    VMAuth.usesAtLeast = singleApp "vmauth";
  };

  # The operator's health convention: a VM CR is ready when
  # status.updateStatus == "operational". Its conditions are
  # consumer-prefixed, never Ready/Available, so the generic condition check
  # would wait forever. The rule rides the typed chain into every CR as the
  # `kix.run/readiness` annotation, which the kix CLI evaluates at deploy
  # time, so the CLI keeps no kind list.
  #
  # The operator reconciles operand kinds (VMCluster, VMAgent, ...) itself
  # and always writes updateStatus. It writes updateStatus on a
  # configuration kind only from a consumer that selects it: a VMAgent or
  # VMSingle for the scrape kinds, a VMAlert for VMRule, a VMAlertmanager
  # for VMAlertmanagerConfig, a VMAuth for VMUser, a VMAnomaly for
  # VMAnomalyConfig (factory/reconcile/status.go, writeAggregatedStatus, at
  # v0.74.1). With no consumer the field never appears, so those kinds are
  # ready unless a consumer rejected them (`failed`).
  #
  # The parked kinds (VTCluster, VLAgent, ...) inherit the operand rule on
  # the operator's convention alone. If the operator never writes
  # updateStatus for one, a CR of it waits until timeout. Re-verify per kind
  # when adding out.mk* builders for parked kinds.
  vmReadiness = {
    path = "/status/updateStatus";
    equals = "operational";
  };
  vmConfigReadiness = {
    path = "/status/updateStatus";
    notEquals = "failed";
  };
  configKinds = [
    "VMServiceScrape"
    "VMPodScrape"
    "VMNodeScrape"
    "VMProbe"
    "VMStaticScrape"
    "VMScrapeConfig"
    "VMRule"
    "VMAlertmanagerConfig"
    "VMUser"
    "VMAnomalyConfig"
  ];

  # ── Vendored upstream spec schemas ──────────────────────────────────
  # `fromKind` mints a stub whose spec is x-kubernetes-preserve-unknown-
  # fields, which registers the kind and validates nothing. A mistyped
  # field in a CR then reaches the operator instead of being refused at
  # apply time, and `kix deploy --dry-run` cannot see it either.
  #
  # So every kind with a consumer surface (`consumer = true` in kinds.nix:
  # the out.mk* builders and the sibling packages) carries the real
  # upstream schema, vendored under ./crds by scripts/vendor-crds.py from
  # the URL in crds/sources.txt. The indexer-floor kinds keep the stub:
  # nothing in kix writes one, and their only job is to exist.
  #
  # The file is the whole upstream CRD document; only its spec subtree is
  # read here. A missing file is an error rather than a silent fall back
  # to the stub, because the point is that consumer kinds are checked.
  vendoredSpec =
    def:
    let
      path = ./crds + "/${def.plural}.${vmGroup}.json";
    in
    if !(def.consumer or false) then
      null
    else if !builtins.pathExists path then
      throw (
        "victoria-metrics-operator: ${def.kind} has a consumer surface but no "
        + "vendored schema at crds/${def.plural}.${vmGroup}.json. Add it to "
        + "crds/sources.txt and run scripts/vendor-crds.py."
      )
    else
      (builtins.elemAt (builtins.fromJSON (builtins.readFile path)).spec.versions 0)
      .schema.openAPIV3Schema.properties.spec;

  mkVMKindCRD =
    def:
    let
      extras = kindExtras.${def.kind} or { };
      spec = vendoredSpec def;
      base =
        scope.crd.fromKind def.kind {
          spec.group = vmGroup;
          spec.names.plural = def.plural;
        }
        |> scope.crd.withVersion def.version
        |> scope.crd.withPrinterColumns (extras.printerColumns or ageColumn);
      schemed = if spec == null then base else base |> scope.crd.withSchema spec;
    in
    mkVMOperatorCRD (
      schemed
      // {
        readiness = if builtins.elem def.kind configKinds then vmConfigReadiness else vmReadiness;
      }
      // lib.optionalAttrs (extras ? factBehavior) {
        inherit (extras) factBehavior;
      }
      // lib.optionalAttrs (extras ? usesAtLeast) {
        inherit (extras) usesAtLeast;
      }
    );

  vmCrds = lib.mapAttrs (_: mkVMKindCRD) vmCrdDefs;

  # ── prometheus-operator compat CRDs (converter input) ────────────────
  # ServiceMonitor, PodMonitor, PrometheusRule, Probe. The same slim
  # schemas as prometheus-operator/crds.nix, so the converter has
  # something to watch when that package isn't installed.
  #
  # On a cluster that already runs prometheus-operator, these four names
  # are taken: the real CRDs are there at the upstream schemas, owned by
  # whatever installed them. `prometheusOperatorCRDs = "reference"` swaps
  # each declaration for an import marker that waits for the CRD instead.
  # See the option in default.nix for why there is no safe default.
  mkPromCompatCRD =
    def:
    mkVMOperatorCRD (
      scope.crd.fromKind def.kind {
        spec.group = promGroup;
        spec.names.plural = def.plural;
      }
      |> scope.crd.withVersion def.version
      |> scope.crd.withShortNames def.shortNames
      |> scope.crd.withPrinterColumns ageColumn
    );

  # No labels, annotations, short names or printer columns: this marker
  # names a CRD somebody else installed and does not get to restyle it.
  # The plural is spelled out in the table above rather than derived,
  # because `<plural>.<group>` has to match the name already on the
  # cluster exactly.
  mkPromCompatRef =
    def:
    scope.mkCRDRef {
      group = promGroup;
      inherit (def) kind plural version;
    };

  mkPromCompat =
    if config.prometheusOperatorCRDs == "reference" then mkPromCompatRef else mkPromCompatCRD;

  # A compat CRD is here when the package exposes a builder for it, or
  # when its converter is on. Deriving it this way is what stops a
  # converter ever running without its CRD (kinds.nix promCompatDefs).
  neededCompat = lib.filterAttrs (name: def: def.builder || config.convert.${name}) promCompatDefs;

  promCompatCrds = lib.mapAttrs (_: mkPromCompat) neededCompat;
in
builtins.seq guard {
  crds = vmCrds // promCompatCrds;
}

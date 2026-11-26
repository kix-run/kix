# Derive network policies for the scrape paths from each scraper to the
# targets it selects: a Prometheus server to its ServiceMonitors,
# PodMonitors, and Alertmanagers, and a VictoriaMetrics VMAgent to its
# VMServiceScrapes and VMPodScrapes.
#
# The netpol cluster processor runs this pass after all instances are built
# because scrape discovery is a cluster-wide label join. A scraper selects
# scrape objects by label and namespace selectors, while the scrape objects
# select Services and pods by label. Those selectors carry no endpoint facts
# and often cross namespaces, so per-workload edge analysis cannot see the
# connection.
#
# `scraperKinds` lists the scraper kinds. Each names the selector slots of
# the scraper (`serviceMonitor`, `podScrape`, ...), the scrape object kinds
# each slot selects, and how an unset selector reads. A VMAgent also selects
# ServiceMonitors and PodMonitors while the VictoriaMetrics operator
# converts them, which the operator's `VM_ENABLEDPROMETHEUSCONVERTER_*`
# variables decide (on when no workload in the build sets them).
#
# Scraper pods are identified by `factBehavior.podSelector` on the
# scraper's CRD. Scrape objects an operator creates for its own operands
# come from `factBehavior.selfScrapes` on the operand's CRD. Targets are
# resolved against rendered Services, ServiceRef markers, and workloads. A
# Service backed by pods outside Kix still gets a selector egress rule on
# the pod network, while a scrape object targeting an unrendered Service
# without a ServiceRef marker gets no rule.
#
# Unresolvable scrape paths include scrapers without a `podSelector`, pod
# scrape selectors that use `matchExpressions`, and named target ports that
# no rendered container declares. Under default deny these are build errors
# because the scrape traffic would be blocked. When default deny is
# disabled they are reported as warnings. Scrape sources Kix does not read
# (additional scrape configs, probes, static and node scrapes, scrape
# configs) are always warnings: their targets are free-form addresses, and
# the path may be opened outside the join, such as by a platform intent.
#
# When default deny is disabled, adding the first ingress policy to a target
# pod would block all other callers. Target ingress policies are therefore
# emitted only when another policy already isolates all of the target's pods
# for ingress.

{ lib }:

let
  kixKeys = (import ../../core/annotations.nix).keys;
  matchesSelector = (import ../../core/label-selector.nix { inherit lib; }).matches;
  core = import ../../core/default.nix { inherit lib; };
  inherit
    (import ../../eval/edges.nix {
      inherit lib;
      k8s = core;
    })
    isWorkload
    isServiceRef
    ;
  inherit (import ../../core/pod-spec.nix { inherit lib; }) podSpecOf podTemplateOf;
  inherit (import ../../core/util.nix { inherit lib; }) groupOf plain;

  monitoringGroup = "monitoring.coreos.com";
  vmGroup = "operator.victoriametrics.com";
  apiGroupOf = r: groupOf (r.rawManifest.apiVersion or "");
  isKindOf =
    group: kind: r:
    (r.kind or "") == kind && apiGroupOf r == group;

  # Strip string context from every string in a value.
  plainDeep =
    v:
    if builtins.isString v then
      builtins.unsafeDiscardStringContext v
    else if builtins.isList v then
      map plainDeep v
    else if builtins.isAttrs v then
      lib.mapAttrs (_: plainDeep) v
    else
      v;

  nsOfRaw = raw: raw.metadata.namespace or null;

  # Return true for the strings Go's strconv.ParseBool reads as true, which
  # is how the VictoriaMetrics operator reads its boolean variables.
  isGoTrue =
    v:
    builtins.elem v [
      "1"
      "t"
      "T"
      "TRUE"
      "true"
      "True"
    ];

  isNumeric = p: builtins.isInt p || (builtins.isString p && builtins.match "[0-9]+" p != null);
in
{
  # Derive `{ egressPolicies, ingressPolicies, warnings, errors }` for all
  # scrapers (Prometheus and VMAgent resources) in Kix-managed namespaces. `extraPolicies` supplies
  # additional cluster-level policies (such as platform intents) that count
  # when checking whether target pods are already isolated for ingress.
  # `errors` is populated only when `defaultDeny` is enabled.
  derive =
    {
      resources,
      nsResources,
      realNsNames,
      enforcerApi,
      enforced,
      defaultDeny,
      # The namespaces with a `<namespace>-default-deny` policy. A target in
      # another namespace gets scrape ingress only when another policy
      # already isolates all its pods, as when default deny is off.
      defaultDenyNamespaces ? realNsNames,
      extraPolicies ? [ ],
    }:
    let

      nsLabels =
        ns:
        (nsResources.${ns}.rawManifest.metadata.labels or { })
        // {
          "kubernetes.io/metadata.name" = ns;
        };

      # Collect Services with pod selectors and ServiceRef markers as
      # `{ namespace, name, labels, selector, ports }`.
      services = builtins.concatMap (
        r:
        let
          raw = r.rawManifest;
          anns = raw.metadata.annotations or { };
        in
        if (r.kind or "") == "Service" && (raw.spec.selector or { }) != { } then
          [
            {
              namespace = nsOfRaw raw;
              name = raw.metadata.name;
              labels = raw.metadata.labels or { };
              selector = raw.spec.selector;
              ports = raw.spec.ports or [ ];
            }
          ]
        else if isServiceRef r && anns ? ${kixKeys.serviceSelector} then
          [
            {
              namespace = nsOfRaw raw;
              name = anns.${kixKeys.importName};
              labels = builtins.fromJSON (anns.${kixKeys.serviceLabels} or "{}");
              selector = builtins.fromJSON anns.${kixKeys.serviceSelector};
              ports = builtins.fromJSON (anns.${kixKeys.servicePorts} or "[]");
            }
          ]
        else
          [ ]
      ) resources;

      workloads = map (
        w:
        let
          podSpec = podSpecOf w.rawManifest;
        in
        {
          namespace = nsOfRaw w.rawManifest;
          podLabels = (podTemplateOf w.rawManifest).metadata.labels or { };
          hostNetwork = podSpec.hostNetwork or false;
          namedPorts = builtins.listToAttrs (
            builtins.concatMap (
              c:
              map (cp: {
                name = cp.name;
                value = cp.containerPort;
              }) (builtins.filter (cp: cp ? name) (c.ports or [ ]))
            ) (podSpec.containers or [ ])
          );
        }
      ) (builtins.filter isWorkload resources);

      podsOf =
        namespace: podSelector:
        builtins.filter (
          w: w.namespace == namespace && matchesSelector { matchLabels = podSelector; } w.podLabels
        ) workloads;

      # Resolve a port name against the container ports of the backing workloads.
      # Multiple workloads behind one selector may map the same port name to
      # different numbers. Keep the port name unchanged when no workload in the
      # build declares it.
      resolvePort =
        backing: port:
        if isNumeric port then
          [ (toString port) ]
        else
          let
            hits = lib.unique (
              map toString (
                builtins.concatMap (w: lib.optional (w.namedPorts ? ${port}) w.namedPorts.${port}) backing
              )
            );
          in
          if hits == [ ] then [ port ] else hits;

      # Build a scrape target record for pods matching `podSelector` in
      # `namespace`. `key` forms the human-readable policy name segment, and
      # `id` deduplicates targets within a namespace.
      mkTarget =
        {
          key,
          id,
          namespace,
          podSelector,
          ports,
          protocol ? "TCP",
        }:
        let
          backing = podsOf namespace podSelector;
        in
        {
          inherit
            key
            id
            namespace
            podSelector
            ;
          ports = map (port: { inherit port protocol; }) (
            lib.unique (builtins.concatMap (resolvePort backing) ports)
          );
          # Only workloads built by Kix have known `hostNetwork` and pod labels.
          # Pods created at runtime by an operator default to the pod network
          # with an empty `podLabelSets`.
          hostNetwork = backing != [ ] && builtins.all (w: w.hostNetwork) backing;
          podLabelSets = map (w: w.podLabels) backing;
        };

      podPortOf = sp: sp.targetPort or sp.port;

      serviceTarget =
        svc: podPorts:
        mkTarget {
          key = "svc-${svc.name}";
          id = "svc/${svc.name}";
          inherit (svc) namespace;
          podSelector = svc.selector;
          ports = podPorts;
        };

      # Return the namespaces selected by a monitor's `namespaceSelector`. When
      # `any = true`, include all Kix namespaces and any external namespaces
      # referenced by ServiceRef markers.
      monitorNamespaces =
        mon:
        let
          sel = mon.spec.namespaceSelector or { };
          names = sel.matchNames or [ ];
        in
        if sel.any or false then
          lib.unique (
            map plain (
              realNsNames ++ builtins.filter (n: n != null) (map (s: s.namespace) services ++ [ (nsOfRaw mon) ])
            )
          )
        else if names != [ ] then
          names
        else
          [ (nsOfRaw mon) ];

      serviceMonitorTargets =
        mon:
        let
          namespaces = monitorNamespaces mon;
          matched = builtins.filter (
            s: builtins.elem s.namespace namespaces && matchesSelector (mon.spec.selector or { }) s.labels
          ) services;
          endpoints = mon.spec.endpoints or [ ];
          podPortsFor =
            svc:
            lib.unique (
              builtins.concatMap (
                ep:
                if ep ? port then
                  map podPortOf (builtins.filter (sp: (sp.name or null) == ep.port) svc.ports)
                else if ep ? targetPort then
                  [ ep.targetPort ]
                else
                  map podPortOf svc.ports
              ) endpoints
            );
        in
        builtins.concatMap (
          svc:
          let
            ports = podPortsFor svc;
          in
          lib.optional (ports != [ ]) (serviceTarget svc ports)
        ) matched;

      # Build scrape targets for a pod scrape object (PodMonitor or
      # VMPodScrape, which share the spec shape). Skip objects whose selector
      # uses `matchExpressions`, which `podScrapeBreakage` reports separately.
      # `idPrefix` keeps a VMPodScrape apart from a PodMonitor of one name.
      podScrapeTargets =
        idPrefix: mon:
        let
          sel = mon.spec.selector or { };
          podSelector = sel.matchLabels or { };
          monNs = plain (nsOfRaw mon);
          ports = lib.unique (
            builtins.concatMap (
              ep:
              if ep ? portNumber then
                [ ep.portNumber ]
              else if ep ? port then
                [ ep.port ]
              else
                lib.optional (ep ? targetPort) ep.targetPort
            ) (mon.spec.podMetricsEndpoints or [ ])
          );
        in
        if sel ? matchExpressions || ports == [ ] then
          [ ]
        else
          map (
            namespace:
            mkTarget {
              key = "pods-${mon.metadata.name}";
              id = "${idPrefix}/${monNs}/${mon.metadata.name}";
              inherit namespace podSelector ports;
            }
          ) (monitorNamespaces mon);

      podScrapeBreakage =
        kind: mon:
        lib.optional ((mon.spec.selector or { }) ? matchExpressions)
          "${kind} ${plain (nsOfRaw mon)}/${plain mon.metadata.name}: its selector uses matchExpressions, which Kix does not turn into a network policy selector, so no scrape policy opens its pods. Under default deny the scrape is dropped. Select the pods with matchLabels only.";

      alertmanagerTargets =
        prom:
        builtins.concatMap (
          am:
          let
            amNs = am.namespace or (nsOfRaw prom);
            svc = lib.findFirst (s: s.namespace == amNs && s.name == am.name) null services;
            svcPorts = builtins.filter (sp: (sp.name or null) == am.port || (sp.port or null) == am.port) (
              if svc == null then [ ] else svc.ports
            );
          in
          lib.optional (svc != null && svcPorts != [ ]) (serviceTarget svc (map podPortOf svcPorts))
        ) (prom.spec.alerting.alertmanagers or [ ]);

      # Return the value of environment variable `name` on every container of
      # every workload in the build that sets it.
      envValues =
        name:
        builtins.concatMap (
          w:
          builtins.concatMap (
            c: map (e: e.value or null) (builtins.filter (e: e.name == name) (c.env or [ ]))
          ) ((podSpecOf w.rawManifest).containers or [ ])
        ) (builtins.filter isWorkload resources);

      # Return true while the VictoriaMetrics operator converts the
      # prometheus-operator kind its variable suffix `env` names. The
      # operator's default is on, so a build that sets no such variable
      # converts.
      vmConverts =
        env:
        let
          values = envValues "VM_ENABLEDPROMETHEUSCONVERTER_${env}";
        in
        values == [ ] || builtins.any isGoTrue values;

      # Every scrape object in the build as
      # `{ group, kind, namespace, name, labels, targets, breakages }`.
      # `targets` and `breakages` do not depend on the scraper.
      renderedScrapeObjects =
        let
          object =
            group: kind: targetsOf: breakagesOf: r:
            let
              raw = r.rawManifest;
            in
            {
              inherit group kind;
              namespace = plain (nsOfRaw raw);
              name = plain raw.metadata.name;
              labels = raw.metadata.labels or { };
              targets = targetsOf raw;
              breakages = breakagesOf raw;
            };
          ofKind =
            group: kind: targetsOf: breakagesOf:
            map (object group kind targetsOf breakagesOf) (builtins.filter (isKindOf group kind) resources);
          noBreakage = _: [ ];
          noTargets = _: [ ];
        in
        ofKind monitoringGroup "ServiceMonitor" serviceMonitorTargets noBreakage
        ++ ofKind monitoringGroup "PodMonitor" (podScrapeTargets "pods") (podScrapeBreakage "PodMonitor")
        ++ ofKind vmGroup "VMServiceScrape" serviceMonitorTargets noBreakage
        ++ ofKind vmGroup "VMPodScrape" (podScrapeTargets "vmpodscrape") (podScrapeBreakage "VMPodScrape")
        # Kinds Kix opens no path for. A scraper that selects one is warned.
        ++ ofKind monitoringGroup "Probe" noTargets noBreakage
        ++ ofKind monitoringGroup "ScrapeConfig" noTargets noBreakage
        ++ builtins.concatMap (k: ofKind vmGroup k noTargets noBreakage) [
          "VMProbe"
          "VMStaticScrape"
          "VMNodeScrape"
          "VMScrapeConfig"
        ];

      # Scrape objects an operator creates at runtime for the pods of a
      # custom resource, declared by `factBehavior.selfScrapes` on its CRD.
      # Each entry is `{ kind, name, labels, podSelector, ports }`, where
      # `ports` are pod port numbers.
      selfScrapeObjects = builtins.concatMap (
        r:
        let
          raw = r.rawManifest;
          declared = r.factBehavior.selfScrapes or null;
          namespace = plain (nsOfRaw raw);
        in
        if declared == null || !(nsResources ? ${namespace}) then
          [ ]
        else
          map (s: {
            group = vmGroup;
            inherit (s) kind labels;
            inherit namespace;
            name = plain s.name;
            targets = [
              (mkTarget {
                key = "svc-${plain s.name}";
                id = "svc/${plain s.name}";
                inherit namespace;
                inherit (s) podSelector ports;
              })
            ];
            breakages = [ ];
          }) (declared raw)
      ) resources;

      scrapeObjects = renderedScrapeObjects ++ selfScrapeObjects;

      # Return the scrape objects of `group`/`kind`.
      objectsOf = group: kind: builtins.filter (o: o.group == group && o.kind == kind) scrapeObjects;

      # Return true when a prometheus-operator resource selects `obj` through
      # its `<slot>Selector` and `<slot>NamespaceSelector`. A null selector
      # matches nothing while `{}` matches all objects. A null namespace
      # selector matches only the scraper's namespace while `{}` matches
      # every namespace.
      prometheusSelects =
        cr: slot: obj:
        let
          sel = cr.spec."${slot}Selector" or null;
          nsSel = cr.spec."${slot}NamespaceSelector" or null;
        in
        sel != null
        && matchesSelector sel obj.labels
        && (
          if nsSel == null then
            obj.namespace == plain (nsOfRaw cr)
          else
            matchesSelector nsSel (nsLabels obj.namespace)
        );

      # Return true when a VictoriaMetrics resource selects `obj`, as the
      # operator's `k8stools.VisitSelected` does. With both selectors unset
      # it selects everything when `selectAllByDefault` is true and nothing
      # otherwise. An object selector without a namespace selector reads only
      # the scraper's namespace. A namespace selector reads the namespaces it
      # matches, and `{}` matches every namespace.
      vmSelects =
        cr: slot: obj:
        let
          sel = cr.spec."${slot}Selector" or null;
          nsSel = cr.spec."${slot}NamespaceSelector" or null;
        in
        if sel == null && nsSel == null then
          cr.spec.selectAllByDefault or false
        else
          (sel == null || matchesSelector sel obj.labels)
          && (
            if nsSel == null then
              obj.namespace == plain (nsOfRaw cr)
            else
              matchesSelector nsSel (nsLabels obj.namespace)
          );

      # Scraper kinds. `slots` maps each selector slot to the scrape object
      # kinds it selects, `unread` lists the slots whose objects Kix opens no
      # path for, and `unreadFields` the spec fields that name targets
      # directly. `stem` names the scraper in policy names.
      scraperKinds = [
        {
          group = monitoringGroup;
          kind = "Prometheus";
          stem = name: name;
          selects = prometheusSelects;
          slots = {
            serviceMonitor = [ "ServiceMonitor" ];
            podMonitor = [ "PodMonitor" ];
          };
          slotGroup = monitoringGroup;
          unread = {
            probe = [ "Probe" ];
            scrapeConfig = [ "ScrapeConfig" ];
          };
          unreadFields = [
            "additionalScrapeConfigs"
            "additionalAlertManagerConfigs"
          ];
          extraTargets = alertmanagerTargets;
        }
        {
          group = vmGroup;
          kind = "VMAgent";
          stem = name: "vmagent-${name}";
          selects = vmSelects;
          slots = {
            serviceScrape = [ "VMServiceScrape" ];
            podScrape = [ "VMPodScrape" ];
          };
          slotGroup = vmGroup;
          unread = {
            probe = [ "VMProbe" ];
            staticScrape = [ "VMStaticScrape" ];
            nodeScrape = [ "VMNodeScrape" ];
            scrapeConfig = [ "VMScrapeConfig" ];
          };
          unreadFields = [
            "inlineScrapeConfig"
            "additionalScrapeConfigs"
          ];
          extraTargets = _: [ ];
          # The prometheus-operator kinds the operator converts into each
          # slot's kind, by the suffix of its converter variable.
          converted = {
            serviceScrape = lib.optional (vmConverts "SERVICESCRAPE") "ServiceMonitor";
            podScrape = lib.optional (vmConverts "PODMONITOR") "PodMonitor";
            probe = lib.optional (vmConverts "PROBE") "Probe";
            scrapeConfig = lib.optional (vmConverts "SCRAPECONFIG") "ScrapeConfig";
          };
        }
      ];

      # Return the scrape objects a scraper of kind `sk` may select through
      # `slot`, from the slot table `table`.
      candidatesOf =
        sk: table: slot:
        builtins.concatMap (objectsOf sk.slotGroup) table.${slot}
        ++ builtins.concatMap (objectsOf monitoringGroup) (sk.converted.${slot} or [ ]);

      # Return the objects `cr` selects through the slots of `table`.
      selectedBy =
        sk: cr: table:
        builtins.concatMap (slot: builtins.filter (sk.selects cr slot) (candidatesOf sk table slot)) (
          builtins.attrNames table
        );

      scraperResources = builtins.concatMap (
        sk:
        map (r: { inherit sk r; }) (
          builtins.filter (
            r: isKindOf sk.group sk.kind r && nsResources ? ${plain (nsOfRaw r.rawManifest)}
          ) resources
        )
      ) scraperKinds;
      hasPodSelector = s: ((s.r.factBehavior or null).podSelector or null) != null;
      scrapers = builtins.filter hasPodSelector scraperResources;
      unnamedScraperBreakages = map (
        s:
        let
          inherit (s.sk) group kind;
        in
        "${kind} ${plain (nsOfRaw s.r.rawManifest)}/${plain s.r.rawManifest.metadata.name}: the ${kind} CRD declares no factBehavior.podSelector, so Kix cannot name the server pods and derives no scrape policy for them. Under default deny the server reaches no target. Set cluster.factBehavior.\"${group}/${kind}\" to { endpoint = \"terminate\"; podSelector = <the server pods' labels>; }."
      ) (builtins.filter (s: !hasPodSelector s) scraperResources);
      # Return true when a policy isolates its selected pods for ingress. This
      # includes enforcer policies with `ingress` or `ingressDeny` rules and
      # Kubernetes NetworkPolicies whose `policyTypes` include `Ingress` (the
      # default when `policyTypes` is omitted).
      isolatesIngress =
        r:
        let
          spec = r.rawManifest.spec or { };
          kind = r.kind or "";
        in
        if kind == "NetworkPolicy" && apiGroupOf r == "networking.k8s.io" then
          builtins.elem "Ingress" (spec.policyTypes or [ "Ingress" ])
        else
          builtins.elem kind (enforcerApi.policyKinds or [ ]) && (spec ? ingress || spec ? ingressDeny);
      namespacePolicies = builtins.concatMap (ns: builtins.attrValues (ns.netpols or { })) (
        builtins.attrValues nsResources
      );
      isolatingPolicies = builtins.filter isolatesIngress (
        resources ++ extraPolicies ++ namespacePolicies
      );

      # Return the pod selectors of all ingress-isolating policies that apply in
      # `namespace`, including cluster-wide policies.
      isolatingSelectorsIn =
        namespace:
        builtins.concatMap (
          p:
          let
            raw = p.rawManifest;
            policyNs = nsOfRaw raw;
            selector = raw.spec.endpointSelector or raw.spec.podSelector or null;
          in
          lib.optional (selector != null && (policyNs == null || plain policyNs == plain namespace)) selector
        ) isolatingPolicies;
      # Add Cilium's namespace label so cluster-wide policy selectors can match
      # on `k8s:io.kubernetes.pod.namespace`.
      withNamespace =
        namespace: labels: labels // { "k8s:io.kubernetes.pod.namespace" = plain namespace; };

      # Return true when `selector` matches `labels` and only inspects keys
      # present in `labels`, guaranteeing that any pod carrying `labels` matches.
      selectorImplied =
        selector: labels:
        builtins.all (k: labels ? ${k}) (
          builtins.attrNames (selector.matchLabels or { })
          ++ map (e: e.key) (selector.matchExpressions or [ ])
        )
        && matchesSelector selector labels;

      # Return whether "all", "some", or "none" of a target's pods are already
      # isolated for ingress by another policy. For Kix-built workloads, check
      # each pod's full label set. For external pods known only by `podSelector`,
      # treat them as "all" only when `podSelector` implies the policy selector,
      # and as "some" when the policy selector could depend on labels outside
      # `podSelector`.
      isolationOf =
        t:
        let
          selectors = isolatingSelectorsIn t.namespace;
          isolated =
            labels: builtins.any (sel: matchesSelector sel (withNamespace t.namespace labels)) selectors;
          count = builtins.length (builtins.filter isolated t.podLabelSets);
          selectorLabels = withNamespace t.namespace t.podSelector;
        in
        if t.podLabelSets == [ ] then
          if builtins.any (sel: selectorImplied sel selectorLabels) selectors then
            "all"
          else if isolated t.podSelector then
            "some"
          else
            "none"
        else if count == 0 then
          "none"
        else if count == builtins.length t.podLabelSets then
          "all"
        else
          "some";

      perScraper =
        { sk, r }:
        let
          prom = r.rawManifest;
          promNs = plain (nsOfRaw prom);
          promName = plain prom.metadata.name;
          who = "${sk.kind} ${promNs}/${promName}";
          # Return a warning about this scraper as a record whose `object` and
          # `instance` name the scraper and the instance that built it.
          aboutScraper = message: {
            object = {
              inherit (sk) kind;
              namespace = promNs;
              name = promName;
            };
            instance = r._builtBy or null;
            inherit message;
          };
          stem = sk.stem promName;
          podSelectorDecl = r.factBehavior.podSelector;
          scraperSelector =
            if builtins.isFunction podSelectorDecl then podSelectorDecl prom else podSelectorDecl;

          selected = selectedBy sk prom sk.slots;

          rawTargets = builtins.concatMap (o: o.targets) selected ++ sk.extraTargets prom;

          unreadObjects = selectedBy sk prom sk.unread;
          unreadFields = builtins.filter (f: (prom.spec.${f} or null) != null) sk.unreadFields;
          unreadWarnings =
            map (
              o:
              aboutScraper "${who} selects ${o.kind} ${o.namespace}/${o.name}, whose targets Kix does not read, so no network policy opens them. Under an enforcer the scrape is dropped unless a policy outside the scrape join admits it, such as a networkPolicy.platformIntents entry."
            ) unreadObjects
            ++ map (
              f:
              aboutScraper "${who} sets spec.${f}, whose targets Kix does not read, so no network policy opens them. Under an enforcer that traffic is dropped unless a policy outside the scrape join admits it, such as a networkPolicy.platformIntents entry."
            ) unreadFields;

          # Two monitors on one Service are one target with the union of
          # their ports.
          targets = builtins.attrValues (
            builtins.foldl' (
              acc: t:
              let
                id = "${plain t.namespace}/${t.id}";
              in
              acc
              // {
                ${id} =
                  if acc ? ${id} then acc.${id} // { ports = lib.unique (acc.${id}.ports ++ t.ports); } else t;
              }
            ) { } rawTargets
          );

          # Cilium drops egress on a named port, and a rule without ports
          # admits every port, so an egress rule carries only the numeric
          # ports and a target with none gets no rule.
          numericPorts = t: builtins.filter (p: isNumeric p.port) t.ports;
          namedPorts = t: builtins.filter (p: !isNumeric p.port) t.ports;

          # The rules carry no string context, so the policy does not wait
          # for every target to be deployed. A scraper that is up before
          # its last target can scrape the others, and admitting traffic to
          # pods that do not exist yet opens nothing.
          egressRules = plainDeep (
            lib.unique (
              builtins.concatMap (
                t:
                if numericPorts t == [ ] then
                  [ ]
                else if t.hostNetwork then
                  [ (enforcerApi.mkHostNetworkEgressRule { ports = numericPorts t; }) ]
                else
                  [
                    (enforcerApi.mkServiceEgressRule {
                      selector = t.podSelector;
                      namespace = t.namespace;
                      sourceNamespace = promNs;
                      ports = numericPorts t;
                    })
                  ]
              ) targets
            )
          );

          namedPortBreakage =
            t:
            let
              target = "${who}: target ${plain t.namespace}/${plain t.key}";
              names = lib.concatMapStringsSep ", " (p: toString p.port) (namedPorts t);
              fix = "Give the monitor endpoint a port number: a numeric targetPort on the Service or ServiceMonitor endpoint, or portNumber on a PodMonitor endpoint.";
            in
            if t.hostNetwork then
              "${target} runs on the host network and its port ${names} is a name no Kix container declares, so Kix adds no scrape rule for it. The server reaches it only while its API server rule admits every port on the nodes. ${fix}"
            else
              "${target} has port ${names}, a name no Kix container declares, and Cilium drops egress on a named port, so Kix adds no scrape rule for it. Under default deny the scrape is dropped. ${fix}";

          egressPolicy = enforcerApi.mkPolicy {
            mkResource = core.mkResource;
            selector = scraperSelector;
            egress = egressRules;
            extraArgs = {
              name = "${stem}-scrape-egress";
              namespace = nsResources.${promNs};
              labels = {
                ${kixKeys.derived} = "true";
                ${kixKeys.policyType} = "scrape";
                "app.kubernetes.io/managed-by" = "kix";
              };
            };
          };

          # Host-network pods are outside Cilium's endpoint policy, so they
          # get no ingress rule.
          ingressCandidates = builtins.filter (
            t: !t.hostNetwork && nsResources ? ${plain t.namespace}
          ) targets;
          deniedIn = t: defaultDeny && builtins.elem (plain t.namespace) defaultDenyNamespaces;
          ingressTargets = builtins.filter (t: deniedIn t || isolationOf t == "all") ingressCandidates;
          partlyIsolatedTargets = builtins.filter (
            t: !(deniedIn t) && isolationOf t == "some"
          ) ingressCandidates;

          # Build a unique ingress policy name for a scrape target, appending a
          # hash to disambiguate colliding namespace, Prometheus, and monitor
          # names.
          ingressPolicyName =
            t:
            let
              hash = builtins.substring 0 8 (
                builtins.hashString "sha256" "${promNs}/${stem}/${plain t.namespace}/${plain t.id}"
              );
            in
            "${promNs}-${stem}-scrape-${plain t.key}-${hash}";

          ingressPolicy =
            t:
            enforcerApi.mkPolicy {
              mkResource = core.mkResource;
              selector = t.podSelector;
              ingress = [
                (enforcerApi.mkCallerIngressRule {
                  callerSelector = scraperSelector;
                  callerNamespace = promNs;
                  inherit (t) ports;
                })
              ];
              extraArgs = {
                name = ingressPolicyName t;
                namespace = nsResources.${plain t.namespace};
                labels = {
                  ${kixKeys.derived} = "true";
                  ${kixKeys.policyType} = "scrape";
                  "app.kubernetes.io/managed-by" = "kix";
                };
              };
            };
        in
        {
          egressPolicies = lib.optional (enforced.egress && egressRules != [ ]) egressPolicy;
          ingressPolicies = lib.optionals enforced.ingress (map ingressPolicy ingressTargets);
          warnings = lib.optionals enforced.ingress (
            map (
              t:
              aboutScraper "${who} scrapes target ${plain t.namespace}/${plain t.key}. Another ingress policy ${
                if t.podLabelSets == [ ] then
                  "may isolate only some of the target's pods, because that policy matches labels outside the target's selector and Kix does not know the full labels of pods it did not build"
                else
                  "isolates only some of the target's pods"
              }. ${
                if defaultDeny then
                  "Namespace ${plain t.namespace} has no default-deny policy because it contains no deployed instances or is listed in `networkPolicy.platformNamespaces`. Kix skipped generating a scrape ingress policy to avoid isolating the remaining pods, so the monitoring server cannot scrape the isolated pods. Select all of the target's pods in that ingress policy, or add a default-deny policy to ${plain t.namespace} (declare `namespaces.${plain t.namespace} = { };` and remove `${plain t.namespace}` from `networkPolicy.platformNamespaces` if present)"
                else
                  "With `networkPolicy.defaultDeny = false`, Kix skipped generating a scrape ingress policy to avoid isolating the remaining pods, so the monitoring server cannot scrape the isolated pods. Select all of the target's pods in that ingress policy, or set `networkPolicy.defaultDeny = true`"
              }."
            ) partlyIsolatedTargets
          );
          inherit unreadWarnings;
          breakages =
            builtins.concatMap (o: o.breakages) selected
            ++ lib.optionals enforced.egress (
              map namedPortBreakage (builtins.filter (t: namedPorts t != [ ]) targets)
            );
        };

      results = map perScraper scrapers;
      breakages = lib.unique (unnamedScraperBreakages ++ builtins.concatMap (r: r.breakages) results);
    in
    {
      egressPolicies = builtins.concatMap (r: r.egressPolicies) results;
      ingressPolicies = builtins.concatMap (r: r.ingressPolicies) results;
      warnings = lib.unique (
        builtins.concatMap (r: r.warnings ++ r.unreadWarnings) results
        ++ lib.optionals (!defaultDeny) breakages
      );
      errors = lib.optionals defaultDeny breakages;
    };
}

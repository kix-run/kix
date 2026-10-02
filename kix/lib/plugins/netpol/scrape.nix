# Scrape policies: the network path from each Prometheus server to the
# targets of the ServiceMonitors, PodMonitors, and Alertmanagers it selects.
#
# The path is a cluster-wide label join, so the netpol cluster processor runs
# it after every instance is built. A Prometheus CR selects monitors by
# `serviceMonitorSelector`/`podMonitorSelector` and their namespace selectors;
# a ServiceMonitor selects Services by label, and a PodMonitor selects pods.
# None of these carry endpoint facts, and the scraper pods usually run in a
# different namespace from the monitor, so the per-workload derivation cannot
# see the connection.
#
# The scraper pods are named by the Prometheus CRD's `factBehavior.podSelector`,
# which the prometheus-operator package declares. Targets are resolved against
# the resources Kix built: Services, ServiceRef markers, and workloads (pod
# labels, named container ports, `hostNetwork`). A Service over pods Kix did
# not build gets an egress rule for its selector, which does not reach pods on
# the host network. A monitor whose Service Kix does not render (the kubelet)
# gets no rule.
#
# Some scrape paths cannot be derived: a Prometheus CR whose CRD names no
# server pods, a PodMonitor selector with matchExpressions, and a target port
# that is a name no Kix container declares (an egress rule needs a number).
# These are `breakages`: errors under default deny, where the scrape would
# otherwise be dropped, and warnings without it.
#
# Without default deny, a target ingress policy would be the first ingress
# policy on its pods and close them to every other client. Target ingress is
# then emitted only for targets whose pods another policy already isolates
# for ingress.

{ lib }:

let
  kixKeys = (import ../../core/annotations.nix).keys;
  core = import ../../core/default.nix { inherit lib; };
  inherit (import ../../eval/edges.nix { k8s = core; }) isWorkload isServiceRef;

  monitoringGroup = "monitoring.coreos.com";
  groupOf = r: lib.head (lib.splitString "/" (r.rawManifest.apiVersion or ""));
  isMonitoringKind = kind: r: (r.kind or "") == kind && groupOf r == monitoringGroup;

  # Attribute names and object names cannot use a value's string context.
  plain = s: builtins.unsafeDiscardStringContext (toString s);

  nsOfRaw = raw: raw.metadata.namespace or null;

  # metav1.LabelSelector: every matchLabels pair and every matchExpression
  # must hold. `{}` matches everything.
  matchesSelector =
    selector: labels:
    let
      matchLabels = selector.matchLabels or { };
      exprHolds =
        e:
        let
          has = labels ? ${e.key};
          values = e.values or [ ];
        in
        if e.operator == "In" then
          has && builtins.elem labels.${e.key} values
        else if e.operator == "NotIn" then
          !has || !(builtins.elem labels.${e.key} values)
        else if e.operator == "Exists" then
          has
        else if e.operator == "DoesNotExist" then
          !has
        else
          throw "kix netpol: label selector operator '${toString e.operator}' is not one of In, NotIn, Exists, DoesNotExist";
    in
    builtins.all (k: (labels.${k} or null) == matchLabels.${k}) (builtins.attrNames matchLabels)
    && builtins.all exprHolds (selector.matchExpressions or [ ]);

  isNumeric = p: builtins.isInt p || (builtins.isString p && builtins.match "[0-9]+" p != null);
in
{
  inherit matchesSelector;

  # Returns { egressPolicies, ingressPolicies, warnings, errors }.
  # `resources` are the sealed resources of every active instance;
  # `nsResources` maps each Kix namespace to its Namespace resource, and
  # `realNsNames` lists the ones default deny covers. Policies land only in
  # Kix namespaces. `enforced` is `{ ingress; egress; }`, the directions the
  # cluster enforces. `extraPolicies` are policies the cluster processor
  # emits itself (platform intents), which count when deciding whether a
  # target is already isolated. `errors` is non-empty only under
  # `defaultDeny`.
  derive =
    {
      resources,
      nsResources,
      realNsNames,
      enforcerApi,
      enforced,
      defaultDeny,
      extraPolicies ? [ ],
    }:
    let

      nsLabels =
        ns:
        (nsResources.${ns}.rawManifest.metadata.labels or { })
        // {
          "kubernetes.io/metadata.name" = ns;
        };

      # Services and ServiceRef markers, as { namespace, name, labels,
      # selector, ports }. A Service without a selector has no pods Kix can
      # name, so it is left out.
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
          podSpec = w.rawManifest.spec.template.spec or { };
        in
        {
          namespace = nsOfRaw w.rawManifest;
          podLabels = w.rawManifest.spec.template.metadata.labels or { };
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

      # A port name resolves through the container ports of the Kix workloads
      # behind the selector, to every number they declare it with: a Service
      # targetPort name resolves per pod, so two workloads may give it two
      # numbers. It stays a name when no workload declares it, which is the
      # case for pods an operator creates.
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

      # One target: pods by selector in a namespace, with the pod ports a
      # scrape reaches. `key` is the readable part of the policy name; `id`
      # is unique per target within a namespace and keys deduplication.
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
          # Kix knows the pods' network and labels only for pods it built;
          # unknown pods are taken to be on the pod network, and
          # `podLabelSets` is empty for them.
          hostNetwork = backing != [ ] && builtins.all (w: w.hostNetwork) backing;
          podLabelSets = map (w: w.podLabels) backing;
        };

      # Pod port of a Service port, before name resolution.
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

      # Namespaces a monitor looks in: `any`, `matchNames`, or its own. `any`
      # covers every Kix namespace, including ones that hold only custom
      # resources whose operator creates the pods, and the namespaces of
      # ServiceRef markers outside Kix.
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

      # A PodMonitor names pods directly. Only `matchLabels` becomes a policy
      # selector, so a selector with matchExpressions is skipped and reported
      # by `podMonitorBreakage`.
      podMonitorTargets =
        mon:
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
              id = "pods/${monNs}/${mon.metadata.name}";
              inherit namespace podSelector ports;
            }
          ) (monitorNamespaces mon);

      podMonitorBreakage =
        mon:
        lib.optional ((mon.spec.selector or { }) ? matchExpressions)
          "PodMonitor ${plain (nsOfRaw mon)}/${plain mon.metadata.name}: its selector uses matchExpressions, which Kix does not turn into a network policy selector, so no scrape policy opens its pods. Under default deny the scrape is dropped. Select the pods with matchLabels only.";

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

      monitors = {
        serviceMonitor = builtins.filter (isMonitoringKind "ServiceMonitor") resources;
        podMonitor = builtins.filter (isMonitoringKind "PodMonitor") resources;
      };

      # Prometheus selector semantics: a null monitor selector selects no
      # monitors and `{}` selects all; a null namespace selector means the
      # Prometheus's own namespace and `{}` means every namespace.
      selects =
        prom: prefix: mon:
        let
          sel = prom.spec."${prefix}Selector" or null;
          nsSel = prom.spec."${prefix}NamespaceSelector" or null;
          monNs = nsOfRaw mon;
        in
        sel != null
        && matchesSelector sel (mon.metadata.labels or { })
        && (if nsSel == null then monNs == nsOfRaw prom else matchesSelector nsSel (nsLabels monNs));

      prometheuses = builtins.filter (
        r: isMonitoringKind "Prometheus" r && nsResources ? ${plain (nsOfRaw r.rawManifest)}
      ) resources;
      hasPodSelector = r: ((r.factBehavior or null).podSelector or null) != null;
      scrapers = builtins.filter hasPodSelector prometheuses;
      unnamedScraperBreakages = map (
        r:
        "Prometheus ${plain (nsOfRaw r.rawManifest)}/${plain r.rawManifest.metadata.name}: the Prometheus CRD declares no factBehavior.podSelector, so Kix cannot name the server pods and derives no scrape policy for them. Under default deny the server reaches no target. Set cluster.factBehavior.\"monitoring.coreos.com/Prometheus\" to { endpoint = \"terminate\"; podSelector = <the server pods' labels>; }."
      ) (builtins.filter (r: !hasPodSelector r) prometheuses);

      # Policies that isolate the pods they select for ingress, for the check
      # without default deny: an enforcer policy with an ingress section, and
      # a Kubernetes NetworkPolicy whose policyTypes include Ingress (absent
      # policyTypes include it). `namespaces.<ns>.networkPolicies` reach the
      # check through `nsResources`.
      isolatesIngress =
        r:
        let
          spec = r.rawManifest.spec or { };
          kind = r.kind or "";
        in
        if kind == "NetworkPolicy" && groupOf r == "networking.k8s.io" then
          builtins.elem "Ingress" (spec.policyTypes or [ "Ingress" ])
        else
          builtins.elem kind (enforcerApi.policyKinds or [ ]) && (spec ? ingress || spec ? ingressDeny);
      namespacePolicies = builtins.concatMap (ns: builtins.attrValues (ns.netpols or { })) (
        builtins.attrValues nsResources
      );
      isolatingPolicies = builtins.filter isolatesIngress (
        resources ++ extraPolicies ++ namespacePolicies
      );

      # The pod selectors of the isolating policies that apply in a
      # namespace, and the labels they are matched against. A cluster-wide
      # policy names the namespace with Cilium's
      # `k8s:io.kubernetes.pod.namespace` label, if at all.
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
      withNamespace =
        namespace: labels: labels // { "k8s:io.kubernetes.pod.namespace" = plain namespace; };

      # A selector holds for every pod whose labels include `labels` only
      # when each key it reads is one of them and it matches them.
      selectorImplied =
        selector: labels:
        builtins.all (k: labels ? ${k}) (
          builtins.attrNames (selector.matchLabels or { })
          ++ map (e: e.key) (selector.matchExpressions or [ ])
        )
        && matchesSelector selector labels;

      # "all", "some", or "none" of the target's pods are already isolated
      # for ingress. "some" means the target ingress would isolate pods that
      # no other policy isolates. A policy selects pods by their own labels,
      # which can carry more than the target's selector, so each pod Kix
      # built behind the target is checked. Pods Kix did not build are known
      # by `podSelector` alone: a policy isolates all of them only when
      # `podSelector` implies its selector, and one that matches
      # `podSelector` without implying it (a NotIn or DoesNotExist on a key
      # outside it) may isolate only some.
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
        r:
        let
          prom = r.rawManifest;
          promNs = plain (nsOfRaw prom);
          promName = plain prom.metadata.name;
          podSelectorDecl = r.factBehavior.podSelector;
          scraperSelector =
            if builtins.isFunction podSelectorDecl then podSelectorDecl prom else podSelectorDecl;

          selectedPodMonitors = builtins.filter (
            m: selects prom "podMonitor" m.rawManifest
          ) monitors.podMonitor;

          rawTargets =
            builtins.concatMap (m: serviceMonitorTargets m.rawManifest) (
              builtins.filter (m: selects prom "serviceMonitor" m.rawManifest) monitors.serviceMonitor
            )
            ++ builtins.concatMap (m: podMonitorTargets m.rawManifest) selectedPodMonitors
            ++ alertmanagerTargets prom;

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

          egressRules = lib.unique (
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
          );

          namedPortBreakage =
            t:
            let
              target = "Prometheus ${promNs}/${promName}: target ${plain t.namespace}/${plain t.key}";
              names = lib.concatMapStringsSep ", " (p: toString p.port) (namedPorts t);
              fix = "Give the monitor endpoint a port number: a numeric targetPort on the Service or ServiceMonitor endpoint, or portNumber on a PodMonitor endpoint.";
            in
            if t.hostNetwork then
              "${target} runs on the host network and its port ${names} is a name no Kix container declares, so Kix adds no scrape rule for it. The server reaches it only while its API server rule admits every port on the nodes. ${fix}"
            else
              "${target} has port ${names}, a name no Kix container declares, and Cilium drops egress on a named port, so Kix adds no scrape rule for it. Under default deny the scrape is dropped. ${fix}";

          egressPolicy = enforcerApi.mkPolicy {
            mkResource = core.mkResource;
            extraArgs = {
              name = "${promName}-scrape-egress";
              namespace = nsResources.${promNs};
              labels = {
                ${kixKeys.derived} = "true";
                ${kixKeys.policyType} = "scrape";
                "app.kubernetes.io/managed-by" = "kix";
              };
              spec = {
                endpointSelector.matchLabels = scraperSelector;
                egress = egressRules;
              };
            };
          };

          # Host-network pods are outside Cilium's endpoint policy, so they
          # get no ingress rule.
          ingressCandidates = builtins.filter (
            t: !t.hostNetwork && nsResources ? ${plain t.namespace}
          ) targets;
          ingressTargets = builtins.filter (t: defaultDeny || isolationOf t == "all") ingressCandidates;
          partlyIsolatedTargets = lib.optionals (!defaultDeny) (
            builtins.filter (t: isolationOf t == "some") ingressCandidates
          );

          # The hash keeps names distinct where the readable parts join
          # ambiguously (Prometheus `c` in `a-b` and `b-c` in `a`) and for
          # same-named PodMonitors in different namespaces.
          ingressPolicyName =
            t:
            let
              hash = builtins.substring 0 8 (
                builtins.hashString "sha256" "${promNs}/${promName}/${plain t.namespace}/${plain t.id}"
              );
            in
            "${promNs}-${promName}-scrape-${plain t.key}-${hash}";

          ingressPolicy =
            t:
            enforcerApi.mkPolicy {
              mkResource = core.mkResource;
              extraArgs = {
                name = ingressPolicyName t;
                namespace = nsResources.${plain t.namespace};
                labels = {
                  ${kixKeys.derived} = "true";
                  ${kixKeys.policyType} = "scrape";
                  "app.kubernetes.io/managed-by" = "kix";
                };
                spec = {
                  endpointSelector.matchLabels = t.podSelector;
                  ingress = [
                    (enforcerApi.mkCallerIngressRule {
                      callerSelector = scraperSelector;
                      callerNamespace = promNs;
                      inherit (t) ports;
                    })
                  ];
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
              "Prometheus ${promNs}/${promName}: another ingress policy ${
                if t.podLabelSets == [ ] then
                  "may isolate only some of the pods behind target ${plain t.namespace}/${plain t.key}, which Kix did not build, depending on labels outside the target's selector"
                else
                  "isolates only some of the pods behind target ${plain t.namespace}/${plain t.key}"
              }. Without default deny Kix adds scrape ingress only where it can show that every pod is already isolated, so the server cannot reach the isolated pods. Select all of the target's pods in that policy, or turn on networkPolicy.defaultDeny."
            ) partlyIsolatedTargets
          );
          breakages =
            builtins.concatMap (m: podMonitorBreakage m.rawManifest) selectedPodMonitors
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
        builtins.concatMap (r: r.warnings) results ++ lib.optionals (!defaultDeny) breakages
      );
      errors = lib.optionals defaultDeny breakages;
    };
}

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
# which the prometheus-operator package declares; a Prometheus CR without one
# is skipped with a warning. Targets are resolved against the resources Kix
# built: Services, ServiceRef markers, and workloads (pod labels, named
# container ports, `hostNetwork`). A Service over pods Kix did not build gets
# an egress rule for its selector, which does not reach pods on the host
# network. A monitor whose Service Kix does not render (the kubelet) gets no
# rule.
#
# Without default deny, a target ingress policy would be the first ingress
# policy on its pods and close them to every other client. Target ingress is
# then emitted only for pods that another policy already isolates for ingress.

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

  # Returns { egressPolicies, ingressPolicies, warnings }. `resources` are
  # the sealed resources of every active instance; `nsResources` maps each
  # Kix namespace to its Namespace resource, and `realNsNames` lists the ones
  # default deny covers. Policies land only in Kix namespaces. `extraPolicies`
  # are policies the cluster processor emits itself (platform intents), which
  # count when deciding whether a target is already isolated.
  derive =
    {
      resources,
      nsResources,
      realNsNames,
      enforcerApi,
      directions,
      defaultDeny,
      extraPolicies ? [ ],
    }:
    let
      doEgress = directions == "both" || directions == "egress";
      doIngress = directions == "both" || directions == "ingress";

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
      # behind the selector. It stays a name when no workload declares it,
      # which is the case for pods an operator creates.
      resolvePort =
        backing: port:
        if isNumeric port then
          toString port
        else
          let
            hits = lib.unique (
              map toString (
                builtins.concatMap (w: lib.optional (w.namedPorts ? ${port}) w.namedPorts.${port}) backing
              )
            );
          in
          if builtins.length hits == 1 then builtins.head hits else port;

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
          ports = map (p: {
            port = resolvePort backing p;
            inherit protocol;
          }) ports;
          # Kix knows the pods' network only for pods it built; unknown pods
          # are taken to be on the pod network.
          hostNetwork = backing != [ ] && builtins.all (w: w.hostNetwork) backing;
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
      # selector, so a selector with matchExpressions is skipped (and warned
      # about by the caller).
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

      podMonitorWarning =
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
      unnamedScraperWarnings = map (
        r:
        "Prometheus ${plain (nsOfRaw r.rawManifest)}/${plain r.rawManifest.metadata.name}: the Prometheus CRD declares no factBehavior.podSelector, so Kix cannot name the server pods and derives no scrape policy for them. Under default deny the server reaches no target. Set cluster.factBehavior.\"monitoring.coreos.com/Prometheus\" to { endpoint = \"terminate\"; podSelector = <the server pods' labels>; }."
      ) (builtins.filter (r: !hasPodSelector r) prometheuses);

      # Ingress policies that already select pods, for the check without
      # default deny. A cluster-wide policy names the namespace with
      # Cilium's `k8s:io.kubernetes.pod.namespace` label, if at all.
      ingressPolicies = builtins.filter (
        r:
        builtins.elem (r.kind or "") (enforcerApi.policyKinds or [ ])
        && (
          let
            spec = r.rawManifest.spec or { };
          in
          spec ? ingress || spec ? ingressDeny
        )
      ) (resources ++ extraPolicies);
      isolatedForIngress =
        t:
        builtins.any (
          p:
          let
            raw = p.rawManifest;
            policyNs = nsOfRaw raw;
            selector = raw.spec.endpointSelector or raw.spec.podSelector or null;
          in
          selector != null
          && (policyNs == null || plain policyNs == plain t.namespace)
          && matchesSelector selector (
            t.podSelector // { "k8s:io.kubernetes.pod.namespace" = plain t.namespace; }
          )
        ) ingressPolicies;

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

          numericPorts = t: builtins.filter (p: isNumeric p.port) t.ports;
          # Cilium drops egress on a named port, so a target with a port Kix
          # could not resolve gets a rule without ports.
          egressPorts = t: if builtins.all (p: isNumeric p.port) t.ports then t.ports else [ ];

          # A host rule without ports would admit every port on every node,
          # so a host-network target without a numeric port gets no rule.
          portlessHostTargets = builtins.filter (t: t.hostNetwork && numericPorts t == [ ]) targets;

          egressRules = lib.unique (
            builtins.concatMap (
              t:
              if t.hostNetwork then
                lib.optional (numericPorts t != [ ]) (
                  enforcerApi.mkHostNetworkEgressRule { ports = numericPorts t; }
                )
              else
                [
                  (enforcerApi.mkServiceEgressRule {
                    selector = t.podSelector;
                    namespace = t.namespace;
                    sourceNamespace = promNs;
                    ports = egressPorts t;
                  })
                ]
            ) targets
          );

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
          ingressTargets = builtins.filter (
            t: !t.hostNetwork && nsResources ? ${plain t.namespace} && (defaultDeny || isolatedForIngress t)
          ) targets;

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
          egressPolicies = lib.optional (doEgress && egressRules != [ ]) egressPolicy;
          ingressPolicies = lib.optionals doIngress (map ingressPolicy ingressTargets);
          warnings =
            builtins.concatMap (m: podMonitorWarning m.rawManifest) selectedPodMonitors
            ++ lib.optionals doEgress (
              map (
                t:
                "Prometheus ${promNs}/${promName}: target ${plain t.namespace}/${plain t.key} runs on the host network and its port ${
                  lib.concatMapStringsSep ", " (p: toString p.port) t.ports
                } is a name no Kix container declares, so Kix adds no scrape rule for it. The server reaches it only while its API server rule admits every port on the nodes. Give the monitor endpoint a numeric port."
              ) portlessHostTargets
            );
        };

      results = map perScraper scrapers;
    in
    {
      egressPolicies = builtins.concatMap (r: r.egressPolicies) results;
      ingressPolicies = builtins.concatMap (r: r.ingressPolicies) results;
      warnings = lib.unique (unnamedScraperWarnings ++ builtins.concatMap (r: r.warnings) results);
    };
}

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
# is skipped. Targets are resolved against the resources Kix built: Services,
# ServiceRef markers, and workloads (pod labels, named container ports,
# `hostNetwork`). A Service over pods Kix did not build gets an egress rule for
# its selector, which does not reach pods on the host network. A monitor whose
# Service Kix does not render (the kubelet) gets no rule.

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

  # Returns { egressPolicies, ingressPolicies }. `resources` are the sealed
  # resources of every active instance; `nsResources` maps each Kix namespace
  # to its Namespace resource. Policies land only in Kix namespaces, which are
  # the namespaces default deny covers.
  derive =
    {
      resources,
      nsResources,
      enforcerApi,
      directions,
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
      # scrape reaches. `key` identifies it for naming and deduplication.
      mkTarget =
        {
          key,
          namespace,
          podSelector,
          ports,
          protocol ? "TCP",
        }:
        let
          backing = podsOf namespace podSelector;
        in
        {
          inherit key namespace podSelector;
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
          inherit (svc) namespace;
          podSelector = svc.selector;
          ports = podPorts;
        };

      # Namespaces a monitor looks in: `any`, `matchNames`, or its own.
      monitorNamespaces =
        mon:
        let
          sel = mon.spec.namespaceSelector or { };
          names = sel.matchNames or [ ];
        in
        if sel.any or false then
          lib.unique (
            builtins.filter (n: n != null) (map (s: s.namespace) services ++ map (w: w.namespace) workloads)
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

      # A PodMonitor names pods directly; only `matchLabels` can become a
      # policy selector, so a selector with matchExpressions is skipped.
      podMonitorTargets =
        mon:
        let
          sel = mon.spec.selector or { };
          podSelector = sel.matchLabels or { };
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
        if sel ? matchExpressions || podSelector == { } || ports == [ ] then
          [ ]
        else
          map (
            namespace:
            mkTarget {
              key = "pods-${mon.metadata.name}";
              inherit namespace podSelector ports;
            }
          ) (monitorNamespaces mon);

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

      scrapers = builtins.filter (
        r:
        isMonitoringKind "Prometheus" r
        && ((r.factBehavior or null).podSelector or null) != null
        && nsResources ? ${plain (nsOfRaw r.rawManifest)}
      ) resources;

      perScraper =
        r:
        let
          prom = r.rawManifest;
          promNs = plain (nsOfRaw prom);
          promName = plain prom.metadata.name;
          podSelectorDecl = r.factBehavior.podSelector;
          scraperSelector =
            if builtins.isFunction podSelectorDecl then podSelectorDecl prom else podSelectorDecl;

          rawTargets =
            builtins.concatMap (m: serviceMonitorTargets m.rawManifest) (
              builtins.filter (m: selects prom "serviceMonitor" m.rawManifest) monitors.serviceMonitor
            )
            ++ builtins.concatMap (m: podMonitorTargets m.rawManifest) (
              builtins.filter (m: selects prom "podMonitor" m.rawManifest) monitors.podMonitor
            )
            ++ alertmanagerTargets prom;

          # Two monitors on one Service are one target with the union of
          # their ports.
          targets = builtins.attrValues (
            builtins.foldl' (
              acc: t:
              let
                id = "${plain t.namespace}/${t.key}";
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

          egressRules = lib.unique (
            map (
              t:
              if t.hostNetwork then
                enforcerApi.mkHostNetworkEgressRule { ports = numericPorts t; }
              else
                enforcerApi.mkServiceEgressRule {
                  selector = t.podSelector;
                  namespace = t.namespace;
                  sourceNamespace = promNs;
                  ports = egressPorts t;
                }
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
          ingressTargets = builtins.filter (t: !t.hostNetwork && nsResources ? ${plain t.namespace}) targets;

          ingressPolicy =
            t:
            enforcerApi.mkPolicy {
              mkResource = core.mkResource;
              extraArgs = {
                name = "${promNs}-${promName}-scrape-${plain t.key}";
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
        };

      results = map perScraper scrapers;
    in
    {
      egressPolicies = builtins.concatMap (r: r.egressPolicies) results;
      ingressPolicies = builtins.concatMap (r: r.ingressPolicies) results;
    };
}

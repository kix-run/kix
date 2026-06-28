# Cilium-native network-policy rule builders.
#
# Shared between the full cilium package (default.nix) and the external
# variant (external.nix). Encodes CiliumNetworkPolicy rule shapes:
# toEndpoints/fromEndpoints with matchLabels, toEntities/fromEntities
# for identity-based rules, and Cilium's k8s:-prefixed namespace labels.
#
# Contract: kix/lib/netpol-interface.nix

{ lib }:

rec {
  # Build a network-policy resource routed through the CNP CRD ref.
  # mkResource is the caller's scope.mkResource or k8s.mkResource.
  mkPolicy =
    {
      crdRef,
      mkResource,
      extraArgs,
    }:
    mkResource (crdRef.out.cr extraArgs);

  # Spec for a default-deny policy (empty rule lists = deny all).
  mkDefaultDenySpec =
    {
      denyIngress,
      denyEgress,
    }:
    {
      endpointSelector = { };
    }
    // lib.optionalAttrs denyIngress { ingress = [ ]; }
    // lib.optionalAttrs denyEgress { egress = [ ]; };

  # DNS egress — allow UDP+TCP 53 to kube-dns in kube-system.
  dnsEgressRule = {
    toEndpoints = [
      {
        matchLabels = {
          "k8s:io.kubernetes.pod.namespace" = "kube-system";
          "k8s-app" = "kube-dns";
        };
      }
    ];
    toPorts = [
      {
        ports = [
          {
            port = "53";
            protocol = "UDP";
          }
          {
            port = "53";
            protocol = "TCP";
          }
        ];
      }
    ];
  };

  # API server egress — Cilium identity entity.
  # `host`/`remote-node` alongside `kube-apiserver`: when the apiserver is
  # host-networked (e.g. single-node k3s), its IP is the node IP, which
  # Cilium resolves to the reserved `host` identity (or `remote-node` for
  # other nodes) rather than `kube-apiserver`. Without these, a
  # default-deny CNP drops pod→apiserver traffic on such clusters
  # ("Policy denied" to host in `cilium monitor`).
  apiServerEgressRule = {
    toEntities = [
      "kube-apiserver"
      "remote-node"
      "host"
    ];
  };

  # External ingress (world / custom entities).
  mkExternalIngressRule =
    {
      entities ? [ "world" ],
    }:
    {
      fromEntities = entities;
    };

  # External egress (world / custom entities).
  mkExternalEgressRule =
    {
      entities ? [ "world" ],
    }:
    {
      toEntities = entities;
    };

  # Egress to a Service's backing pods.
  # Cross-namespace: stamps k8s:io.kubernetes.pod.namespace on the selector.
  mkServiceEgressRule =
    {
      selector,
      namespace,
      sourceNamespace,
      ports,
    }:
    let
      sel =
        if namespace == sourceNamespace then
          selector
        else
          selector
          // {
            "k8s:io.kubernetes.pod.namespace" = namespace;
          };
      cp = portsToCilium ports;
    in
    {
      toEndpoints = [ { matchLabels = sel; } ];
    }
    // lib.optionalAttrs (cp != [ ]) { toPorts = [ { ports = cp; } ]; };

  # Self-communication rules for StatefulSet peer traffic.
  mkSelfRules =
    { selector }:
    {
      egress = [
        { toEndpoints = [ { matchLabels = selector; } ]; }
      ];
      ingress = [
        { fromEndpoints = [ { matchLabels = selector; } ]; }
      ];
    };

  # Ingress from a specific caller workload (inverted cross-namespace ingress).
  mkCallerIngressRule =
    {
      callerSelector,
      callerNamespace,
      ports,
    }:
    let
      fromEndpoint = {
        matchLabels = callerSelector // {
          "k8s:io.kubernetes.pod.namespace" = callerNamespace;
        };
      };
      cp = portsToCilium ports;
    in
    {
      fromEndpoints = [ fromEndpoint ];
    }
    // lib.optionalAttrs (cp != [ ]) { toPorts = [ { ports = cp; } ]; };

  # Convert K8s Service ports to Cilium toPorts format.
  # Uses targetPort (pod port), not port (service port).
  portsToCilium =
    ports:
    builtins.filter (p: p != null) (
      map (
        p:
        let
          tp = p.targetPort or p.port or null;
        in
        if tp == null then
          null
        else
          {
            port = toString tp;
            protocol = p.protocol or "TCP";
          }
      ) ports
    );

  # Wrap matchLabels into Cilium's endpointSelector.
  mkEndpointSelector = matchLabels: { endpointSelector.matchLabels = matchLabels; };

  # Translate declarative intent rules to Cilium-native rules.
  translateIntentRules =
    { intents }:
    let
      translateEgressRule =
        rule:
        let
          target = rule.to or (throw "kix: egress intent rule must have 'to' field");
          baseRule =
            if target == "apiserver" then
              apiServerEgressRule
            else if target == "world" then
              mkExternalEgressRule { entities = rule.entities or [ "world" ]; }
            else if target == "dns" then
              dnsEgressRule
            else
              throw "kix: unknown egress intent target '${toString target}'";
        in
        if target == "dns" then
          baseRule # DNS rule already includes ports
        else
          baseRule
          // lib.optionalAttrs (rule ? ports) {
            toPorts = [
              {
                ports = portsToCilium rule.ports;
              }
            ];
          };

      translateIngressRule =
        rule:
        let
          source = rule.from or (throw "kix: ingress intent rule must have 'from' field");
          baseRule =
            if source == "all-pods" then
              { fromEntities = [ "cluster" ]; }
            else if source == "world" then
              mkExternalIngressRule { entities = rule.entities or [ "world" ]; }
            else
              throw "kix: unknown ingress intent source '${toString source}'";
        in
        baseRule
        // lib.optionalAttrs (rule ? ports) {
          toPorts = [
            {
              ports = portsToCilium rule.ports;
            }
          ];
        };

      allIntents = builtins.attrValues intents;
    in
    {
      egressRules = builtins.concatMap (i: map translateEgressRule (i.egress or [ ])) allIntents;
      ingressRules = builtins.concatMap (i: map translateIngressRule (i.ingress or [ ])) allIntents;
    };
}

# Whether the operator's pods may reach the Infisical address when the
# cluster enforces egress policy. The package's static network intent opens
# TCP 443 to destinations outside the cluster. Any other address needs a
# `networkPolicy.platformIntents` entry that selects the operator's pods.
{ lib }:
{
  # Returns null when the address is reachable, else the refusal message.
  # `address` is the normalised address, `scheme://host[:port][/path]`.
  check =
    {
      who,
      clusterConfig,
      address,
      namespace,
      selectorLabels,
      # Names the platform intent the refusal suggests.
      intentName,
    }:
    let
      networkPolicy = clusterConfig.networkPolicy or { };
      # `networkPolicy.enforced` is defined whenever the netpol module is
      # loaded, which `enable` implies.
      enforced = networkPolicy.enable or false && networkPolicy.enforced.egress;
      domain = clusterConfig.clusterDomain;

      parsed = builtins.match "(https?)://([^/:]+)(:([0-9]+))?(/.*)?" address;
      scheme = builtins.elemAt parsed 0;
      host = builtins.elemAt parsed 1;
      explicitPort = builtins.elemAt parsed 3;
      port =
        if explicitPort != null then
          lib.toInt explicitPort
        else if scheme == "https" then
          443
        else
          80;

      # A host without a dot, or under the cluster domain, is a Service name.
      # An IPv4 literal counts as outside the cluster, so an address in the
      # pod or Service range passes the 443 test although `world` does not
      # reach it; a platform intent for such an address may use either target.
      ipLiteral = builtins.match "[0-9.]+" host != null;
      inCluster =
        parsed != null
        && (
          !(lib.hasInfix "." host)
          || lib.hasSuffix ".svc" host
          || lib.hasSuffix ".svc.${domain}" host
          || lib.hasSuffix ".${domain}" host
        );
      target = if inCluster then "all-pods" else "world";
      targets =
        if parsed == null || ipLiteral then
          [
            "world"
            "all-pods"
          ]
        else
          [ target ];

      # A platform intent applies to the operator when it sits in the
      # operator's namespace (or targets it clusterwide) and its podSelector
      # is a subset of the operator's selector labels.
      selectsOperator =
        intent:
        (
          if (intent.scope or "namespaced") == "clusterwide" then
            intent.targetNamespace or null
          else
            intent.namespace or null
        ) == namespace
        && lib.all (k: (selectorLabels.${k} or null) == intent.podSelector.${k}) (
          builtins.attrNames (intent.podSelector or { })
        );
      # A rule without ports opens every port. Policy for traffic to a
      # Service applies to the backend pod's port, which the address does
      # not give, so an in-cluster rule passes with any ports, as does any
      # rule for an address the pattern cannot parse.
      coversPort =
        rule:
        builtins.elem (rule.to or null) targets
        && (
          parsed == null
          || inCluster
          || !(rule ? ports)
          || builtins.any (p: toString (p.port or "") == toString port) rule.ports
        );
      platformIntentCovers = builtins.any (
        intent: selectsOperator intent && builtins.any coversPort (intent.egress or [ ])
      ) (builtins.attrValues (networkPolicy.platformIntents or { }));

      selectorText = "{ ${
        lib.concatStrings (lib.mapAttrsToList (k: v: "\"${k}\" = \"${v}\"; ") selectorLabels)
      }}";
      portText = if inCluster then "<the port Infisical's pods listen on>" else toString port;
      remedy = "Add this entry to networkPolicy.platformIntents: ${intentName} = { namespace = \"${namespace}\"; podSelector = ${selectorText}; egress = [ { to = \"${target}\"; ports = [ { port = ${portText}; protocol = \"TCP\"; } ]; } ]; };";
    in
    if !enforced || platformIntentCovers then
      null
    else if parsed == null then
      "${who}: this cluster enforces egress policy, and the package cannot read a host and port from address ${address}, so it cannot tell whether the operator may reach it. Use a host name, or add a networkPolicy.platformIntents entry with namespace = \"${namespace}\", podSelector = ${selectorText}, and an egress rule that reaches the address."
    else if port == 443 && !inCluster then
      null
    else
      "${who}: this cluster enforces egress policy, and the package's network intent opens only TCP 443 to destinations outside the cluster, so the operator cannot reach ${address} and the default InfisicalConnection would never become ready. ${remedy}";
}

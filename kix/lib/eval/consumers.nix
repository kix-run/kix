# Two Kix clusters on one Kubernetes cluster: a platform and the consumers
# it hosts. Each builds alone, from its own code, under a name of its own.
# They share data only: the platform's build writes one interface file per
# consumer, and the consumer's build loads a copy of it with `kix.interface`.
#
# A consumer's namespaces are patterns (`acme-*`, `reports`, `*`). The
# platform's namespaces are those its build renders into plus its
# `reservedNamespaces`; a consumer may use any namespace one of its patterns
# matches and that is not the platform's. The consumer renders its own
# namespaces, and each carries the consumer's label, Pod Security level and
# quota.
#
# `platform` checks a cluster's `consumers`, renders the ingress rules to
# granted services, and writes the interface files. `interface` is the
# loader. `consumer` is what buildCluster does with a loaded interface: it
# stamps the consumer's namespaces, refuses objects outside the grant, and
# records the file in the Activation record.

{
  lib,
  k8s,
  mkImport,
  instancePinsLib,
}:

let
  version = 1;

  kixAnnotations = import ../core/annotations.nix;
  consumerLabel = kixAnnotations.keys.consumerLabel;

  plain = v: builtins.unsafeDiscardStringContext (toString v);

  isDnsLabel =
    s: builtins.stringLength s <= 63 && builtins.match "[a-z0-9]([-a-z0-9]*[a-z0-9])?" s != null;

  groupOf =
    apiVersion:
    let
      parts = lib.splitString "/" apiVersion;
    in
    if builtins.length parts > 1 then builtins.head parts else "";

  # A namespace pattern: `*`, a prefix glob `x-*`, or an exact name.
  isGlob = p: p != "*" && lib.hasSuffix "*" p;
  prefixOf = lib.removeSuffix "*";
  isPattern =
    p:
    p == "*" || (isGlob p && builtins.match "[a-z0-9][-a-z0-9]*" (prefixOf p) != null) || isDnsLabel p;
  matches = p: ns: p == "*" || (if isGlob p then lib.hasPrefix (prefixOf p) ns else p == ns);
  # Whether some namespace could match both `a` and `b`, neither of them `*`.
  overlap =
    a: b:
    if isGlob a && isGlob b then
      lib.hasPrefix (prefixOf a) (prefixOf b) || lib.hasPrefix (prefixOf b) (prefixOf a)
    else if isGlob a then
      matches a b
    else if isGlob b then
      matches b a
    else
      a == b;

  # Objects every Kix cluster renders for itself: its Activation record and
  # the CRDs of kix's own kinds. Neither grant nor platform checks apply.
  isKixOwn =
    m:
    let
      kind = m.kind or "";
      name = plain (m.metadata.name or "");
    in
    (kind == "Activation" && groupOf (plain (m.apiVersion or "")) == kixAnnotations.group)
    || (
      kind == "CustomResourceDefinition"
      && builtins.elem name [
        "activations.${kixAnnotations.group}"
        "packageinstances.${kixAnnotations.group}"
      ]
    );

  # A string context entry that carries no content into the interface: a
  # fact token, an inert marker, or the identity of a resource this cluster
  # renders (`k8s-*`, the context every `out` value of a resource carries).
  isInertContext =
    path: ctx:
    k8s.facts.isFactPath path
    || k8s.markers.isMarkerPath path
    || ((ctx.path or false) && lib.hasPrefix "k8s-" (k8s.markers.pathName path));

  # `out` as plain JSON data. Functions, kix's own handles (anything with a
  # `_type`) and `identityHash` are dropped: the hash changes with every
  # edit of the platform's object and tells the consumer nothing. A string
  # that refers to a store path in any other way, a SOPS file or a rendered
  # configuration file, is refused, naming the field, since its content is
  # the platform's.
  plainOut =
    field: v:
    if builtins.isFunction v then
      null
    else if builtins.isAttrs v then
      if v ? _type || v ? outPath then
        null
      else
        lib.filterAttrs (_: x: x != null) (
          lib.mapAttrs (k: plainOut "${field}.${k}") (removeAttrs v [ "identityHash" ])
        )
    else if builtins.isList v then
      lib.imap0 (i: plainOut "${field}.${toString i}") v
    else if builtins.isString v then
      let
        ctx = builtins.getContext v;
        carried = builtins.filter (p: !isInertContext p ctx.${p}) (builtins.attrNames ctx);
        text = builtins.unsafeDiscardStringContext v;
      in
      if carried != [ ] || lib.hasInfix builtins.storeDir text then
        throw "kix: ${field} refers to a store path (${
          if carried != [ ] then builtins.head carried else text
        }). An interface carries data only; a store path can hold a secret or the platform's code. Give the consumer the value it needs instead."
      else
        text
    else
      v;

  # Refusals, as messages, of the platform's grants: names, patterns, `*`
  # held once, no two consumers' patterns overlapping, no exact pattern on
  # a platform namespace, and delivered Secrets in the consumer's own
  # namespaces.
  grantRefusals =
    {
      name,
      consumers,
      platformNamespaces,
    }:
    let
      owns = c: ns: !(builtins.elem ns platformNamespaces) && builtins.any (p: matches p ns) c.namespaces;
      names = builtins.attrNames consumers;
      wildcards = builtins.filter (c: builtins.elem "*" consumers.${c}.namespaces) names;
      pairs = lib.concatMap (a: map (b: { inherit a b; }) (builtins.filter (b: a < b) names)) names;
      overlapsOf =
        { a, b }:
        lib.concatMap (
          pa:
          map (
            pb:
            "consumers.${a} and consumers.${b} both match namespaces '${pa}' and '${pb}'. Give each consumer namespaces of its own."
          ) (builtins.filter (pb: pb != "*" && pa != "*" && overlap pa pb) consumers.${b}.namespaces)
        ) consumers.${a}.namespaces;
      ofConsumer =
        consumer: c:
        let
          who = "consumers.${consumer}";
        in
        lib.optional (
          !isDnsLabel consumer
        ) "${who}: the consumer name must be a DNS label (lower-case letters, digits and '-')."
        ++
          lib.optional (c.namespaces == [ ])
            "${who}.namespaces is empty, so the consumer has nowhere to put its objects. Give it a pattern such as \"${consumer}-*\"."
        ++ map (
          p:
          "${who}.namespaces: '${p}' is not a namespace pattern. Use an exact name, a prefix such as \"${consumer}-*\", or \"*\"."
        ) (builtins.filter (p: !isPattern p) c.namespaces)
        ++ map (
          p:
          "${who}.namespaces: '${p}' is a namespace cluster '${name}' uses itself. A consumer's namespace holds only the consumer's objects."
        ) (builtins.filter (p: !isGlob p && p != "*" && builtins.elem p platformNamespaces) c.namespaces)
        ++ map (
          s:
          "${who}.secrets: Secret '${s.name}' is in namespace '${s.namespace}', which is not one of the consumer's namespaces (${builtins.concatStringsSep ", " c.namespaces}, not cluster '${name}''s own)."
        ) (builtins.filter (s: !(owns c s.namespace)) c.secrets);
    in
    lib.concatLists (lib.mapAttrsToList ofConsumer consumers)
    ++
      lib.optional (builtins.length wildcards > 1)
        "consumers ${builtins.concatStringsSep " and " wildcards} each hold namespaces \"*\". One consumer may hold \"*\"; give the others patterns of their own."
    ++ lib.concatMap overlapsOf pairs;
in
{
  inherit isKixOwn grantRefusals;

  # What the platform cluster `name` renders for its consumers, and the
  # interface file of each.
  platform =
    {
      name,
      cfg,
      realNsNames,
      nsResources,
      mergedInstances,
      clusterInstances,
      peekedMetas,
      isActive,
    }:
    let
      consumers = cfg.consumers;
      platformNamespaces = lib.unique (
        builtins.sort builtins.lessThan (realNsNames ++ cfg.reservedNamespaces)
      );

      refusals = grantRefusals { inherit name consumers platformNamespaces; };

      instanceOf =
        consumer: key:
        let
          parts = lib.splitString "/" key;
          ns = builtins.head parts;
          inst = lib.last parts;
          instCfg = (mergedInstances.${ns} or { }).${inst} or null;
        in
        if builtins.length parts != 2 || instCfg == null then
          throw "kix: consumers.${consumer}.services names '${key}', which is not an instance of cluster '${name}'. Name a service as \"namespace/instance\"."
        else if (instCfg.package._type or "") == "kix-import" then
          throw "kix: consumers.${consumer}.services names '${key}', an import. A consumer can import what the environment provides itself."
        else if !(isActive ns inst) then
          throw "kix: consumers.${consumer}.services names '${key}', an optional instance that is not active."
        else
          {
            inherit ns inst;
            out = clusterInstances.${ns}.${inst}.out or { };
            # The instance's root object as rendered: a Service's own pod
            # selector and ports, for the ingress policy.
            root =
              let
                r = clusterInstances.${ns}.${inst}.raw.root or { };
              in
              (r.resource or r).rawManifest or { };
            roles = (peekedMetas.${ns}.${inst}).roles or [ ];
          };

      # Lets the consumer's pods reach a granted service: from every
      # namespace carrying the consumer's label. Only when the cluster
      # enforces network policy: on a cluster that does not, an allow policy
      # would isolate the service's pods from everyone else.
      ingressPolicies =
        if !(cfg.networkPolicy.enable or false) then
          [ ]
        else
          lib.concatLists (
            lib.mapAttrsToList (
              consumer: c:
              lib.concatMap (
                key:
                let
                  svc = instanceOf consumer key;
                in
                lib.optional ((svc.root.kind or "") == "Service" && (svc.root.spec.selector or { }) != { }) (
                  k8s.mkResource {
                    apiVersion = "networking.k8s.io/v1";
                    kind = "NetworkPolicy";
                    name = "kix-consumer-${consumer}-${svc.inst}";
                    namespace = nsResources.${svc.ns};
                    labels = {
                      "app.kubernetes.io/managed-by" = "kix";
                      ${consumerLabel} = consumer;
                    };
                    spec = {
                      podSelector.matchLabels = lib.mapAttrs (_: plain) svc.root.spec.selector;
                      policyTypes = [ "Ingress" ];
                      ingress = [
                        {
                          from = [ { namespaceSelector.matchLabels.${consumerLabel} = consumer; } ];
                          ports = map (p: {
                            port = p.targetPort or p.port;
                            protocol = p.protocol or "TCP";
                          }) (svc.root.spec.ports or [ ]);
                        }
                      ];
                    };
                  }
                )
              ) c.services
            ) consumers
          );

      interfaceOf = consumer: c: {
        inherit version consumer;
        platform = name;
        facts = {
          provider = cfg.cluster.provider;
          k8sVersion = cfg.k8sVersion;
          clusterDomain = cfg.clusterDomain;
          capabilities = cfg.cluster.capabilities;
          networkPolicy = cfg.networkPolicy.enable or false;
        };
        namespaces = {
          patterns = c.namespaces;
          inherit (c) podSecurity resourceQuota;
          platform = platformNamespaces;
        };
        services = builtins.listToAttrs (
          map (
            key:
            let
              svc = instanceOf consumer key;
            in
            lib.nameValuePair key {
              namespace = svc.ns;
              instance = svc.inst;
              inherit (svc) roles;
              out = plainOut ''consumers.${consumer}.services."${key}".out'' svc.out;
            }
          ) c.services
        );
        secrets = map (s: {
          inherit (s)
            name
            namespace
            keys
            type
            ;
        }) c.secrets;
        clusterScoped = map (o: { inherit (o) kind name; }) c.clusterScoped;
        secretsRecipient = cfg.secretsRecipient;
      };

      files = lib.mapAttrs (
        consumer: c:
        builtins.toFile "kix-interface-${consumer}.json" (builtins.toJSON (interfaceOf consumer c))
      ) consumers;
    in
    if refusals != [ ] then
      throw "kix: cluster '${name}' grants its consumers what it cannot:\n  ${builtins.concatStringsSep "\n  " refusals}"
    else
      {
        resources = ingressPolicies;
        interfaces = files;
        recordConsumers = lib.mapAttrs (_: file: { interface = plain file; }) files;
        interfaceFiles = builtins.attrValues files;
      };

  # `kix.interface ./kix-interface/prod.json`, or
  # `kix.interface { file = ./kix-interface/prod.json; importNamespace = "acme-app"; }`:
  # a cluster module that builds this cluster as the consumer the file
  # describes. Each granted service becomes an import in `importNamespace`,
  # by default the first exact name among the consumer's patterns.
  interface =
    arg:
    { lib, ... }:
    let
      file = if builtins.isAttrs arg && !(arg ? outPath) then arg.file else arg;
      data = builtins.fromJSON (builtins.readFile file);
      where = instancePinsLib.relativeFile (toString file);
      facts = data.facts or { };
      # Every capability as a default, so the cluster's own setting wins.
      defaults = v: if builtins.isAttrs v then lib.mapAttrs (_: defaults) v else lib.mkDefault v;
      exact = builtins.filter (p: !isGlob p && p != "*") (data.namespaces.patterns or [ ]);
      home =
        if builtins.isAttrs arg && arg ? importNamespace then
          arg.importNamespace
        else if exact != [ ] then
          builtins.head exact
        else
          throw "kix.interface: ${where} gives the consumer namespace patterns only (${builtins.concatStringsSep ", " data.namespaces.patterns}), so kix does not know where to put the imports of its services. Name one: kix.interface { file = ./${baseNameOf (toString file)}; importNamespace = \"<namespace>\"; }.";
      imports = lib.mapAttrsToList (key: svc: {
        inherit key;
        inherit (svc) instance;
        package = mkImport {
          inherit (svc) out roles;
        };
      }) data.services;
      repeated = builtins.filter (i: lib.count (j: j.instance == i.instance) imports > 1) imports;
    in
    if (data.version or null) != version then
      throw "kix.interface: ${where} has format version ${
        builtins.toJSON (data.version or null)
      }; this kix reads version ${toString version}. Use a kix that reads it, or ask the platform for an interface of version ${toString version}."
    else if repeated != [ ] then
      throw "kix.interface: ${where} grants services ${
        builtins.concatStringsSep " and " (map (i: i.key) repeated)
      }, which share the instance name '${(builtins.head repeated).instance}'. Each becomes an import of that name in namespace '${home}', so only one can."
    else
      {
        clusterDomain = lib.mkDefault facts.clusterDomain;
        k8sVersion = lib.mkDefault facts.k8sVersion;
        cluster.provider = lib.mkDefault facts.provider;
        cluster.capabilities = defaults (facts.capabilities or { });
        interfaces.${data.platform} = data // {
          inherit file;
        };
        instances = lib.optionalAttrs (imports != [ ]) {
          ${home} = builtins.listToAttrs (
            map (i: lib.nameValuePair i.instance { inherit (i) package; }) imports
          );
        };
      };

  # What buildCluster `name` does with the interfaces in `cfg.interfaces`:
  # null when it loads none.
  consumer =
    {
      name,
      cfg,
      self,
    }:
    let
      loaded = builtins.attrValues cfg.interfaces;
      data = builtins.head loaded;
      grant = data.namespaces;
      allowedScoped = map (o: "${o.kind}/${o.name}") data.clusterScoped;
      who =
        m:
        "${plain m.kind} ${
          lib.optionalString (m.metadata ? namespace) "${plain m.metadata.namespace}/"
        }${plain m.metadata.name}";
      whose =
        ns:
        if builtins.elem ns grant.platform then
          "is ${data.platform}'s"
        else if !(builtins.any (p: matches p ns) grant.patterns) then
          "matches none of your namespaces (${builtins.concatStringsSep ", " grant.patterns})"
        else
          null;

      # Refuse what the grant does not allow, before anything is deployed.
      refusalOf =
        m:
        let
          ns = if m.metadata ? namespace then plain m.metadata.namespace else null;
          namespace = if ns == null && plain m.kind == "Namespace" then plain m.metadata.name else ns;
        in
        if isKixOwn m then
          null
        else if namespace != null && whose namespace != null then
          "${who m} is in namespace ${namespace}, which ${whose namespace}."
        else if
          namespace == null && !(builtins.elem "${plain m.kind}/${plain m.metadata.name}" allowedScoped)
        then
          "${who m} is cluster-scoped, and ${data.platform}'s interface does not let ${name} own it. It allows ${
            if allowedScoped == [ ] then
              "no cluster-scoped objects"
            else
              builtins.concatStringsSep ", " allowedScoped
          }."
        else
          null;
    in
    if loaded == [ ] then
      null
    else if builtins.length loaded > 1 then
      throw "kix: cluster '${name}' loads interfaces of ${builtins.concatStringsSep " and " (builtins.attrNames cfg.interfaces)}. A cluster is one platform's consumer; load one interface."
    else
      {
        # A namespace's own configuration, with the consumer's label, and
        # the platform's Pod Security level and quota where it sets them.
        stamp =
          own:
          own
          // {
            labels = (own.labels or { }) // {
              ${consumerLabel} = data.consumer;
            };
          }
          // lib.optionalAttrs (grant.podSecurity != null) { inherit (grant) podSecurity; }
          // lib.optionalAttrs (grant.resourceQuota != null) { inherit (grant) resourceQuota; };

        # The hash of the file as the platform's build writes it: compact
        # JSON with sorted keys. A copy reformatted by an editor pins the
        # same interface as the platform's own file.
        recordInterfaces.${data.platform} = {
          inherit (data) consumer;
          path = instancePinsLib.pathInFlake self data.file;
          sha256 = builtins.hashString "sha256" (
            builtins.toJSON (builtins.fromJSON (builtins.readFile data.file))
          );
        };

        # The refusals of the build, as assertions.
        assertionsFor =
          manifests:
          map (message: {
            assertion = false;
            message = "kix: ${message}";
          }) (builtins.filter (r: r != null) (map refusalOf manifests));
      };
}

# Support platform and consumer Kix clusters on the same Kubernetes cluster.
# Each cluster evaluates independently under its own name. The platform build
# writes one JSON interface file per consumer, and each consumer build loads
# its interface file with `kix.interface`.
#
# Each consumer's `namespaces` grant maps patterns (`acme-*`, `reports`, `*`) to
# namespace settings (Pod Security level, quota, `max` on patterns, and Secrets
# on exact names). An exact name within a pattern overrides that namespace's
# settings. A consumer may use any namespace matching one of its patterns except
# namespaces the platform renders or lists in `reservedNamespaces`. At most one
# consumer may hold `*`, which grants every namespace not owned by the platform
# or matched by another consumer's pattern (recorded in `claimedNamespaces`).
#
# `platform` validates `consumers`, generates ingress policies for granted
# services, and writes the interface files. `interface` loads an interface file
# as a cluster module. `consumer` stamps the consumer's namespaces, rejects
# resources outside the grant, and records the interface in the Activation
# resource.

{
  lib,
  k8s,
  mkImport,
  instancePinsLib,
}:

let
  inherit (import ../core/error.nix { inherit lib; }) fail;
  version = 2;

  kixAnnotations = import ../core/annotations.nix;
  consumerLabel = kixAnnotations.keys.consumerLabel;

  inherit (import ../core/util.nix { inherit lib; }) plain groupOf;

  # Hash the normalized JSON of an interface file so reformatted copies match
  # the file written by the platform build. Both Activation records store this
  # hash so `kix status` can verify whether a consumer matches the current
  # platform interface.
  interfaceHash =
    file: builtins.hashString "sha256" (builtins.toJSON (builtins.fromJSON (builtins.readFile file)));

  isDnsLabel =
    s: builtins.stringLength s <= 63 && builtins.match "[a-z0-9]([-a-z0-9]*[a-z0-9])?" s != null;

  isGlob = p: p != "*" && lib.hasSuffix "*" p;
  prefixOf = lib.removeSuffix "*";
  isPattern =
    p:
    p == "*" || (isGlob p && builtins.match "[a-z0-9][-a-z0-9]*" (prefixOf p) != null) || isDnsLabel p;
  matches = p: ns: p == "*" || (if isGlob p then lib.hasPrefix (prefixOf p) ns else p == ns);
  # Return true when some namespace could match both non-wildcard patterns `a`
  # and `b`.
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

  # Return true for Kix's own cluster-level resources (its Activation record
  # and Kix CRDs), which bypass consumer grant and platform checks.
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

  # Return true for string context entries that carry only Kix tracking
  # metadata (fact tokens, markers, or `k8s-*` resource identity paths) rather
  # than store file content.
  isInertContext =
    path: ctx:
    k8s.facts.isFactPath path
    || k8s.markers.isMarkerPath path
    || ((ctx.path or false) && lib.hasPrefix "k8s-" (k8s.markers.pathName path));

  # Convert `out` to plain JSON data for an interface file. Drop functions,
  # typed Kix handles, and `identityHash` and `contentHash` (which change on
  # edits to the platform object). Reject strings that reference store paths such as SOPS
  # secrets or rendered config files so platform store paths do not leak into
  # the interface.
  plainOut =
    field: v:
    if builtins.isFunction v then
      null
    else if builtins.isAttrs v then
      if v ? _type || v ? outPath then
        null
      else
        lib.filterAttrs (_: x: x != null) (
          lib.mapAttrs (k: plainOut "${field}.${k}") (
            removeAttrs v [
              "identityHash"
              "contentHash"
            ]
          )
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
        fail {
          message = "${field} contains a file path from Kix's local store (${
            if carried != [ ] then builtins.head carried else text
          }). A consumer interface file can carry only plain strings, numbers, booleans, lists, and attribute sets, because a local store path is not available in the consumer project and may hold a secret.";
          fix = "Change the package or `out` field of the service so ${field} is a plain string value (or Secret name) rather than a file path.";
        }
      else
        text
    else
      v;

  # Return the namespace patterns claimed by other consumers when `consumer`
  # holds `*`, or an empty list otherwise.
  claimedBy =
    consumers: consumer:
    if consumers.${consumer}.namespaces ? "*" then
      lib.unique (
        builtins.sort builtins.lessThan (
          builtins.filter (p: p != "*") (
            lib.concatMap (c: builtins.attrNames consumers.${c}.namespaces) (
              builtins.filter (c: c != consumer) (builtins.attrNames consumers)
            )
          )
        )
      )
    else
      [ ];

  # Validate consumer grants and return any error messages. Checks consumer
  # names, namespace patterns, single `*` ownership, non-overlapping patterns
  # within and across consumers, reserved platform namespaces, `max` on patterns
  # only, and `secrets` on exact namespace names only.
  grantRefusals =
    {
      name,
      consumers,
      platformNamespaces,
    }:
    let
      names = builtins.attrNames consumers;
      keysOf = c: builtins.attrNames consumers.${c}.namespaces;
      wildcards = builtins.filter (c: consumers.${c}.namespaces ? "*") names;
      pairsOf = xs: lib.concatMap (a: map (b: { inherit a b; }) (builtins.filter (b: a < b) xs)) xs;
      overlapsOf =
        { a, b }:
        lib.concatMap (
          pa:
          map (
            pb:
            "consumers.${a} and consumers.${b} both match namespaces '${pa}' and '${pb}'. Give each consumer namespaces of its own."
          ) (builtins.filter (pb: pb != "*" && pa != "*" && overlap pa pb) (keysOf b))
        ) (keysOf a);
      ofConsumer =
        consumer: c:
        let
          who = "consumers.${consumer}";
          keys = builtins.attrNames c.namespaces;
          patterns = builtins.filter (p: p == "*" || isGlob p) keys;
          exact = builtins.filter (p: !(p == "*" || isGlob p)) keys;
        in
        lib.optional (
          !isDnsLabel consumer
        ) "${who}: the consumer name must be a DNS label (lower-case letters, digits and '-')."
        ++
          lib.optional (c.namespaces == { })
            "${who}.namespaces is empty, so the consumer has nowhere to put its objects. Give it a pattern such as \"${consumer}-*\" = { }."
        ++ map (
          p:
          "${who}.namespaces: '${p}' is not a namespace pattern. Use an exact name, a prefix such as \"${consumer}-*\", or \"*\"."
        ) (builtins.filter (p: !isPattern p) keys)
        ++ map (
          p:
          "${who}.namespaces: '${p}' is a namespace cluster '${name}' uses itself. A consumer's namespace holds only the consumer's objects."
        ) (builtins.filter (p: builtins.elem p platformNamespaces) exact)
        ++ map (
          { a, b }:
          "${who}.namespaces: '${a}' and '${b}' can match the same namespace. Give each namespace one pattern; an exact name inside a pattern may adjust its settings."
        ) (builtins.filter ({ a, b }: a == "*" || b == "*" || overlap a b) (pairsOf patterns))
        ++ map (
          p:
          "${who}.namespaces.${p}.max: '${p}' is an exact name, so it is one namespace. Set `max` on a pattern."
        ) (builtins.filter (p: c.namespaces.${p}.max != null) exact)
        ++ map (
          p:
          "${who}.namespaces.\"${p}\".secrets: '${p}' is a pattern, and a Secret lives in one namespace. List the Secret under the exact name of its namespace."
        ) (builtins.filter (p: c.namespaces.${p}.secrets != [ ]) patterns);
    in
    lib.concatLists (lib.mapAttrsToList ofConsumer consumers)
    ++
      lib.optional (builtins.length wildcards > 1)
        "consumers ${builtins.concatStringsSep " and " wildcards} each hold namespaces \"*\". One consumer may hold \"*\"; give the others patterns of their own."
    ++ lib.concatMap overlapsOf (pairsOf names);
in
{
  inherit isKixOwn grantRefusals;

  # Build the resources and interface files that platform cluster `name`
  # produces for its consumers.
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
          instCfg = mergedInstances.${ns}.${inst} or null;
        in
        if builtins.length parts != 2 || instCfg == null then
          fail {
            message = "cluster '${name}' (platform): consumers.${consumer}.services lists '${key}', which is not an instance in cluster '${name}'.";
            fix = "Write the service as \"<namespace>/<instance>\" matching an instance in `instances.<namespace>.<instance>`, or remove '${key}' from consumers.${consumer}.services.";
          }
        else if (instCfg.package._type or "") == "kix-import" then
          fail {
            message = "cluster '${name}' (platform): consumers.${consumer}.services lists '${key}', which is a kix.mkImport instance for an external service. Platform interfaces publish only services that cluster '${name}' manages.";
            fix = "Remove '${key}' from consumers.${consumer}.services in cluster '${name}', and declare `kix.mkImport` for '${key}' directly in consumer '${consumer}'s cluster definition.";
          }
        else if !(isActive ns inst) then
          fail {
            message = "cluster '${name}' (platform): consumers.${consumer}.services lists '${key}', which is an optional instance (`optional = true`) that nothing in cluster '${name}' activates.";
            fix = "Set `instances.${ns}.${inst}.optional = false;` in cluster '${name}' so it is always deployed for consumers, or remove '${key}' from consumers.${consumer}.services.";
          }
        else
          {
            inherit ns inst;
            out = clusterInstances.${ns}.${inst}.out or { };
            root =
              let
                r = clusterInstances.${ns}.${inst}.raw.root or { };
              in
              (r.resource or r).rawManifest or { };
            roles = (peekedMetas.${ns}.${inst}).roles or [ ];
          };

      # Generate ingress NetworkPolicies allowing consumer namespaces to reach
      # granted Services. Emit these policies only when `networkPolicy.enable`
      # is true; otherwise an allow policy would isolate the Service's pods from
      # other traffic.
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
        namespaces = lib.mapAttrs (_: n: {
          inherit (n) podSecurity quota max;
          secrets = map (s: { inherit (s) name keys type; }) n.secrets;
        }) c.namespaces;
        inherit platformNamespaces;
        claimedNamespaces = claimedBy consumers consumer;
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
        clusterScoped = map (o: { inherit (o) kind name; }) c.clusterScoped;
        secretsRecipient = cfg.secretsRecipient;
      };

      files = lib.mapAttrs (
        consumer: c:
        builtins.toFile "kix-interface-${consumer}.json" (builtins.toJSON (interfaceOf consumer c))
      ) consumers;
    in
    if refusals != [ ] then
      fail {
        clusterOption = "consumers";
        message = "cluster '${name}' (platform): invalid consumer grant(s) in `consumers`:\n  ${builtins.concatStringsSep "\n  " refusals}";
      }
    else
      {
        resources = ingressPolicies;
        interfaces = files;
        recordConsumers = lib.mapAttrs (_: file: {
          interface = plain file;
          sha256 = interfaceHash file;
        }) files;
        interfaceFiles = builtins.attrValues files;
      };

  # Load a platform interface file (`kix.interface ./path.json` or
  # `kix.interface { file = ./path.json; importNamespace = "acme-app"; }`) and
  # return a cluster module for the consumer. Each granted service becomes an
  # import in `importNamespace`, which defaults to the alphabetically first
  # exact namespace name in the grant.
  interface =
    arg:
    { lib, ... }:
    let
      file = if builtins.isAttrs arg && !(arg ? outPath) then arg.file else arg;
      data = builtins.fromJSON (builtins.readFile file);
      where = instancePinsLib.relativeFile (toString file);
      facts = data.facts or { };
      # Set every capability with `mkDefault` so the consumer cluster can
      # override it.
      defaults = v: if builtins.isAttrs v then lib.mapAttrs (_: defaults) v else lib.mkDefault v;
      exact = builtins.filter (p: !isGlob p && p != "*") (builtins.attrNames (data.namespaces or { }));
      home =
        if builtins.isAttrs arg && arg ? importNamespace then
          arg.importNamespace
        else if exact != [ ] then
          builtins.head exact
        else
          fail {
            message = "kix.interface: ${where} gives the consumer namespace patterns only (${builtins.concatStringsSep ", " (builtins.attrNames data.namespaces)}), with no concrete namespace for imported services.";
            fix = "Pass `importNamespace`: kix.interface { file = ./${baseNameOf (toString file)}; importNamespace = \"<namespace>\"; }.";
          };
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
      fail {
        message = "kix.interface: ${where} has format version ${
          builtins.toJSON (data.version or null)
        }; Kix reads version ${toString version}.";
        fix = "Use a version of Kix that reads it, or ask the platform for an interface of version ${toString version}.";
      }
    else if repeated != [ ] then
      fail {
        message = "kix.interface: ${where} grants services ${
          builtins.concatStringsSep " and " (map (i: i.key) repeated)
        }, which share the instance name '${(builtins.head repeated).instance}'. Each becomes an import of that name in namespace '${home}', so only one can.";
      }
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

  # Enforce a loaded platform interface on consumer cluster `name`, or return
  # null when `cfg.interfaces` is empty.
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
      keys = builtins.attrNames grant;
      patterns = builtins.filter (p: p == "*" || isGlob p) keys;
      allowedScoped = map (o: "${o.kind}/${o.name}") data.clusterScoped;
      who =
        m:
        "${plain m.kind} ${
          lib.optionalString (m.metadata ? namespace) "${plain m.metadata.namespace}/"
        }${plain m.metadata.name}";
      whose =
        ns:
        if builtins.elem ns data.platformNamespaces then
          "is ${data.platform}'s"
        else if !(builtins.any (p: matches p ns) keys) then
          "matches none of your namespaces (${builtins.concatStringsSep ", " keys})"
        else
          let
            by = builtins.filter (p: matches p ns) data.claimedNamespaces;
          in
          if by != [ ] then
            "another consumer of ${data.platform} uses (it matches '${builtins.head by}')"
          else
            null;

      # Resolve settings for namespace `ns` by overlaying exact-name settings on
      # top of the matching pattern's settings. Platform validation rejects
      # overlapping patterns, so at most one pattern matches.
      settingsOf =
        ns:
        let
          pattern = lib.findFirst (p: matches p ns) null patterns;
          base =
            if pattern == null then
              {
                podSecurity = null;
                quota = { };
              }
            else
              grant.${pattern};
          own = grant.${ns} or { };
        in
        {
          podSecurity = if (own.podSecurity or null) != null then own.podSecurity else base.podSecurity;
          quota = base.quota // (own.quota or { });
        };

      # Return an error message if manifest `m` falls outside the platform's
      # grant, or null if allowed.
      refusalOf =
        m:
        let
          ns = if m.metadata ? namespace then plain m.metadata.namespace else null;
          namespace = if ns == null && plain m.kind == "Namespace" then plain m.metadata.name else ns;
        in
        if isKixOwn m then
          null
        # Name the namespace a Namespace object creates, since it is in none.
        else if ns == null && namespace != null && whose namespace != null then
          "${name} may not create Namespace ${namespace}, which ${whose namespace}."
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

      # Return an error message for each pattern whose `max` namespace count is
      # exceeded by `manifests`.
      overMax =
        manifests:
        let
          namespaces = map (m: plain m.metadata.name) (
            builtins.filter (m: plain (m.kind or "") == "Namespace") manifests
          );
        in
        lib.concatMap (
          p:
          let
            max = grant.${p}.max or null;
            found = builtins.filter (matches p) namespaces;
          in
          lib.optional (max != null && builtins.length found > max)
            "the build renders ${toString (builtins.length found)} namespaces matching '${p}' (${builtins.concatStringsSep ", " found}), and ${data.platform}'s interface allows at most ${toString max}."
        ) patterns;
    in
    if loaded == [ ] then
      null
    else if builtins.length loaded > 1 then
      fail {
        message = "cluster '${name}' (consumer): loads multiple platform interfaces (${builtins.concatStringsSep " and " (builtins.attrNames cfg.interfaces)}). A consumer cluster can belong to only one platform cluster.";
        fix = "Keep one `kix.interface` module in cluster '${name}' and remove the others.";
      }
    else
      {
        # Stamp namespace `ns` with the consumer label and any Pod Security
        # level or quota from the platform interface.
        stamp =
          ns: own:
          let
            settings = settingsOf ns;
          in
          own
          // {
            labels = (own.labels or { }) // {
              ${consumerLabel} = data.consumer;
            };
          }
          // lib.optionalAttrs (settings.podSecurity != null) { inherit (settings) podSecurity; }
          // lib.optionalAttrs (settings.quota != { }) { resourceQuota = settings.quota; };

        # Describe the interface source of `ns`'s Pod Security level for error
        # messages, or return null when the interface does not set one.
        podSecuritySourceOf =
          ns: if (settingsOf ns).podSecurity != null then "set by ${data.platform}'s interface" else null;

        recordInterfaces.${data.platform} = {
          inherit (data) consumer;
          path = instancePinsLib.pathInFlake self data.file;
          sha256 = interfaceHash data.file;
        };

        # Convert grant violations across `manifests` into failed build
        # assertions.
        assertionsFor =
          manifests:
          map (message: {
            assertion = false;
            message = "kix: ${message}";
          }) (builtins.filter (r: r != null) (map refusalOf manifests) ++ overMax manifests);
      };
}

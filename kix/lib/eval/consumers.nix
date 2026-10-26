# Two Kix clusters on one Kubernetes cluster: a platform and the consumers
# it hosts. Each builds alone, from its own code. They share data only: the
# platform's build writes one interface file per consumer, and the
# consumer's build loads a copy of it with `kix.interface`.
#
# `platform` renders what a cluster's `consumers` grant (namespaces, ingress
# to granted services) and writes the interface files. `interface` is the
# loader. `consumer` is what buildCluster does with a loaded interface: it
# leaves the provided namespaces unrendered, refuses objects outside the
# grant, and records the file in the Activation record.

{
  lib,
  k8s,
  mkImport,
  instancePinsLib,
}:

let
  version = 1;

  plain = v: builtins.unsafeDiscardStringContext (toString v);

  isDnsLabel =
    s: builtins.stringLength s <= 63 && builtins.match "[a-z0-9]([-a-z0-9]*[a-z0-9])?" s != null;

  groupOf =
    apiVersion:
    let
      parts = lib.splitString "/" apiVersion;
    in
    if builtins.length parts > 1 then builtins.head parts else "";

  # Objects every Kix cluster renders for itself: its Activation record and
  # the CRDs of kix's own kinds. Neither grant nor platform checks apply.
  isKixOwn =
    m:
    let
      kind = m.kind or "";
      name = plain (m.metadata.name or "");
    in
    (kind == "Activation" && groupOf (plain (m.apiVersion or "")) == "kix.run")
    || (
      kind == "CustomResourceDefinition"
      && builtins.elem name [
        "activations.kix.run"
        "packageinstances.kix.run"
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
  # edit of the platform's object and tells the consumer nothing. A string that refers to a store path in any other
  # way, a SOPS file or a rendered configuration file, is refused, naming
  # the field, since its content is the platform's.
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
in
{
  inherit isKixOwn;

  # What the platform cluster `name` renders for its consumers, and the
  # interface file of each. `objects` are the platform's other rendered
  # resources, without the Activation record, for each namespace's
  # `platformObjects`.
  platform =
    {
      name,
      cfg,
      allNsNames,
      nsResources,
      mergedInstances,
      clusterInstances,
      peekedMetas,
      isActive,
      mkNamespace,
      objects,
    }:
    let
      consumers = cfg.consumers;

      _checks = lib.mapAttrsToList (
        consumer: c:
        let
          who = "kix: consumers.${consumer}";
          ownerOf =
            ns:
            lib.findFirst (other: other != consumer && consumers.${other}.namespaces ? ${ns}) null (
              builtins.attrNames consumers
            );
        in
        if !isDnsLabel consumer then
          throw "${who}: the consumer name must be a DNS label (lower-case letters, digits and '-')."
        else if !isDnsLabel "${name}-${consumer}" then
          throw "${who}: the consumer's cluster name '${name}-${consumer}' is not a DNS label of at most 63 characters."
        else
          map (
            ns:
            if builtins.elem ns allNsNames then
              throw "${who}.namespaces.${ns}: cluster '${name}' uses namespace '${ns}' itself. A consumer's namespace holds only the consumer's objects; grant another."
            else if ownerOf ns != null then
              throw "${who}.namespaces.${ns}: consumer '${ownerOf ns}' is granted '${ns}' too. Grant each namespace to one consumer."
            else
              null
          ) (builtins.attrNames c.namespaces)
          ++ map (
            s:
            if !(c.namespaces ? ${s.namespace}) then
              throw "${who}.secrets: Secret '${s.name}' is in namespace '${s.namespace}', which is not one of the consumer's namespaces (${builtins.concatStringsSep ", " (builtins.attrNames c.namespaces)})."
            else
              null
          ) c.secrets
      ) consumers;

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

      namespacesOf =
        consumer: lib.mapAttrs (ns: n: mkNamespace (n // { name = ns; })) consumers.${consumer}.namespaces;

      namespaceResources = lib.concatMapAttrs (consumer: _: namespacesOf consumer) consumers;

      # Lets the consumer's pods reach a granted service. Only when the
      # cluster enforces network policy: on a cluster that does not, an
      # allow policy would isolate the service's pods from everyone else.
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
                      "kix.run/consumer" = consumer;
                    };
                    spec = {
                      podSelector.matchLabels = lib.mapAttrs (_: plain) svc.root.spec.selector;
                      policyTypes = [ "Ingress" ];
                      ingress = [
                        {
                          from = [
                            {
                              namespaceSelector.matchExpressions = [
                                {
                                  key = "kubernetes.io/metadata.name";
                                  operator = "In";
                                  values = builtins.attrNames c.namespaces;
                                }
                              ];
                            }
                          ];
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

      platformObjectsIn =
        ns:
        map
          (m: {
            apiVersion = plain m.apiVersion;
            kind = plain m.kind;
            name = plain m.metadata.name;
          })
          (
            builtins.filter (m: plain (m.metadata.namespace or "") == ns) (
              map (r: r.rawManifest) (builtins.filter (r: r ? rawManifest) objects)
            )
          );

      interfaceOf = consumer: c: {
        inherit version consumer;
        platform = name;
        slice = "${name}-${consumer}";
        facts = {
          provider = cfg.cluster.provider;
          k8sVersion = cfg.k8sVersion;
          clusterDomain = cfg.clusterDomain;
          capabilities = cfg.cluster.capabilities;
          networkPolicy = cfg.networkPolicy.enable or false;
        };
        namespaces = lib.mapAttrs (ns: n: {
          inherit (n) labels resourceQuota podSecurity;
          platformObjects = platformObjectsIn ns;
        }) c.namespaces;
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
    builtins.deepSeq _checks {
      resources =
        lib.concatMap (
          ns: [ ns.resource ] ++ lib.optional (ns.quota != null) ns.quota ++ builtins.attrValues ns.netpols
        ) (builtins.attrValues namespaceResources)
        ++ ingressPolicies;
      interfaces = files;
      recordConsumers = lib.mapAttrs (consumer: file: {
        slice = "${name}-${consumer}";
        interface = plain file;
      }) files;
      interfaceFiles = builtins.attrValues files;
    };

  # `kix.interface ./kix-interface/lab1.json`: a cluster module that builds
  # this cluster as the consumer the file describes.
  interface =
    file:
    { lib, ... }:
    let
      data = builtins.fromJSON (builtins.readFile file);
      where = instancePinsLib.relativeFile (toString file);
      facts = data.facts or { };
      # Every capability as a default, so the cluster's own setting wins.
      defaults = v: if builtins.isAttrs v then lib.mapAttrs (_: defaults) v else lib.mkDefault v;
      home = builtins.head (builtins.sort builtins.lessThan (builtins.attrNames data.namespaces));
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
    else if data.namespaces == { } then
      throw "kix.interface: ${where} grants no namespace, so the consumer has nowhere to put its objects."
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
        instances.${home} = builtins.listToAttrs (
          map (i: lib.nameValuePair i.instance { inherit (i) package; }) imports
        );
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
      granted = builtins.attrNames data.namespaces;
      allowedScoped = map (o: "${o.kind}/${o.name}") data.clusterScoped;
      platformObjects = lib.concatLists (
        lib.mapAttrsToList (
          ns: n: map (o: "${groupOf o.apiVersion}/${o.kind}/${ns}/${o.name}") n.platformObjects
        ) data.namespaces
      );
      who =
        m:
        "${plain m.kind} ${
          lib.optionalString (m.metadata ? namespace) "${plain m.metadata.namespace}/"
        }${plain m.metadata.name}";

      # Refuse what the grant does not allow, before anything is deployed.
      refusalOf =
        m:
        let
          ns = if m.metadata ? namespace then plain m.metadata.namespace else null;
          key = "${groupOf (plain m.apiVersion)}/${plain m.kind}/${toString ns}/${plain m.metadata.name}";
        in
        if isKixOwn m then
          null
        else if ns == null && !(builtins.elem "${plain m.kind}/${plain m.metadata.name}" allowedScoped) then
          "${who m} is cluster-scoped, and ${data.platform}'s interface does not let ${name} own it. It allows ${
            if allowedScoped == [ ] then
              "no cluster-scoped objects"
            else
              builtins.concatStringsSep ", " allowedScoped
          }."
        else if ns != null && !(builtins.elem ns granted) then
          "${who m} is in namespace ${ns}. Your namespaces are ${builtins.concatStringsSep " and " granted}."
        else if builtins.elem key platformObjects then
          "${who m} is ${data.platform}'s. Rename the object, or remove it."
        else
          null;
    in
    if loaded == [ ] then
      null
    else if builtins.length loaded > 1 then
      throw "kix: cluster '${name}' loads interfaces of ${builtins.concatStringsSep " and " (builtins.attrNames cfg.interfaces)}. A cluster is one platform's consumer; load one interface."
    else if name != data.slice then
      throw "kix: cluster '${name}' loads ${data.platform}'s interface for '${data.slice}'. Name the cluster '${data.slice}'."
    else
      {
        providedNamespaces = lib.mapAttrs (
          ns: n:
          k8s.mkProvidedNamespace {
            name = ns;
            inherit (n) labels;
          }
        ) data.namespaces;

        recordInterfaces.${data.platform} = {
          inherit (data) consumer;
          path = instancePinsLib.pathInFlake self data.file;
          sha256 = builtins.hashFile "sha256" data.file;
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

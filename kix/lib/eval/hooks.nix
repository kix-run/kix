{
  lib,
  roles,
}:

let
  # Allowed result keys per hook channel. `collectHooks` validates each hook's
  # return value against this map so misspelled keys fail immediately.
  channelResultKeys = {
    workloadInterceptors = [
      "requires"
      "resources"
      "warnings"
      "podSpec"
    ];
    instanceProcessors = [
      "resources"
      "warnings"
    ];
    clusterProcessors = [
      "resources"
      "checks"
      "warnings"
    ];
  };

  defaultPriority = 1000;
in

rec {
  # Map each namespace and instance to its roles and import state from peeked
  # metadata without forcing the instance fixpoint. Validate role names against
  # the registry here so an unknown `meta.roles` entry fails immediately with
  # the declaring instance named.
  buildRolesIndex =
    { instances, peekedMetas }:
    lib.mapAttrs (
      nsName: nsInsts:
      lib.mapAttrs (instName: instCfg: {
        roles = map (roles.assertKnownRole "meta.roles of instance ${nsName}/${instName}") (
          (peekedMetas.${nsName}.${instName}).roles or [ ]
        );
        isImport = (instCfg.package._type or "") == "kix-import";
        autoInstantiatedFor = instCfg._autoInstantiatedFor or null;
      }) nsInsts
    ) instances;

  # Map each annotation domain in `meta.annotationDomains` to its declaring
  # namespace and instance. Operator packages declare the annotation domains
  # they manage (for example, `reflector.v1.k8s.emberstack.com`), and the
  # scorecard's `architecture.annotationDomainOwnership` rule checks consumers
  # against this index. Because annotation domains are upstream operator
  # identifiers, the declarations themselves form the registry and duplicate
  # declarers of the same domain fail immediately.
  buildAnnotationDomainIndex =
    { instances, peekedMetas }:
    builtins.foldl'
      (
        acc: entry:
        builtins.foldl' (
          acc': domain:
          let
            _shape =
              if !(lib.hasInfix "." domain) || lib.hasInfix "/" domain then
                throw (
                  "kix: meta.annotationDomains of instance ${entry.ns}/${entry.inst} contains "
                  + "'${domain}', which is not a valid annotation domain "
                  + "(expected e.g. \"reflector.v1.k8s.emberstack.com\")"
                )
              else
                null;
            existing = acc'.${domain} or null;
          in
          builtins.seq _shape (
            if existing != null then
              throw (
                "kix: annotation domain '${domain}' is declared by two instances: "
                + "${existing.ns}/${existing.inst} and ${entry.ns}/${entry.inst}. "
                + "Exactly one package owns an annotation domain."
              )
            else
              acc'
              // {
                ${domain} = {
                  inherit (entry) ns inst;
                };
              }
          )
        ) acc entry.domains
      )
      { }
      (annotationDomainDeclarers {
        inherit instances peekedMetas;
      });

  annotationDomainDeclarers =
    { instances, peekedMetas }:
    builtins.concatMap (
      nsName:
      builtins.concatMap (
        instName:
        let
          domains = (peekedMetas.${nsName}.${instName}).annotationDomains or [ ];
        in
        if domains == [ ] then
          [ ]
        else
          [
            {
              ns = nsName;
              inst = instName;
              inherit domains;
            }
          ]
      ) (builtins.attrNames instances.${nsName})
    ) (builtins.attrNames instances);

  roleCandidates =
    {
      role,
      rolesIndex,
    }:
    builtins.concatMap (
      nsName:
      builtins.concatMap (
        instName:
        let
          entry = rolesIndex.${nsName}.${instName};
        in
        if builtins.elem role entry.roles then
          [
            {
              ns = nsName;
              inst = instName;
              inherit (entry) isImport;
              autoInstantiatedFor = entry.autoInstantiatedFor or null;
            }
          ]
        else
          [ ]
      ) (builtins.attrNames rolesIndex.${nsName})
    ) (builtins.attrNames rolesIndex);

  # Resolve a role to its provider `{ ns, inst, isImport }`, or null when none
  # is declared. Managed instances take precedence over imports. Reject
  # multiple managed providers, multiple import providers when no managed
  # provider exists, or any managed provider when the environment binding is
  # `"exclusive"`.
  findRoleProvider =
    {
      role,
      rolesIndex,
      clusterRoles ? { },
    }:
    let
      _known = roles.assertKnownRole "findRoleProvider" role;
      candidates = roleCandidates { inherit role rolesIndex; };
      managed = builtins.filter (c: !c.isImport) candidates;
      imports = builtins.filter (c: c.isImport) candidates;
      binding = (clusterRoles.${role} or { }).binding or null;
      envProvider = (clusterRoles.${role} or { }).provider or null;
      fmt =
        cs:
        builtins.concatStringsSep ", " (
          map (
            c:
            "${c.ns}/${c.inst}"
            + lib.optionalString (
              c.autoInstantiatedFor != null
            ) " (auto-instantiated for ${builtins.concatStringsSep ", " c.autoInstantiatedFor})"
          ) cs
        );
    in
    builtins.seq _known (
      if managed != [ ] && binding == "exclusive" then
        throw (
          "kix: role '${role}' is exclusively provided by the environment"
          + lib.optionalString (envProvider != null) " (${envProvider})"
          + ", but managed instance(s) also claim it: ${fmt managed}. "
          + "Remove the conflicting instance or use an environment where this role is not "
          + "already provided. Set cluster.roles.${role}.binding to match that environment."
        )
      else if builtins.length managed > 1 then
        throw (
          "kix: multiple instances declare `meta.roles = [\"${role}\"]`: ${fmt managed}. "
          + "Declare exactly one provider for this role."
        )
      else if managed != [ ] then
        builtins.head managed
      else if builtins.length imports > 1 then
        throw (
          "kix: multiple imports declare role '${role}': ${fmt imports}. "
          + "Declare exactly one environment provider for this role."
        )
      else if imports != [ ] then
        builtins.head imports
      else
        null
    );

  # Validate all `cluster.roles` keys and force provider resolution for every
  # known role so exclusive-binding conflicts and duplicate providers fail even
  # when no consumer requests the role.
  checkRoleBindings =
    {
      clusterRoles,
      rolesIndex,
    }:
    let
      _keys = map (roles.assertKnownRole "cluster.roles") (builtins.attrNames clusterRoles);
      lookups = map (
        role:
        findRoleProvider {
          inherit role rolesIndex clusterRoles;
        }
      ) roles.roleNames;
    in
    builtins.seq (builtins.deepSeq _keys null) (
      builtins.foldl' (acc: l: builtins.seq l acc) null lookups
    );

  # Collect and sort hooks for `channel` by ascending priority, then by name.
  # Each hook is either a function (default priority 1000) or
  # `{ priority ? 1000; fn; }`. For `clusterProcessors`, this order determines
  # the Activation `extraDeps` order and manifest hashes.
  collectHooks =
    config: channel:
    let
      allowedKeys = channelResultKeys.${channel} or (throw "kix: unknown hook channel '${channel}'");

      normalize =
        name: v:
        if builtins.isFunction v then
          {
            inherit name;
            priority = defaultPriority;
            fn = v;
          }
        else if builtins.isAttrs v && v ? fn then
          {
            inherit name;
            priority = v.priority or defaultPriority;
            fn = v.fn;
          }
        else
          throw (
            "kix: hooks.${channel}.${name} must be a function `ctx -> result` "
            + "or `{ priority ? ${toString defaultPriority}; fn; }` (got ${builtins.typeOf v})"
          );

      checkResult =
        name: result:
        if !(builtins.isAttrs result) then
          throw (
            "kix: hooks.${channel}.${name} returned ${builtins.typeOf result}; "
            + "expected an attribute set with keys: ${builtins.concatStringsSep ", " allowedKeys}"
          )
        else
          let
            unknown = builtins.filter (k: !(builtins.elem k allowedKeys)) (builtins.attrNames result);
          in
          if unknown != [ ] then
            throw (
              "kix: hooks.${channel}.${name} returned unknown result keys: "
              + builtins.concatStringsSep ", " unknown
              + ". Allowed keys for this channel: ${builtins.concatStringsSep ", " allowedKeys}"
            )
          else
            result;

      registered = lib.mapAttrsToList normalize ((config.hooks or { }).${channel} or { });
      sorted = lib.sort (
        a: b: if a.priority != b.priority then a.priority < b.priority else a.name < b.name
      ) registered;
    in
    map (h: ctx: checkResult h.name (h.fn ctx)) sorted;

  # Force each check in order. Each check is a lazy value that throws its own
  # error message on failure and evaluates to null on success.
  runChecks = checks: builtins.foldl' (acc: c: builtins.seq c acc) null checks;
}

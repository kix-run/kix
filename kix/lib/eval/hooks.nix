{
  lib,
  roles,
}:

let
  inherit (import ../core/error.nix { inherit lib; }) fail;
  inherit (import ../core/util.nix { inherit lib; }) instanceLabel;
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
                fail {
                  instance = "${entry.ns}/${entry.inst}";
                  message = "meta.annotationDomains contains '${domain}', which is not a valid annotation domain.";
                  fix = "Use a domain such as \"reflector.v1.k8s.emberstack.com\".";
                }
              else
                null;
            existing = acc'.${domain} or null;
          in
          builtins.seq _shape (
            if existing != null then
              fail {
                message = "annotation domain '${domain}' is declared by two instances: ${existing.ns}/${existing.inst} and ${entry.ns}/${entry.inst}.";
                fix = "Exactly one package may own an annotation domain.";
              }
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
      binding = clusterRoles.${role}.binding or null;
      envProvider = clusterRoles.${role}.provider or null;
      fmt =
        cs:
        builtins.concatStringsSep ", " (
          map (c: instanceLabel "${c.ns}/${c.inst}" c.autoInstantiatedFor) cs
        );
    in
    builtins.seq _known (
      if managed != [ ] && binding == "exclusive" then
        fail {
          message =
            "role '${role}' is already provided by the cluster environment"
            + lib.optionalString (envProvider != null) " (${envProvider})"
            + " (cluster.roles.${role}.binding = \"exclusive\"), so Kix cannot also deploy ${fmt managed}.";
          fix =
            "Remove ${fmt managed} from your cluster definition."
            + "\nIf you disabled ${
              if envProvider != null then envProvider else "the environment's '${role}' provider"
            } on this cluster and want ${fmt managed} to replace it, set `cluster.roles.${role}.binding = \"absent\";` in your cluster definition.";
        }
      else if builtins.length managed > 1 then
        fail {
          message = "role '${role}' is claimed by multiple instances (via meta.roles = [ \"${role}\" ]): ${fmt managed}. A cluster can have only one active provider per role.";
          fix = "Keep one of these instances in your cluster definition and remove the others.";
        }
      else if managed != [ ] then
        builtins.head managed
      else if builtins.length imports > 1 then
        fail {
          message = "role '${role}' is claimed by multiple kix.mkImport instances: ${fmt imports}. A cluster can have only one environment import per role.";
          fix = "Keep one import for role '${role}' and remove the others.";
        }
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
      allowedKeys = channelResultKeys.${channel} or (fail "unknown hook channel '${channel}'.");

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
          fail "hooks.${channel}.${name} must be a function `ctx -> result` or `{ priority ? ${toString defaultPriority}; fn; }` (got ${builtins.typeOf v}).";

      checkResult =
        name: result:
        if !(builtins.isAttrs result) then
          fail "hooks.${channel}.${name} returned ${builtins.typeOf result}, and it must return an attribute set with keys: ${builtins.concatStringsSep ", " allowedKeys}."
        else
          let
            unknown = builtins.filter (k: !(builtins.elem k allowedKeys)) (builtins.attrNames result);
          in
          if unknown != [ ] then
            fail {
              message = "hooks.${channel}.${name} returned unknown result keys: ${builtins.concatStringsSep ", " unknown}.";
              fix = "Return only these keys for this channel: ${builtins.concatStringsSep ", " allowedKeys}.";
            }
          else
            result;

      registered = lib.mapAttrsToList normalize (config.hooks.${channel} or { });
      sorted = lib.sort (
        a: b: if a.priority != b.priority then a.priority < b.priority else a.name < b.name
      ) registered;
    in
    map (h: ctx: checkResult h.name (h.fn ctx)) sorted;

  # Force each check in order. Each check is a lazy value that throws its own
  # error message on failure and evaluates to null on success.
  runChecks = checks: builtins.foldl' (acc: c: builtins.seq c acc) null checks;
}

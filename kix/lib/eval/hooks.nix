{
  lib,
  meta,
  kixlib,
  roles,
}:

let
  # Per-channel result contracts. Every hook result is shape-checked at the
  # call site; unknown keys throw with the hook's full name so a typo'd key
  # fails loudly instead of being silently ignored.
  channelResultKeys = {
    workloadInterceptors = [
      "requires"
      "resources"
      "warnings"
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
  # ns → inst → { roles, isImport }, built from peeked meta (phase-1 timing,
  # no fixpoint). Role names are validated against the registry here, so a
  # typo'd `meta.roles` entry throws with the declaring instance named
  # instead of silently never matching (the meta.provides failure mode).
  buildRolesIndex =
    instances:
    lib.mapAttrs (
      nsName: nsInsts:
      lib.mapAttrs (
        instName: instCfg:
        let
          packageMeta = meta.peekPackageMeta {
            package = instCfg.package;
            inherit kixlib;
          };
        in
        {
          roles = map (roles.assertKnownRole "meta.roles of instance ${nsName}/${instName}") (
            packageMeta.roles or [ ]
          );
          isImport = (instCfg.package._type or "") == "kix-import";
        }
      ) nsInsts
    ) instances;

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
            }
          ]
        else
          [ ]
      ) (builtins.attrNames rolesIndex.${nsName})
    ) (builtins.attrNames rolesIndex);

  # Resolve a role to its provider. Managed instances are strong symbols,
  # imports weak (mirrors the DI managed-over-import filter). Two strong
  # providers never coexist — whether both are managed, or one is the
  # environment (binding = "exclusive"). Returns { ns, inst, isImport } or
  # null; the out-contract wrapper lives at the cluster.nix call site.
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
      fmt = cs: builtins.concatStringsSep ", " (map (c: "${c.ns}/${c.inst}") cs);
    in
    builtins.seq _known (
      if managed != [ ] && binding == "exclusive" then
        throw (
          "kix: role '${role}' is exclusively provided by the environment"
          + lib.optionalString (envProvider != null) " (${envProvider})"
          + ", but managed instance(s) also claim it: ${fmt managed}. "
          + "Two strong providers cannot coexist — switch to a target where the role is not "
          + "environment-owned (cluster.roles.${role}.binding = \"absent\"), or drop the managed instance."
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

  # Eager refusal pass, seq-forced by buildCluster: exclusive-binding
  # conflicts and duplicate strong providers throw even when nothing looks
  # the role up this eval (a broken combination must not compile just
  # because its consumer is absent). Also validates cluster.roles keys.
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

  # Hook execution order is (priority ascending, then name) — never bare
  # attribute-name order. A hook is either a plain function (priority 1000)
  # or { priority ? 1000; fn; }. This order is a contract: for
  # clusterProcessors it determines Activation extraDeps order, which is
  # content-addressed into the manifest set.
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
            + "expected an attrset with keys: ${builtins.concatStringsSep ", " allowedKeys}"
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

  # Force each check in order. A check is any lazy value that throws its own
  # error message on failure and evaluates to anything (conventionally null)
  # on success — so validators keep authorship of their messages instead of
  # being squeezed into an assertion/message pair.
  runChecks = checks: builtins.foldl' (acc: c: builtins.seq c acc) null checks;
}

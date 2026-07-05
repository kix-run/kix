{
  lib,
  meta,
  kixlib,
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

{
  buildProvidesIndex =
    instances:
    lib.mapAttrs (
      _nsName: nsInsts:
      lib.mapAttrs (
        _instName: instCfg:
        (meta.peekPackageMeta {
          package = instCfg.package;
          inherit kixlib;
        }).provides or [ ]
      ) nsInsts
    ) instances;

  findCapabilityProvider =
    {
      capability,
      providesIndex,
    }:
    let
      candidates = builtins.concatMap (
        nsName:
        builtins.concatMap (
          instName:
          if builtins.elem capability providesIndex.${nsName}.${instName} then
            [
              {
                ns = nsName;
                inst = instName;
              }
            ]
          else
            [ ]
        ) (builtins.attrNames providesIndex.${nsName})
      ) (builtins.attrNames providesIndex);
    in
    if candidates == [ ] then
      null
    else if builtins.length candidates > 1 then
      throw (
        "kix: multiple instances advertise `meta.provides = [\"${capability}\"]`: "
        + builtins.concatStringsSep ", " (map (c: "${c.ns}/${c.inst}") candidates)
        + ". Declare exactly one provider for this capability."
      )
    else
      builtins.head candidates;

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

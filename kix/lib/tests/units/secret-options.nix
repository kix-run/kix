# Tests that no package Kix ships takes a secret value through an option.
# A package takes every secret through a secret dependency
# (kix.contracts.secret), so the site chooses where the value comes from.
# The check reads each package's option declarations: an option of type
# `path`, or a string option whose name says it holds a credential, fails.
# `kix/packages/not-secret.nix` lists the options that match and are not
# secrets.

{
  lib,
  eval,
  kixlib,
  ...
}:

let
  packagesByLevel = import ../../../packages/by-level.nix { inherit lib; };
  notSecret = import ../../../packages/not-secret.nix;

  # A scope with the values option declarations read for their defaults.
  # Defaults are never forced here, only names and types.
  stubScope = {
    instanceName = "inst";
    namespaceName = "ns";
  };

  optionsOf =
    package:
    (eval.callPackagePhase1 {
      inherit package;
      scope = stubScope;
    }).options or { };

  # Return `[ { path; type; } ]` for every visible option under `opts`.
  # A hidden option only refuses a removed name, so it is skipped.
  walk =
    prefix: opts:
    lib.concatLists (
      lib.mapAttrsToList (
        name: v:
        let
          path = if prefix == "" then name else "${prefix}.${name}";
        in
        if (v._type or null) == "option" then
          lib.optionals (v.visible or true != false) (
            [
              {
                inherit path;
                type = v.type or null;
              }
            ]
            ++ walk path (subOptionsOf (v.type or null))
          )
        else if builtins.isAttrs v && !(v ? _type) then
          walk path v
        else
          [ ]
      ) opts
    );

  # The type under any `nullOr`.
  baseType = t: if t != null && t.name == "nullOr" then baseType t.nestedTypes.elemType else t;

  # The options a submodule declares, under any `nullOr`, `listOf`, or
  # `attrsOf`, or `{ }` for any other type.
  subOptionsOf =
    t:
    if t == null then
      { }
    else if
      builtins.elem t.name [
        "nullOr"
        "listOf"
        "attrsOf"
        "lazyAttrsOf"
      ]
    then
      subOptionsOf (t.nestedTypes.elemType or null)
    else if t.name == "submodule" then
      removeAttrs (t.getSubOptions [ ]) [ "_module" ]
    else
      { };

  isPathType = t: t != null && (baseType t).name == "path";
  isStringType =
    t:
    t != null
    && builtins.elem (baseType t).name [
      "str"
      "nonEmptyStr"
      "singleLineStr"
      "strMatching"
      "passwdEntry"
    ];

  credentialName =
    path:
    builtins.match "(.*[a-z])?(password|passwd|token|apikey|apiKey|secretKey|privateKey|secret|credential|credentials)[A-Za-z]*" (
      lib.last (lib.splitString "." path)
    ) != null
    ||
      builtins.match ".*(Password|Token|ApiKey|SecretKey|PrivateKey|Secret|Credential|Credentials)[A-Za-z]*" (
        lib.last (lib.splitString "." path)
      ) != null;

  offendersOf =
    pkgName: package:
    map (o: "${pkgName}.${o.path}") (
      builtins.filter (
        o:
        !(notSecret ? "${pkgName}.${o.path}")
        && (isPathType o.type || (isStringType o.type && credentialName o.path))
      ) (walk "" (optionsOf package))
    );

  allPackages = packagesByLevel.stable // packagesByLevel.experimental;
  offenders = lib.concatLists (lib.mapAttrsToList offendersOf allPackages);

  # Entries in not-secret.nix that name no option, so the list stays true.
  known = lib.concatLists (
    lib.mapAttrsToList (n: p: map (o: "${n}.${o.path}") (walk "" (optionsOf p))) allPackages
  );
  stale = builtins.filter (k: !(builtins.elem k known)) (builtins.attrNames notSecret);
in
{
  secret-options-none-take-a-secret =
    offenders == [ ]
    || throw "These package options take a secret value, or a path to one: ${lib.concatStringsSep ", " offenders}. Take the value through a secret dependency instead, read with kix.contracts.secret.helpers.use, so the site chooses where it comes from (packages.secret, packages.secret-ref, or another source package). If an option only matches by name and holds no secret, add it to kix/packages/not-secret.nix with the reason.";

  secret-options-allowlist-is-current =
    stale == [ ]
    || throw "kix/packages/not-secret.nix lists options that no package has: ${lib.concatStringsSep ", " stale}. Remove them.";

  # The contract accepts what the source packages build, and the helper
  # refuses a dependency that is not a secret.
  secret-options-helper-refuses-a-non-secret =
    !(builtins.tryEval (
      kixlib.contracts.secret.helpers.use {
        who = "test";
        arg = "password";
        dep = {
          out.name = "x";
        };
      }
    )).success
    || throw "contracts.secret.helpers.use accepted a dependency without keyRef";
}

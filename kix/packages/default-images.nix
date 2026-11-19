# Return the default image of every image option each package declares, as
# `{ stable = { <package> = [ { path; repository; tag; digest; } ]; }; experimental = ...; }`.
# The walk finds the options that `kix.options.image` builds, at any depth,
# by their submodule fields. `repository` or `tag` is null for an option
# with no default image.
{ lib }:
let
  kixlib = import ../lib/vocab { inherit lib; };
  packagesByLevel = import ./by-level.nix { inherit lib; };

  # A scope with the values option declarations read for their defaults.
  stubScope = {
    instanceName = "inst";
    namespaceName = "ns";
  };

  optionsOf =
    package:
    let
      fnArgs = builtins.functionArgs package;
      result = package (
        {
          scope = stubScope;
          inherit lib;
        }
        // lib.optionalAttrs (fnArgs ? kix) { kix = kixlib; }
        // lib.optionalAttrs (fnArgs ? availability) { availability = "none"; }
      );
    in
    result.options or { };

  # Return the options a submodule declares, under any `nullOr`, `listOf`,
  # or `attrsOf`, or `{ }` for any other type.
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

  isImageOption =
    v:
    let
      subs = subOptionsOf (v.type or null);
    in
    subs ? repository && subs ? tag && subs ? digest && subs ? pullPolicy;

  imagesIn =
    prefix: opts:
    lib.concatLists (
      lib.mapAttrsToList (
        name: v:
        let
          path = if prefix == "" then name else "${prefix}.${name}";
          d = v.default or { };
        in
        if (v._type or null) == "option" then
          if isImageOption v then
            [
              {
                inherit path;
                repository = d.repository or null;
                tag = d.tag or null;
                digest = d.digest or null;
              }
            ]
          else
            imagesIn path (subOptionsOf (v.type or null))
        else if builtins.isAttrs v && !(v ? _type) then
          imagesIn path v
        else
          [ ]
      ) opts
    );
in
lib.genAttrs [ "stable" "experimental" ] (
  level: lib.mapAttrs (_: package: imagesIn "" (optionsOf package)) packagesByLevel.${level}
)

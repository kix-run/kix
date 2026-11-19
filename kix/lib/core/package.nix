# Recognize the values a cluster definition may give as a package, and call
# them. An instance's `package` is one of:
#
# - a package function, `{ scope, lib, ... }: { meta, options, build }`
# - a package of Kix's own set, which is such a function with an id (`withId`)
# - an inline package, an attribute set with `build`
# - an import, which `kix.mkImport` returns
# - a marker for a package that moved or was removed, which carries an error
{ lib }:
let
  inherit (import ./error.nix { inherit lib; }) fail;

  typeOf = value: if builtins.isAttrs value then value._type or "" else "";
in
rec {
  # Name the arguments Kix passes to a package function. Any other argument
  # of a package function is not a package argument.
  systemArgNames = [
    "scope"
    "lib"
    "kix"
    "availability"
  ];

  # Return the package function `fn` as a package of Kix's own set. The
  # result is called like `fn`, and `lib.functionArgs` returns the arguments
  # `fn` names. `id` is the name change records give the package: the folder
  # name for a stable package, and `experimental/<name>` for an experimental
  # one.
  withId =
    id: fn:
    lib.setFunctionArgs fn (lib.functionArgs fn)
    // {
      _type = "kix-package";
      inherit id;
    };

  # Return the id of a package of Kix's own set, or null for any other
  # package. A function that calls such a package is another package, and
  # has no id.
  idOf = value: if typeOf value == "kix-package" then value.id else null;

  isImport = value: typeOf value == "kix-import";

  # Return whether `value` stands for a package that moved or was removed.
  isRefused =
    value:
    builtins.elem (typeOf value) [
      "kix-moved"
      "kix-removed"
    ];

  # `lib.isFunction` accepts a package of Kix's own set, which is an
  # attribute set that can be called. `builtins.isFunction` does not.
  isFunction = lib.isFunction;

  isInline = value: builtins.isAttrs value && value ? build && !isImport value && !isFunction value;

  # Return whether `value` is a package an instance can run.
  isPackage = value: isFunction value || isImport value || isInline value;

  # Return the arguments a package function names, or none for a package
  # that is not a function.
  argsOf = package: if isFunction package then lib.functionArgs package else { };

  # Return whether a package function names the argument `name`.
  takes = package: name: argsOf package ? ${name};

  # Return what a package defines: `meta`, `options`, `config`, and `build`.
  # A package function receives `scope` and `lib`, and `kix` and
  # `availability` when it names them. `extraArgs` adds arguments that the
  # caller knows the function names.
  call =
    {
      package,
      scope,
      kix,
      availability ? "none",
      extraArgs ? { },
    }:
    if isRefused package then
      fail package.error
    else if isFunction package then
      package (
        {
          inherit scope lib;
        }
        // lib.intersectAttrs (argsOf package) { inherit kix availability; }
        // extraArgs
      )
    else
      package;

  # Return a package's `meta` without building it. A package function is
  # called with an empty scope and `availability = "none"`, so `meta` must
  # not depend on either. This runs before the availability level of an
  # instance is known.
  metaOf =
    { package, kix }:
    (call {
      inherit package kix;
      scope = { };
    }).meta or { };
}

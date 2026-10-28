# Enforce the package option contract so that package defaults survive
# when an instance sets only part of an option.
# The module system replaces an attrset default as a whole when any
# definition exists, so the following declarations lose package defaults:
#
#   - Rule 1: an untyped option (`anything`, `unspecified`, `raw`, `attrs`, or
#     `attrsOf` of one of those) with a non-empty attrset default.
#   - Rule 2: an `attrsOf` or `lazyAttrsOf` of any other type with a non-empty
#     default.
#   - Rule 3: a submodule whose own default sets a key that its field does not
#     default to the same value.
#
# `optionContractViolations` walks a package's raw `options` declaration,
# including submodule fields, and returns one entry per violation.
# `checkOptionContract` throws when any violations exist.
# `kix.checkPackageOptions` (eval/package-options.nix) runs this check at
# each availability level during package CI and `mkFlake`.
# Unreadable declarations also count as violations, including defaults or
# submodules that throw, unknown `_type` wrappers, uncovered attrset types,
# non-option entries, and nesting deeper than `maxDepth`.
{ lib }:

let
  # Recursive submodule types stop at the first repeated declaration on the
  # current path. This bound guards against recursive types whose options lack
  # declaration positions.
  maxDepth = 12;

  isOption = v: builtins.isAttrs v && (v._type or "") == "option";

  untypedNames = [
    "anything"
    "unspecified"
    "raw"
    "attrs"
  ];

  attrsNames = [
    "attrsOf"
    "lazyAttrsOf"
  ];

  # Strip wrapper types that only constrain the inner type.
  unwrap =
    t:
    if
      builtins.elem (t.name or "") [
        "nullOr"
        "uniq"
        "unique"
      ]
      && t ? nestedTypes.elemType
    then
      unwrap t.nestedTypes.elemType
    else
      t;

  # Return the unwrapped alternatives of an `either` or `oneOf` type.
  branches =
    t:
    let
      u = unwrap t;
    in
    if (u.name or "") == "either" && u ? nestedTypes.left && u ? nestedTypes.right then
      branches u.nestedTypes.left ++ branches u.nestedTypes.right
    else
      [ u ];

  isCoercedTo = t: (t.name or "") == "coercedTo" && t ? nestedTypes.finalType;

  # Return the type alternatives that can hold the default `d`.
  # When `coercedType` rejects `d`, `coercedTo` stores `d` as `finalType`,
  # so inspect `finalType` instead.
  branchesFor =
    d: t:
    builtins.concatMap (
      b:
      let
        coerced = builtins.tryEval (b.nestedTypes.coercedType.check d);
      in
      if isCoercedTo b && coerced.success && !coerced.value then
        branchesFor d b.nestedTypes.finalType
      else
        [ b ]
    ) (branches t);

  # Report whether any alternative of `t` can accept an attrset.
  # `attrTag` rejects `{ }` when probed, so check for it by name.
  holdsAttrs =
    t:
    builtins.any (
      b:
      let
        r = builtins.tryEval (b.check { });
      in
      classify b != null
      || isCoercedTo b
      || (b.name or "") == "attrTag"
      || !(r.success && r.value == false)
    ) (branches t);

  classify =
    t:
    let
      n = t.name or "";
    in
    if builtins.elem n untypedNames then
      "rule1"
    else if builtins.elem n attrsNames then
      (
        if builtins.elem ((unwrap (t.nestedTypes.elemType or { })).name or "") untypedNames then
          "rule1"
        else
          "rule2"
      )
    else if n == "submodule" then
      "rule3"
    else
      null;

  typeText = t: t.description or t.name or "unknown";

  # Unwrap module-system wrappers (`mkOverride`, `mkOrder`, `mkMerge`, `mkIf`)
  # from an option default. Return a list of underlying values, or an error
  # string for unrecognized `_type` wrappers.
  defaultValues =
    d:
    let
      kind = if builtins.isAttrs d then d._type or null else null;
      all =
        parts:
        let
          bad = builtins.filter builtins.isString parts;
        in
        if bad != [ ] then builtins.head bad else builtins.concatLists parts;
    in
    if kind == null then
      [ d ]
    else if kind == "override" || kind == "order" then
      defaultValues d.content
    else if kind == "merge" then
      all (map defaultValues d.contents)
    else if kind == "if" && d.condition == true then
      defaultValues d.content
    else if kind == "if" && d.condition == false then
      [ ]
    else if kind == "if" then
      "its default is a lib.mkIf whose condition is not a boolean"
    else
      "its default is a value of _type \"${toString kind}\", which the check does not read";

  # Return the non-empty attrset values in an option's default, or
  # `{ unreadable = <reason>; }`. Ignore derivations because `types.package`
  # does not merge them as attrsets.
  attrsDefaults =
    opt:
    let
      r = builtins.tryEval (
        let
          vs = defaultValues opt.default;
          kept = builtins.filter (v: builtins.isAttrs v && v != { } && !(lib.isDerivation v)) vs;
        in
        if builtins.isString vs then vs else builtins.seq (builtins.length kept) kept
      );
    in
    if !(opt ? default) then
      [ ]
    else if !r.success then
      { unreadable = "evaluating its default throws"; }
    else if builtins.isString r.value then
      { unreadable = r.value; }
    else
      r.value;

  showKeys = attrs: lib.concatStringsSep ", " (builtins.attrNames attrs);

  showValue =
    v:
    let
      r = builtins.tryEval (lib.generators.toPretty { multiline = false; } v);
    in
    if r.success then r.value else "a value that cannot be shown";

  # Evaluate submodule type `t` with `{ }` to collect its field defaults, or
  # return null if evaluation fails.
  fieldDefaults =
    t:
    let
      r =
        builtins.tryEval
          (lib.evalModules {
            modules = [
              {
                options.v = lib.mkOption {
                  type = t;
                  default = { };
                };
              }
            ];
          }).config.v;
    in
    if r.success && builtins.isAttrs r.value then r.value else null;

  # Compare a submodule option's default (`want`) against its field defaults
  # (`got`) and return any mismatches.
  rule3Problems =
    prefix: want: got:
    builtins.concatLists (
      lib.mapAttrsToList (
        key: wanted:
        let
          path = prefix ++ [ key ];
          declared = got ? ${key};
          field = builtins.tryEval (
            let
              v = got.${key};
            in
            builtins.seq v v
          );
          fieldValue = field.value;
          bothAttrs = builtins.isAttrs wanted && builtins.isAttrs fieldValue && !(wanted ? _type);
          same = builtins.tryEval (builtins.deepSeq fieldValue (wanted == fieldValue));
        in
        if !declared then
          [
            {
              inherit path;
              kind = "undeclared";
            }
          ]
        else if !field.success then
          [
            {
              inherit path;
              kind = "noDefault";
            }
          ]
        else if bothAttrs then
          rule3Problems path wanted fieldValue
        else if same.success && same.value then
          [ ]
        else
          [
            {
              inherit path;
              kind = "differs";
              value = fieldValue;
            }
          ]
      ) want
    );

  remedies =
    name:
    "Declare `${name}` as a submodule whose fields carry their defaults (for container resources, `kix.options.resources`), "
    + "or default it to null, apply the package's value in the build, and give it a defaultText naming that value.";

  rule1Message =
    name: t: d:
    "option `${name}` has type `${typeText t}` and a non-empty default (keys: ${showKeys d}). "
    + "An instance that sets any part of `${name}` replaces the whole default, and misspelled keys are accepted. "
    + remedies name;

  rule2Message =
    name: t: d:
    "option `${name}` (${typeText t}) has a non-empty default (keys: ${showKeys d}). "
    + "An instance that sets one key replaces the whole default, and the package's entries disappear without a message. "
    + "To keep them unless overridden, default `${name}` to { } and set each entry in the package's `config` with lib.mkDefault. "
    + "If an instance should replace them as a whole (a selector), default it to null and apply the package's value in the build when null. "
    + "Either way, give `${name}` a defaultText naming the package's value.";

  rule3Message =
    name: problem:
    let
      key = lib.concatStringsSep "." problem.path;
      field = "${name}.${key}";
    in
    if problem.kind == "undeclared" then
      "option `${name}` is a submodule whose own default sets `${key}`, but `${key}` is not a declared field, so any instance value discards it. "
      + remedies name
    else
      "option `${name}` is a submodule whose own default sets `${key}`, but the field `${field}` "
      + (
        if problem.kind == "noDefault" then
          "has no default"
        else
          "has the default ${showValue problem.value}"
      )
      + ". An instance that sets any field discards the option's default, so `${key}` falls back to the field. "
      + "Put the value on the field's `default` and give `${name}` the default { }.";

  unreadableMessage =
    name: reason:
    "option `${name}` cannot be checked against the option contract: ${reason}. "
    + "Change the declaration so the check can read it; an unread declaration fails the check.";

  unknownTypeMessage =
    name: t: d:
    "option `${name}` has type `${typeText t}` and a non-empty attrset default (keys: ${showKeys d}), "
    + "and the option contract has no rule for that type, so the check cannot tell whether an instance that sets part of `${name}` keeps the rest. "
    + remedies name;

  showPos = pos: if pos == null then "<unknown position>" else "${pos.file}:${toString pos.line}";

  subPosition =
    fallback: opt:
    let
      r = builtins.tryEval (
        let
          ps = opt.declarationPositions or [ ];
        in
        if builtins.isList ps && ps != [ ] then builtins.head ps else fallback
      );
    in
    if r.success then r.value else fallback;

  checkOne =
    { path, pos }:
    opt:
    let
      name = lib.concatStringsSep "." path;
      mk = message: {
        inherit path message;
        head = builtins.head path;
        position = pos;
      };
      # mkOption without `type` merges as `types.unspecified`.
      type = opt.type or lib.types.unspecified;
      defaults = attrsDefaults opt;
      perBranch =
        d: t:
        let
          rule = classify t;
        in
        if rule == "rule1" then
          [ (mk (rule1Message name t d)) ]
        else if rule == "rule2" then
          [ (mk (rule2Message name t d)) ]
        else
          let
            got = fieldDefaults t;
          in
          if got == null then
            [
              (mk (
                unreadableMessage name "it is a submodule with a non-empty default, and evaluating its fields with the value { } throws"
              ))
            ]
          else
            map (p: mk (rule3Message name p)) (rule3Problems [ ] d got);
      checkValue =
        d:
        let
          covered = builtins.filter (t: classify t != null) (branchesFor d type);
        in
        if covered == [ ] then
          [ (mk (unknownTypeMessage name type d)) ]
        else
          lib.findFirst (xs: xs != [ ]) [ ] (map (perBranch d) covered);
    in
    if !(holdsAttrs type) then
      [ ]
    else if defaults ? unreadable then
      [ (mk (unreadableMessage name defaults.unreadable)) ]
    else
      builtins.concatMap checkValue defaults;

  # Extract submodule fields and the path segment for `attrsOf` or `listOf` elements.
  subOptions =
    opt:
    let
      u = unwrap (opt.type or { });
      t = if isCoercedTo u then unwrap u.nestedTypes.finalType else u;
      n = t.name or "";
      segment =
        if builtins.elem n attrsNames then
          [ "<name>" ]
        else if n == "listOf" then
          [ "*" ]
        else
          [ ];
      r = builtins.tryEval (
        if t ? getSubOptions then
          let
            s = t.getSubOptions [ ];
          in
          if builtins.isAttrs s then removeAttrs s [ "_module" ] else { }
        else
          { }
      );
    in
    {
      inherit segment;
      ok = r.success;
      options = if r.success then r.value else { };
    };

  # Build a position key (`<name>@<file>:<line>:<column>`) to detect recursive
  # submodule options.
  declarationKey =
    n: opt:
    let
      r = builtins.tryEval (
        let
          ps = opt.declarationPositions or [ ];
          p = if builtins.isList ps && ps != [ ] then builtins.head ps else { };
        in
        if (p.line or null) == null then
          null
        else
          "${n}@${toString p.file}:${toString p.line}:${toString (p.column or 0)}"
      );
    in
    if r.success then r.value else null;

  # Walk an option tree and return contract violations, using `seen` to stop at
  # recursive submodule declarations.
  walk =
    depth: seen: path: pos: node:
    let
      name = lib.concatStringsSep "." path;
      mk = message: {
        inherit path message;
        head = if path == [ ] then "<options>" else builtins.head path;
        position = pos;
      };
    in
    if depth > maxDepth then
      [
        (mk (unreadableMessage name "it is nested more than ${toString maxDepth} option levels deep"))
      ]
    else if isOption node then
      let
        subs = subOptions node;
        here = checkOne { inherit path pos; } node;
        child =
          n: opt:
          let
            key = declarationKey n opt;
          in
          if key != null && builtins.elem key seen then
            [ ]
          else
            walk (depth + 1) (seen ++ lib.optional (key != null) key) (
              path ++ subs.segment ++ [ n ]
            ) (subPosition pos opt) opt;
        below =
          if !subs.ok then
            [ (mk (unreadableMessage name "reading the fields of its type throws")) ]
          else
            lib.concatLists (lib.mapAttrsToList child subs.options);
      in
      here ++ below
    else if builtins.isAttrs node && !(node ? _type) then
      lib.concatLists (
        lib.mapAttrsToList (
          n: child: walk depth seen (path ++ [ n ]) (builtins.unsafeGetAttrPos n node) child
        ) node
      )
    else
      [
        (mk (
          (if path == [ ] then "`options`" else "`${name}` in `options`")
          + " is not an option declaration or an attrset of them (found "
          + (
            if builtins.isAttrs node then
              "a value of _type \"${toString node._type}\""
            else
              "a value of type ${builtins.typeOf node}"
          )
          + "). Declare it with lib.mkOption."
        ))
      ];

  optionContractViolations =
    { options }:
    map (v: v // { message = "${showPos v.position}: ${v.message}"; }) (walk 0 [ ] [ ] null options);
in
{
  inherit optionContractViolations;

  # Throw if `options` violates the option contract.
  checkOptionContract =
    { who, options }:
    let
      violations = optionContractViolations { inherit options; };
    in
    if violations == [ ] then
      null
    else
      throw (
        "the options of ${who} break the option contract (docs: reference/package-schema/options, \"Option contract\"):\n"
        + lib.concatMapStringsSep "\n" (v: "  - ${v.message}") violations
      );
}

# The option contract: a package option's default must survive an instance
# that sets only part of the option. The module system replaces an attrset
# default as a whole when any definition exists, so these declarations lose
# the package's values:
#
#   Rule 1: an untyped option (`anything`, `unspecified`, `raw`, `attrs`, or
#           `attrsOf` of one of those) with a non-empty attrset default.
#   Rule 2: an `attrsOf`/`lazyAttrsOf` of any other type with a non-empty
#           default.
#   Rule 3: a submodule whose own default sets a key that its field does not
#           default to the same value.
#
# `optionContractViolations` walks a package's raw `options` declaration,
# including submodule fields, and returns one entry per violation.
# `checkOptionContract` throws when there is any. Package CI runs the check
# once per package (kix/package-eval.nix); instance evaluation does not.
# A declaration the walker cannot read is a violation too: a default or a
# submodule that throws, an attrset default on a type the rules do not
# cover, an entry that is not an option, and anything nested deeper than
# `maxDepth`.
{ lib }:

let
  # Bounds the walk through recursive submodule types.
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

  # Types that only constrain the value of the type they wrap.
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

  # The alternatives of an `either`/`oneOf`, each unwrapped.
  branches =
    t:
    let
      u = unwrap t;
    in
    if (u.name or "") == "either" && u ? nestedTypes.left && u ? nestedTypes.right then
      branches u.nestedTypes.left ++ branches u.nestedTypes.right
    else
      [ u ];

  # "rule1", "rule2", "rule3" or null for a type that merges an attrset
  # default with an instance value, or takes no attrset.
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

  # `{ ok = true; value; }` with the default when it is a non-empty
  # attrset and null otherwise, or `{ ok = false; }` when forcing the
  # default throws. Only the top level is forced. A derivation default
  # (`types.package`) is not an attrset the module system merges.
  attrsDefault =
    opt:
    if !(opt ? default) then
      {
        ok = true;
        value = null;
      }
    else
      let
        r = builtins.tryEval (
          let
            d = opt.default;
          in
          if builtins.isAttrs d && d != { } && !(d ? _type) && !(lib.isDerivation d) then d else null
        );
      in
      if r.success then
        {
          ok = true;
          inherit (r) value;
        }
      else
        { ok = false; };

  showKeys = attrs: lib.concatStringsSep ", " (builtins.attrNames attrs);

  showValue =
    v:
    let
      r = builtins.tryEval (lib.generators.toPretty { multiline = false; } v);
    in
    if r.success then r.value else "a value that cannot be shown";

  # The value each field of submodule type `t` takes when the option is set
  # to { }, or null when that cannot be evaluated.
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

  # One problem per key of `want` (an option's own default) that the field
  # defaults in `got` do not reproduce. `prefix` is the key path so far.
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

  # The declaration position of an option returned by getSubOptions, or
  # `fallback` when it carries none.
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
      dr = attrsDefault opt;
      d = dr.value;
      name = lib.concatStringsSep "." path;
      mk = message: {
        inherit path message;
        head = builtins.head path;
        position = pos;
      };
      # mkOption without `type` merges as `types.unspecified`.
      type = opt.type or lib.types.unspecified;
      perBranch =
        t:
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
      # The alternatives a rule covers; the first whose rule the default
      # breaks is reported.
      covered = builtins.filter (t: classify t != null) (branches type);
    in
    if !dr.ok then
      [ (mk (unreadableMessage name "evaluating its default throws")) ]
    else if d == null then
      [ ]
    else if covered == [ ] then
      [ (mk (unknownTypeMessage name type d)) ]
    else
      lib.findFirst (xs: xs != [ ]) [ ] (map perBranch covered);

  # The fields of a submodule-typed option, and the path segment that stands
  # for one element of an attrsOf or listOf.
  subOptions =
    opt:
    let
      t = unwrap (opt.type or { });
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

  walk =
    depth: path: pos: node:
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
        below =
          if !subs.ok then
            [ (mk (unreadableMessage name "reading the fields of its type throws")) ]
          else
            lib.concatLists (
              lib.mapAttrsToList (
                n: child: walk (depth + 1) (path ++ subs.segment ++ [ n ]) (subPosition pos child) child
              ) subs.options
            );
      in
      here ++ below
    else if builtins.isAttrs node && !(node ? _type) then
      lib.concatLists (
        lib.mapAttrsToList (
          n: child: walk depth (path ++ [ n ]) (builtins.unsafeGetAttrPos n node) child
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
    map (v: v // { message = "${showPos v.position}: ${v.message}"; }) (walk 0 [ ] null options);
in
{
  inherit optionContractViolations;

  # Throws when `options` breaks the contract; `who` names the package, such
  # as `kix/packages/caddy`.
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

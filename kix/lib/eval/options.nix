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
# `checkOptionContract` throws when there is any. The walker runs inside
# every cluster that uses a package, so it guards each access and catches
# the throws it can; a declaration it cannot read is skipped, not reported.
{ lib }:

let
  maxDepth = 6;

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

  # The default when it is a non-empty attrset, otherwise null. Only the
  # top level is forced.
  attrsDefault =
    opt:
    if !(opt ? default) then
      null
    else
      let
        r = builtins.tryEval (
          let
            d = opt.default;
          in
          if builtins.isAttrs d && d != { } && !(d ? _type) then d else null
        );
      in
      if r.success then r.value else null;

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
      r = builtins.tryEval
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
      + (if problem.kind == "noDefault" then "has no default" else "has the default ${showValue problem.value}")
      + ". An instance that sets any field discards the option's default, so `${key}` falls back to the field. "
      + "Put the value on the field's `default` and give `${name}` the default { }.";

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
      d = attrsDefault opt;
      name = lib.concatStringsSep "." path;
      mk = message: {
        inherit path message;
        head = builtins.head path;
        position = pos;
      };
      # The first alternative whose rule the default breaks.
      perBranch =
        t:
        let
          rule = classify t;
        in
        if rule == "rule1" then
          [ (mk (rule1Message name t d)) ]
        else if rule == "rule2" then
          [ (mk (rule2Message name t d)) ]
        else if rule == "rule3" then
          let
            got = fieldDefaults t;
          in
          if got == null then [ ] else map (p: mk (rule3Message name p)) (rule3Problems [ ] d got)
        else
          [ ];
      found = lib.findFirst (xs: xs != [ ]) [ ] (map perBranch (branches opt.type));
    in
    if d == null || !(opt ? type) then [ ] else found;

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
      options = if r.success then r.value else { };
    };

  walk =
    depth: path: pos: node:
    if depth > maxDepth then
      [ ]
    else if isOption node then
      let
        subs = subOptions node;
        here = checkOne { inherit path pos; } node;
        below = lib.concatLists (
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
      [ ];

  optionContractViolations =
    { options }:
    map (v: v // { message = "${showPos v.position}: ${v.message}"; }) (
      walk 0 [ ] null (if builtins.isAttrs options then options else { })
    );
in
{
  inherit optionContractViolations;

  # Throws when `options` breaks the contract; `who` is `<ns>/<instance>`.
  checkOptionContract =
    { who, options }:
    let
      violations = optionContractViolations { inherit options; };
    in
    if violations == [ ] then
      null
    else
      throw (
        "package options of instance ${who} break the option contract (docs: reference/package-schema/options, \"Option contract\"):\n"
        + lib.concatMapStringsSep "\n" (v: "  - ${v.message}") violations
      );
}

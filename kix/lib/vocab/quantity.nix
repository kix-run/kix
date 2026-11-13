# Define the Kubernetes quantity option type (`kix.types.quantity`) and parser
# (`kix.parseQuantity`). Both accept the same grammar so every valid option
# value parses to a 64-bit integer.
#
# Accepts a non-negative decimal (`1`, `1.5`, `.5`) with an optional unit
# suffix (`m`, `k`, `M`, `G`, `T`, `P`, `E`, `Ki`, `Mi`, `Gi`, `Ti`, `Pi`,
# `Ei`), or a non-negative integer. Unlike Kubernetes, this grammar rejects
# signs and scientific notation (`1e3`).
{ lib }:

let
  inherit (import ../core/error.nix { inherit lib; }) fail;
  pattern = "([0-9]+)?(\\.([0-9]+))?(m|k|M|G|T|P|E|Ki|Mi|Gi|Ti|Pi|Ei)?";

  pow = base: n: if n == 0 then 1 else base * pow base (n - 1);

  # Represent each suffix multiplier as a fraction so `m` stays exact in
  # integer arithmetic.
  suffixes = {
    "" = {
      num = 1;
      den = 1;
    };
    m = {
      num = 1;
      den = 1000;
    };
    k = {
      num = pow 10 3;
      den = 1;
    };
    M = {
      num = pow 10 6;
      den = 1;
    };
    G = {
      num = pow 10 9;
      den = 1;
    };
    T = {
      num = pow 10 12;
      den = 1;
    };
    P = {
      num = pow 10 15;
      den = 1;
    };
    E = {
      num = pow 10 18;
      den = 1;
    };
    Ki = {
      num = pow 1024 1;
      den = 1;
    };
    Mi = {
      num = pow 1024 2;
      den = 1;
    };
    Gi = {
      num = pow 1024 3;
      den = 1;
    };
    Ti = {
      num = pow 1024 4;
      den = 1;
    };
    Pi = {
      num = pow 1024 5;
      den = 1;
    };
    Ei = {
      num = pow 1024 6;
      den = 1;
    };
  };

  digits = n: builtins.stringLength (toString n);

  # Convert a non-negative integer or string to a plain string without context,
  # or return null for other values.
  asString =
    q:
    if builtins.isInt q then
      (if q >= 0 then toString q else null)
    else if builtins.isString q then
      builtins.unsafeDiscardStringContext q
    else
      null;

  # Split `q` into `{ whole; frac; suffix; }`, or return null if `q` does not
  # match the quantity grammar.
  split =
    q:
    let
      s = asString q;
      m = if s == null then null else builtins.match pattern s;
      whole = builtins.elemAt m 0;
      frac = builtins.elemAt m 2;
    in
    if m == null || (whole == null && frac == null) then
      null
    else
      {
        whole = if whole == null then "" else whole;
        frac = if frac == null then "" else frac;
        suffix =
          let
            x = builtins.elemAt m 3;
          in
          if x == null then "" else x;
      };

  stripLeading = d: if lib.hasPrefix "0" d then stripLeading (lib.removePrefix "0" d) else d;
  stripTrailing = d: if lib.hasSuffix "0" d then stripTrailing (lib.removeSuffix "0" d) else d;
  toInt =
    d:
    let
      t = stripLeading d;
    in
    if t == "" then 0 else lib.toIntBase10 t;

  # Strip leading and trailing zeros from a split quantity so `mantissa` and
  # `frac` contain only significant digits.
  normalize =
    p:
    let
      frac = stripTrailing p.frac;
    in
    {
      whole = stripLeading p.whole;
      inherit frac;
      mantissa = stripLeading (p.whole + frac);
    };

  # Combine the suffix multiplier with `scale` (`1` or `1000`), canceling common
  # factors. Keep `num` and `scale` separate because their product overflows a
  # 64-bit integer for `Ei` in millicores.
  factor =
    scale: suffix:
    let
      mult = suffixes.${suffix};
      same = mult.den == scale;
    in
    {
      inherit (mult) num;
      scale = if same then 1 else scale;
      den = if same then 1 else mult.den;
    };

  # Return an error message when the split quantity `p` would overflow signed
  # 64-bit integer arithmetic in `parse`, or null when it fits. Divide `maxInt`
  # before comparing so the bounds check itself never overflows.
  maxInt = 9223372036854775807;
  inexact =
    scale: unit: p:
    let
      n = normalize p;
      f = factor scale p.suffix;
      maxFrac = 18 - digits f.den;
      limit = maxInt / f.num / f.scale;
    in
    if builtins.stringLength n.mantissa > 18 then
      "it has more than 18 significant digits. Round it to at most 18"
    else if builtins.stringLength n.frac > maxFrac then
      "it has more than ${toString maxFrac} significant digits after the decimal point. Round it to at most ${toString maxFrac}"
    else if toInt n.whole > limit then
      "it is more than ${toString maxInt} ${unit}, the largest signed 64-bit integer. Use a smaller value"
    else if toInt n.mantissa > limit then
      "with its digits after the decimal point it overflows a signed 64-bit integer in ${unit}. Round it to fewer digits after the decimal point"
    else
      null;

  scaleOf = resource: if resource == "cpu" then 1000 else 1;
  unitOf = resource: if resource == "cpu" then "millicores" else "bytes";

  # Return the overflow reason why `parse resource q` would fail, or null when
  # `q` is valid or outside the grammar.
  problem =
    resource: q:
    let
      p = split q;
    in
    if p == null then null else inexact (scaleOf resource) (unitOf resource) p;

  # Validate that `q` matches the grammar and fits in a 64-bit integer at byte
  # scale. A CPU quantity near the 64-bit limit can still overflow when scaled
  # to millicores in `parse`.
  valid =
    q:
    let
      p = split q;
    in
    p != null && inexact 1 "bytes" p == null;

  # Parse `q` into millicores when `resource` is "cpu" and into bytes (or base
  # units) otherwise, rounded down. Return null when `q` is outside the
  # grammar, or fail when the value overflows 64-bit integer arithmetic.
  parse =
    resource: q:
    let
      p = split q;
      n = normalize p;
      reason = problem resource q;
      f = factor (scaleOf resource) p.suffix;
    in
    if p == null then
      null
    else if reason != null then
      fail "${resource} quantity \"${asString q}\" cannot be computed exactly: ${reason}. Kix computes quantities as 64-bit integers."
    else
      toInt n.mantissa * f.num * f.scale / (f.den * pow 10 (builtins.stringLength n.frac));
in
{
  inherit parse problem;

  type = lib.mkOptionType {
    name = "quantity";
    description = ''Kubernetes quantity, such as "500m" or "1Gi" (a non-negative decimal or integer with an optional suffix m, k, M, G, T, P, E, Ki, Mi, Gi, Ti, Pi or Ei)'';
    descriptionClass = "noun";
    check = valid;
    merge = lib.options.mergeEqualOption;
  };
}

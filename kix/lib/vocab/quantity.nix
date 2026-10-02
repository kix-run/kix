# Kubernetes resource quantities: the option type `kix.types.quantity` and
# the parser `kix.parseQuantity`. Both accept one grammar, so every value
# the type accepts parses to an integer number of bytes.
#
# The grammar is a non-negative decimal (`1`, `1.5`, `.5`) with an optional
# suffix (`m`, `k`, `M`, `G`, `T`, `P`, `E`, `Ki`, `Mi`, `Gi`, `Ti`, `Pi`,
# `Ei`), or a non-negative integer. Kubernetes also accepts signs and
# exponents (`1e3`); this grammar refuses them.
{ lib }:

let
  pattern = "([0-9]+)?(\\.([0-9]+))?(m|k|M|G|T|P|E|Ki|Mi|Gi|Ti|Pi|Ei)?";

  pow = base: n: if n == 0 then 1 else base * pow base (n - 1);

  # Each suffix as a multiplier of the base unit, written as a fraction so
  # `m` stays exact in integer arithmetic.
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

  # The decimal digits of a divisor, to tell whether it fits in a 64-bit
  # integer.
  digits = n: builtins.stringLength (toString n);

  # The string form of a value, or null when the value cannot be a quantity
  # (a negative integer, a float, an attrset). String context is discarded.
  asString =
    q:
    if builtins.isInt q then
      (if q >= 0 then toString q else null)
    else if builtins.isString q then
      builtins.unsafeDiscardStringContext q
    else
      null;

  # { whole; frac; suffix; } as strings, or null outside the grammar.
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

  # A split quantity without the zeros that do not change its value, so
  # "007Mi" has one significant digit and "1.500" two. `mantissa` is the
  # digit string, `frac` the fraction digits it ends with.
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

  # The suffix multiplier times `scale`, as num * scale / den with common
  # factors removed. `scale` and the suffix denominator are each 1 or 1000,
  # so "250m" in millicores has the multiplier 1 * 1 / 1. num and scale stay
  # separate because their product overflows for "Ei" in millicores.
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

  # Why `parse` cannot compute the split quantity `p` exactly in signed
  # 64-bit integers, or null when it can. `parse` computes
  # mantissa * num * scale / (den * 10^fraction digits), so the significant
  # digits, that divisor, and the product mantissa * num * scale must each
  # fit. Dividing `maxInt` first keeps the checks themselves from
  # overflowing.
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

  # Why `parse resource q` would throw, or null when it parses or `q` is
  # outside the grammar. For a caller that names the field in its own error.
  problem =
    resource: q:
    let
      p = split q;
    in
    if p == null then null else inexact (scaleOf resource) (unitOf resource) p;

  # The type accepts what `parse "memory"` computes; a "cpu" value close to
  # the limit can still fail `parse`, which then throws.
  valid =
    q:
    let
      p = split q;
    in
    p != null && inexact 1 "bytes" p == null;

  # The quantity in millicores when `resource` is "cpu", and in bytes (or
  # the base unit) otherwise, rounded down. null outside the grammar.
  # Throws when the value cannot be computed exactly in 64-bit integers
  # (`problem` gives the reason).
  #
  #   parse "cpu" "250m"     => 250
  #   parse "memory" "1.5Gi" => 1610612736
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
      throw "${resource} quantity \"${asString q}\" cannot be computed exactly: ${reason}. Kix computes quantities as 64-bit integers."
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

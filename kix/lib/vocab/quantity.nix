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

  # Whether `parse` can compute the split quantity `p` exactly in signed
  # 64-bit integers: the digit string has at most 18 digits, the fraction's
  # divisor at most 18, and the product with the suffix and `scale`
  # multipliers is at most `maxInt`. Dividing `maxInt` first keeps the
  # check itself from overflowing.
  maxInt = 9223372036854775807;
  exact =
    scale: p:
    let
      mult = suffixes.${p.suffix};
      mantissa = p.whole + p.frac;
    in
    builtins.stringLength mantissa <= 18
    && builtins.stringLength p.frac + digits mult.den <= 18
    && lib.toIntBase10 mantissa <= maxInt / mult.num / scale;

  # The type accepts what `parse "memory"` computes; a "cpu" value close to
  # the limit can still fail `parse`, which then throws.
  valid =
    q:
    let
      p = split q;
    in
    p != null && exact 1 p;

  # The quantity in millicores when `resource` is "cpu", and in bytes (or
  # the base unit) otherwise, rounded down. null outside the grammar.
  # Throws when the value cannot be computed exactly (`exact`).
  #
  #   parse "cpu" "250m"     => 250
  #   parse "memory" "1.5Gi" => 1610612736
  parse =
    resource: q:
    let
      p = split q;
      scale = if resource == "cpu" then 1000 else 1;
      unit = if resource == "cpu" then "millicores" else "bytes";
      mult = suffixes.${p.suffix};
      fracLength = builtins.stringLength p.frac;
    in
    if p == null then
      null
    else if !(exact scale p) then
      throw "quantity \"${asString q}\" cannot be computed exactly in ${unit}: Kix computes quantities in 64-bit integers, so a value can be at most ${toString maxInt} ${unit} and have at most 18 digits. Write it with fewer digits."
    else
      lib.toIntBase10 (p.whole + p.frac) * mult.num * scale / (mult.den * pow 10 fracLength);
in
{
  inherit parse;

  type = lib.mkOptionType {
    name = "quantity";
    description = ''Kubernetes quantity, such as "500m" or "1Gi" (a non-negative decimal or integer with an optional suffix m, k, M, G, T, P, E, Ki, Mi, Gi, Ti, Pi or Ei)'';
    descriptionClass = "noun";
    check = valid;
    merge = lib.options.mergeEqualOption;
  };
}

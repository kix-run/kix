# Version strings for meta.version, meta.k8s, meta.compatibleWith and
# k8sVersion.
#
# Grammar: an optional "v", numbers separated by dots, an optional
# "-suffix" and an optional "+build". A "-suffix" is a prerelease only when
# its first identifier is one of `prereleaseTags`, optionally followed by
# digits ("rc1"), as Kubernetes tags them. Any other suffix ("-gke.1209000",
# "-eks-7f9249a", "-cf", Helm's "-0") is a vendor build tag and is ignored
# like "+build". Semver 2.0 would treat those as prereleases.
#
# Internal to kix/lib: meta.nix, modules.nix and kix/package-eval.nix import
# this file directly.
{ lib }:

let
  prereleaseTags = [
    "alpha"
    "beta"
    "rc"
    "pre"
    "dev"
    "preview"
  ];

  # builtins.match result indices: 0 core, 3 suffix without "-", 5 build.
  grammar = "[vV]?([0-9]+(\\.[0-9]+)*)(-([0-9A-Za-z.-]+))?(\\+([0-9A-Za-z.-]+))?";

  # "rc10" splits into [ "rc" "10" ] so that rc2 sorts before rc10.
  prereleaseOf =
    suffix:
    let
      ids = lib.splitString "." suffix;
      head = builtins.match "(${lib.concatStringsSep "|" prereleaseTags})([0-9]*)" (builtins.head ids);
    in
    if head == null then
      [ ]
    else
      [ (builtins.elemAt head 0) ]
      ++ lib.optional (builtins.elemAt head 1 != "") (builtins.elemAt head 1)
      ++ builtins.tail ids;

  tryParse =
    v:
    let
      m = if builtins.isString v then builtins.match grammar v else null;
      suffix = builtins.elemAt m 3;
    in
    if m == null then
      null
    else
      {
        core = map lib.toIntBase10 (lib.splitString "." (builtins.elemAt m 0));
        pre = if suffix == null then [ ] else prereleaseOf suffix;
      };

  isVersion = v: tryParse v != null;

  describe = v: if builtins.isString v then "\"${v}\"" else builtins.toJSON v;

  parse =
    v:
    let
      parsed = tryParse v;
    in
    if parsed != null then
      parsed
    else
      throw "${describe v} is not a version Kix can compare: expected numbers separated by dots, optionally with a leading \"v\", a \"-suffix\" and a \"+build\" suffix (for example \"1.19.6\", \"v2.12.2\", \"1.31.2+rke2r1\", \"1.31.2-gke.1209000\").";

  cmp =
    a: b:
    if a < b then
      -1
    else if a > b then
      1
    else
      0;

  # Numeric comparison of two cores, the shorter padded with zeros.
  compareCore =
    a: b:
    let
      len = lib.max (builtins.length a) (builtins.length b);
      pad = l: l ++ lib.genList (_: 0) (len - builtins.length l);
      pa = pad a;
      pb = pad b;
      go =
        i:
        if i >= len then
          0
        else
          let
            c = cmp (builtins.elemAt pa i) (builtins.elemAt pb i);
          in
          if c != 0 then c else go (i + 1);
    in
    go 0;

  isNumeric = s: builtins.match "[0-9]+" s != null;

  # Semver 2.0 §11 precedence for two prerelease identifier lists. An empty
  # list is a release, which sorts after every prerelease of the same core.
  comparePre =
    a: b:
    if a == [ ] && b == [ ] then
      0
    else if a == [ ] then
      1
    else if b == [ ] then
      -1
    else
      let
        go =
          i:
          if i >= builtins.length a && i >= builtins.length b then
            0
          else if i >= builtins.length a then
            -1
          else if i >= builtins.length b then
            1
          else
            let
              x = builtins.elemAt a i;
              y = builtins.elemAt b i;
              c =
                if isNumeric x && isNumeric y then
                  cmp (lib.toIntBase10 x) (lib.toIntBase10 y)
                else if isNumeric x then
                  -1
                else if isNumeric y then
                  1
                else
                  cmp x y;
            in
            if c != 0 then c else go (i + 1);
      in
      go 0;

  compareParsed =
    a: b:
    let
      c = compareCore a.core b.core;
    in
    if c != 0 then c else comparePre a.pre b.pre;

  # Ordering: -1, 0 or 1. Throws when either side is not a version.
  compare = a: b: compareParsed (parse a) (parse b);

  # Compares version `v` against `constraint` at the constraint's precision:
  # "1.30.4" equals "1.30", and "1.31" against "1.31.2" is unknown (null).
  # A prerelease decides only when both cores have the same length.
  compareAtPrecision =
    v: constraint:
    let
      pv = parse v;
      pc = parse constraint;
      n = builtins.length pc.core;
      m = builtins.length pv.core;
    in
    if m >= n then
      let
        c = compareCore (lib.take n pv.core) pc.core;
      in
      if c != 0 then
        c
      else if m > n then
        0
      else
        comparePre pv.pre pc.pre
    else
      let
        c = compareCore pv.core (lib.take m pc.core);
      in
      if c != 0 then c else null;

  # true, false, or null when `v` is less precise than `constraint` and
  # agrees with it as far as it goes.
  atLeast =
    v: constraint:
    let
      c = compareAtPrecision v constraint;
    in
    if c == null then null else c >= 0;

  atMost =
    v: constraint:
    let
      c = compareAtPrecision v constraint;
    in
    if c == null then null else c <= 0;
in
{
  inherit
    prereleaseTags
    isVersion
    tryParse
    parse
    compare
    atLeast
    atMost
    ;
}

# Parse and compare version strings for `meta.version`, `meta.k8s`,
# `meta.compatibleWith`, and `k8sVersion`.
#
# Versions consist of an optional leading `v`, dot-separated numbers, an
# optional `-suffix`, and an optional `+build`. A `-suffix` is treated as a
# prerelease only when its first identifier starts with a tag in
# `prereleaseTags` (such as `rc1`). Other suffixes (such as `-gke.1209000`,
# `-eks-7f9249a`, or `-0`) are vendor build tags and are ignored like `+build`.
{ lib }:

let
  inherit (import ./error.nix { inherit lib; }) fail;
  prereleaseTags = [
    "alpha"
    "beta"
    "rc"
    "pre"
    "dev"
    "preview"
  ];

  # Capture groups: 0 = core numbers, 3 = suffix without "-", 5 = build.
  grammar = "[vV]?([0-9]+(\\.[0-9]+)*)(-([0-9A-Za-z.-]+))?(\\+([0-9A-Za-z.-]+))?";

  # Split "rc10" into [ "rc" "10" ] so rc2 sorts before rc10.
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
      fail {
        message = "${describe v} is not a version Kix can compare.";
        fix = "Use numbers separated by dots, optionally with a leading \"v\", a \"-suffix\" and a \"+build\" suffix (for example \"1.19.6\", \"v2.12.2\", \"1.31.2+rke2r1\", \"1.31.2-gke.1209000\").";
      };

  cmp =
    a: b:
    if a < b then
      -1
    else if a > b then
      1
    else
      0;

  # Compare two numeric core lists, padding the shorter list with zeros.
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

  # Compare two prerelease identifier lists using SemVer 2.0 precedence, where
  # an empty list (a release) sorts after any prerelease.
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

  # Compare two version strings and return -1, 0, or 1.
  compare = a: b: compareParsed (parse a) (parse b);

  # Compare `v` against `constraint` at the constraint's precision, returning
  # null when `v` is less precise than `constraint` and matches its prefix.
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

  # Return true or false, or null when `v` is less precise than `constraint`
  # and matches its prefix.
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

# Parse Prometheus durations and cron schedules to compute alert thresholds.
{ lib }:
let
  # Prometheus also accepts `ms`, which `toSeconds` rounds down to whole seconds.
  units = {
    s = 1;
    m = 60;
    h = 3600;
    d = 86400;
    w = 604800;
    y = 31536000;
  };

  # Convert a Prometheus duration string (such as "1h30m") to whole seconds.
  toSeconds =
    d:
    let
      parts = builtins.filter builtins.isList (builtins.split "([0-9]+)(ms|s|m|h|d|w|y)" d);
      partSeconds =
        p:
        let
          n = lib.toInt (builtins.elemAt p 0);
          u = builtins.elemAt p 1;
        in
        if u == "ms" then n / 1000 else n * units.${u};
    in
    if builtins.match "([0-9]+(ms|s|m|h|d|w|y))+" d == null then
      throw "kix.durations.toSeconds: \"${d}\" is not a Prometheus duration such as \"90s\", \"5m\" or \"1h30m\"."
    else
      lib.foldl' (acc: p: acc + partSeconds p) 0 parts;

  # Format a second count as whole hours, minutes, or seconds. Prefer hours
  # (such as "50h" instead of "2d2h") so the threshold is easy to compare with
  # a schedule period.
  fromSeconds =
    secs:
    if secs > 0 && lib.mod secs 3600 == 0 then
      "${toString (secs / 3600)}h"
    else if secs > 0 && lib.mod secs 60 == 0 then
      "${toString (secs / 60)}m"
    else
      "${toString secs}s";

  # Parse a Go duration in whole hours, minutes, and seconds (such as "1h30m")
  # for cron's `@every` syntax, or return null for other forms.
  goSeconds =
    d:
    if builtins.match "([0-9]+[hms])+" d == null then
      null
    else
      lib.foldl' (acc: p: acc + lib.toInt (builtins.elemAt p 0) * units.${builtins.elemAt p 1}) 0 (
        builtins.filter builtins.isList (builtins.split "([0-9]+)([hms])" d)
      );

  descriptorPeriod = {
    "@hourly" = 3600;
    "@daily" = 86400;
    "@midnight" = 86400;
    "@weekly" = 604800;
    "@monthly" = 31 * 86400;
    "@yearly" = 366 * 86400;
    "@annually" = 366 * 86400;
  };

  # Return the longest gap in seconds between two runs of a cron schedule, or
  # null when the schedule cannot be statically bounded. Accepts a `@`
  # descriptor, `@every <duration>`, or a 5- or 6-field cron expression with
  # an optional `CRON_TZ=` or `TZ=` prefix. When day-of-month and month are
  # both `*`, a `*` day-of-week runs at least daily and any other day-of-week
  # runs at least weekly.
  period =
    schedule:
    let
      line = lib.trim (
        builtins.elemAt (builtins.match "((CRON_TZ|TZ)=[^ ]+ +)?(.*)" (lib.trim schedule)) 2
      );
      fields = builtins.filter (f: builtins.isString f && f != "") (builtins.split "[[:space:]]+" line);
      every = builtins.match "@every +(.+)" line;
      n = builtins.length fields;
      tail3 = lib.drop (n - 3) fields;
    in
    if descriptorPeriod ? ${line} then
      descriptorPeriod.${line}
    else if every != null then
      goSeconds (builtins.head every)
    else if (n == 5 || n == 6) && builtins.elemAt tail3 0 == "*" && builtins.elemAt tail3 1 == "*" then
      if builtins.elemAt tail3 2 == "*" then 86400 else 604800
    else
      null;
in
{
  types.promDuration = lib.types.strMatching "([0-9]+(ms|s|m|h|d|w|y))+";

  durations = {
    inherit toSeconds;
    inherit fromSeconds;
  };

  schedules = {
    inherit period;
    # Return the staleness threshold for a scheduled job as a duration string,
    # or null when the schedule period cannot be read. Uses two periods plus
    # two hours so a single missed run only triggers the failure alert while
    # leaving time for the second run to complete.
    staleAfter =
      schedule:
      let
        p = period schedule;
      in
      if p == null then null else fromSeconds (2 * p + 7200);
  };
}

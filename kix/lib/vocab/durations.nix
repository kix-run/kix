# Prometheus durations and backup schedules, for alert thresholds.
#
# An alert compares a gauge in seconds with a threshold a package option
# writes as a duration ("5m", "50h"), and a backup alert derives its
# threshold from the schedule the package renders.
{ lib }:
let
  # Seconds per unit. Prometheus also accepts `ms`; toSeconds rounds it
  # down to whole seconds.
  units = {
    s = 1;
    m = 60;
    h = 3600;
    d = 86400;
    w = 604800;
    y = 31536000;
  };

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

  # Whole hours where they divide evenly, else minutes, else seconds, so
  # "50h" rather than "2d2h": the hour count reads directly against a
  # schedule period.
  fromSeconds =
    secs:
    if secs > 0 && lib.mod secs 3600 == 0 then
      "${toString (secs / 3600)}h"
    else if secs > 0 && lib.mod secs 60 == 0 then
      "${toString (secs / 60)}m"
    else
      "${toString secs}s";

  # A Go duration in whole hours, minutes and seconds ("6h", "1h30m"), as
  # cron's `@every` takes it. Null for any other form, such as "1.5h".
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

  # The longest gap between two runs of a cron schedule, in seconds, or null
  # when it cannot be read. Takes a descriptor, `@every <duration>`, or five
  # or six fields (six when the first is seconds), after an optional
  # `CRON_TZ=` or `TZ=` prefix. With day-of-month and month both `*`, a
  # schedule runs at least daily when day-of-week is also `*`, and at least
  # weekly otherwise; any other field pattern is null.
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
    # "1h30m" -> 5400. Throws on a string that is not a Prometheus duration.
    inherit toSeconds;
    # 5400 -> "90m", 180000 -> "50h".
    inherit fromSeconds;
  };

  schedules = {
    inherit period;
    # How long a job on `schedule` may go without a success before an alert
    # fires: two periods, so one missed run stays quiet while the failure
    # alert reports it, plus two hours for a run to finish. A duration
    # string such as "50h" for a daily schedule, or null when the period
    # cannot be read.
    staleAfter =
      schedule:
      let
        p = period schedule;
      in
      if p == null then null else fromSeconds (2 * p + 7200);
  };
}

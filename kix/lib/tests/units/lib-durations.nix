# Tests for kix.durations and kix.schedules (vocab/durations.nix), as
# packages receive them.

{ lib, kixlib, ... }:

let
  inherit (kixlib.durations) toSeconds fromSeconds;
  inherit (kixlib.schedules) period staleAfter;

  # The names of the cases whose result differs from the expected value.
  mismatches = f: cases: lib.attrNames (lib.filterAttrs (input: expected: f input != expected) cases);
  check =
    what: f: cases:
    let
      wrong = mismatches f cases;
    in
    wrong == [ ]
    || throw "${what}: ${
      builtins.toJSON (
        map (i: {
          inherit i;
          got = f i;
        }) wrong
      )
    }";
in
{
  # Every Prometheus unit, a compound duration, and `ms` rounded down to
  # whole seconds. A string that is not a Prometheus duration throws.
  lib-durations-to-seconds =
    check "toSeconds" toSeconds {
      "90s" = 90;
      "5m" = 300;
      "1h30m" = 5400;
      "2d" = 172800;
      "1w" = 604800;
      "1y" = 31536000;
      "1500ms" = 1;
      "1d12h" = 129600;
      "0s" = 0;
    }
    && builtins.all (d: !(builtins.tryEval (toSeconds d)).success) [
      ""
      "5"
      "h"
      "1.5h"
      "5 m"
      "-1h"
      "1H"
    ];

  # Whole hours where they divide evenly, else minutes, else seconds.
  lib-durations-from-seconds = check "fromSeconds" (s: fromSeconds (lib.toInt s)) {
    "180000" = "50h";
    "3600" = "1h";
    "5400" = "90m";
    "90" = "90s";
    "61" = "61s";
    "0" = "0s";
  };

  # Descriptors, `@every` Go durations, and five or six fields after an
  # optional CRON_TZ= or TZ= prefix. A schedule that restricts the day of
  # the month or the month, an `@every` with a fraction or no unit, and a
  # line with the wrong number of fields read as null.
  lib-durations-schedule-period = check "period" period {
    "@hourly" = 3600;
    "@daily" = 86400;
    "@midnight" = 86400;
    "@weekly" = 604800;
    "@monthly" = 2678400;
    "@yearly" = 31622400;
    "@annually" = 31622400;
    "  @daily " = 86400;
    "@every 6h" = 21600;
    "@every 1h30m" = 5400;
    "@every 45s" = 45;
    "@every 1.5h" = null;
    "@every day" = null;
    "@reboot" = null;
    "0 2 * * *" = 86400;
    "*/5 * * * *" = 86400;
    "0 3 * * 0" = 604800;
    "0 3 * * MON-FRI" = 604800;
    "0 0 2 * * *" = 86400;
    "0 0 3 * * 1" = 604800;
    "CRON_TZ=UTC 0 2 * * *" = 86400;
    "TZ=Europe/London 0 3 * * 0" = 604800;
    "CRON_TZ=UTC @weekly" = 604800;
    "0 2 1 * *" = null;
    "0 2 * 6 *" = null;
    "0 0 2 1 * *" = null;
    "0 2 * *" = null;
    "0 0 0 2 * * *" = null;
    "nightly" = null;
  };

  # Two periods plus two hours, formatted by fromSeconds, or null when the
  # period cannot be read.
  lib-durations-schedule-stale-after = check "staleAfter" staleAfter {
    "@hourly" = "4h";
    "@daily" = "50h";
    "@weekly" = "338h";
    "@monthly" = "1490h";
    "@yearly" = "17570h";
    "@every 6h" = "14h";
    "@every 30m" = "3h";
    "@every 45s" = "7290s";
    "CRON_TZ=UTC 0 2 * * *" = "50h";
    "0 0 3 * * 1" = "338h";
    "0 2 1 * *" = null;
    "@every 1.5h" = null;
  };
}

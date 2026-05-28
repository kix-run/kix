# Named output transforms for captured command output.
#
# Each transform is a single-stage sed program (string → string). Transforms
# live in one of two layers:
#
#   - displayTransforms: applied during capture. The result is what we store
#     as the JSON's `stdout` / `stderr` and what the `<Command>` component
#     renders in the docs. Keep this minimal — only normalisation that is
#     never useful for a reader to see (terminal control bytes, PTY framing,
#     CRLF endings, intra-line `\r` overwrites). The reader should otherwise
#     see what they would see in their own terminal.
#
#   - driftOnlyTransforms: applied on top of displayTransforms only when
#     producing the JSON's `stdoutDrift` / `stderrDrift` fields. The regen
#     script compares those drift fields between fresh and checked-in
#     captures, so per-run noise (pod-name hashes, IP addresses, timestamps,
#     activity durations, content-addressed activation IDs) doesn't cause
#     false-positive drift while still letting structural changes surface.

{ lib }:

let
  programs = {
    # Pod name suffixes: `hello-world-7d4f9c8b6-x2j8q` → `hello-world-<hash>`.
    # Matches Deployment-managed pod naming: <name>-<replicaset-hash>-<pod-suffix>.
    strip-pod-suffix = ''
      s/([a-z0-9]([a-z0-9-]*[a-z0-9])?)-[a-f0-9]{8,10}-[a-z0-9]{5}\b/\1-<hash>/g
    '';

    # ISO-8601-ish timestamps → `<TIME>`.
    redact-timestamp = ''
      s/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z?/<TIME>/g
    '';

    # Kind cluster IP block (10.96.0.0/12 by default; covers most kind/k3s).
    redact-cluster-ip = ''
      s/\b10\.(9[6-9]|1[0-1][0-9]|12[0-7])\.[0-9]+\.[0-9]+\b/<CLUSTER-IP>/g
    '';

    # Kind node IP block (default 172.18.0.0/16).
    redact-node-ip = ''
      s/\b172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]+\.[0-9]+\b/<NODE-IP>/g
    '';

    # Durations like `1.234s`, `12ms`, `2m4s` → `<DURATION>`.
    redact-duration = ''
      s/\b[0-9]+(\.[0-9]+)?(ms|µs|us|s|m[0-9]+s|h)\b/<DURATION>/g
    '';

    # Activation IDs: `02-hello-world-kddvid7wbdpp` style — `<cluster>-<11-char-hash>`.
    # Run before strip-pod-suffix so the longer hash is consumed first.
    redact-activation-id = ''
      s/(Activation\/)?([a-z0-9][a-z0-9-]*[a-z0-9])-[a-z0-9]{11,12}\b/\1\2-<activation-id>/g
    '';

    # Normalise interactive terminal output while PRESERVING SGR colour
    # codes. Steps:
    #   1. Drop backspace bytes (\b / 0x08). PTY recorders emit these to
    #      erase the literal `^D` EOF echo at session end; they never carry
    #      meaning in captured text.
    #   2. At start-of-line, strip a leading literal `^D` (caret + capital
    #      D). `script -q` on macOS still emits this once at the top of the
    #      session.
    #   3. Drop the trailing `\r` PTYs add as part of CRLF line endings —
    #      otherwise step 5 would treat it as an overwrite pivot and eat
    #      the whole line.
    #   4. Strip CSI escapes that don't end in `m` (cursor moves, clear-
    #      line, scroll, etc.). SGR sequences `\e[<digits>m` survive.
    #   5. Per logical line, collapse intra-line carriage-return overwrites:
    #      `foo\rbar` becomes `bar`. Lines with no remaining `\r` are
    #      untouched.
    # The component-side ANSI parser then translates surviving SGR escapes
    # into styled spans.
    normalize-tty-output = ''
      s/\x08//g
      s/^\^D//
      s/\r$//
      s/\x1b\[[0-9;?]*[a-ln-zA-Z]//g
      s/.*\r//
    '';

    # Strip SGR (colour / weight) escapes entirely. Used only for drift
    # comparison — colour is purely presentational and shouldn't trigger
    # false drift if e.g. the CLI changes a span from green to bright-green.
    strip-sgr = ''
      s/\x1b\[[0-9;]*m//g
    '';

    # Strip whitespace at end of each line. CLIs that pad columns to align
    # often emit trailing spaces; the count varies with content widths and
    # has no semantic meaning.
    strip-trailing-whitespace = ''
      s/[[:blank:]]+$//
    '';

    # Collapse runs of 2+ ASCII spaces into a single space. Tabular CLI
    # output (kubectl, kix list, etc.) pads cells with variable-width gaps
    # so columns align; the exact gap size is purely visual. After this
    # pass, columns are space-separated values, which is good enough for
    # drift detection.
    collapse-spaces = ''
      s/  +/ /g
    '';

    # Collapse runs of 2+ blank lines into a single blank line.
    collapse-blank-lines = ''
      /^$/N;/^\n$/D
    '';
  };

  # Applied during capture; baked into JSON's `stdout` / `stderr` and rendered
  # verbatim in docs. Keep minimal.
  displayTransforms = [
    "normalize-tty-output"
  ];

  # Applied additionally for drift-only comparison; baked into the
  # `stdoutDrift` / `stderrDrift` fields. The regen tool compares those
  # fields between runs. Ordering matters — see comments next to each entry.
  driftOnlyTransforms = [
    # SGR first so subsequent regexes see plain text.
    "strip-sgr"
    # Literal-content redactions: shape-preserving placeholders for values
    # that are noise (hashes, IDs, addresses, times).
    "redact-activation-id"
    "strip-pod-suffix"
    "redact-timestamp"
    "redact-cluster-ip"
    "redact-node-ip"
    "redact-duration"
    # Whitespace normalisation last, so redactions matched on word
    # boundaries still fire before columns collapse together.
    "strip-trailing-whitespace"
    "collapse-spaces"
    "collapse-blank-lines"
  ];
in
{
  inherit programs displayTransforms driftOnlyTransforms;

  # Convenience: full pipeline used when producing drift content (display
  # transforms first, drift transforms layered on top).
  driftTransforms = displayTransforms ++ driftOnlyTransforms;
}

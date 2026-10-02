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
    # Use the Nix base32 alphabet so ordinary 11-letter suffixes such as
    # `application` are not mistaken for content-addressed IDs.
    # Run before strip-pod-suffix so the longer hash is consumed first.
    redact-activation-id = ''
      s/(Activation\/)?([a-z0-9][a-z0-9-]*[a-z0-9])-[0-9abcdfghijklmnpqrsvwxyz]{11,12}\b/\1\2-<activation-id>/g
    '';

    # Source locations in Nix error traces. Nix 2.31 prints a file from a
    # flake input as `/nix/store/<hash>-source/<path>` and builtin files as
    # `<nix/<file>>`; newer Nix prints `«github:owner/repo/rev?…»/<path>` and
    # `«nix-internal»/<file>`. Both become `«source»/<path>`, so a capture's
    # drift does not depend on the Nix version of the machine that made it.
    # Run before redact-identity-hash, which would rewrite the store hash.
    normalize-nix-source-paths = ''
      s|/nix/store/[a-z0-9]{32}-source/|«source»/|g
      s|«[^»]*»/|«source»/|g
      s|<nix/([^>]*)>|«source»/\1|g
    '';

    # Kix identity hashes: 32-char base32 Nix-style hashes that appear in
    # `kix.run/identity-hash`, `kix.run/depends-on`, and embedded store
    # paths in `kix build`/`kix graph` output. These are content-addressed
    # over the kixpkgs source path, so when the source changes (e.g.
    # because `--apply` just wrote new sidecars into
    # docs/src/command-output/), every hash shifts. Redacting them in the
    # drift view lets the comparison ignore that churn while still
    # catching structural changes (new resources, missing deps, etc.).
    redact-identity-hash = ''
      s/\b[a-z0-9]{32}\b/<identity-hash>/g
    '';

    # Nix `narHash=sha256-…` blobs leaked into error messages when an
    # eval fails. URL-encoded (`%2B`, `%2F`, `%3D`) or raw, 43–44 chars
    # of base64 followed by an `=` pad. Same churn category as
    # identity hashes — content-addressed over inputs that move when
    # sidecars get rewritten.
    redact-nar-hash = ''
      s|narHash=sha256-[A-Za-z0-9+/%]+%3D|narHash=sha256-<nar-hash>|g
      s|narHash=sha256-[A-Za-z0-9+/]+=|narHash=sha256-<nar-hash>|g
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

    # Drop Nix's build-progress chatter. `kix` forwards these from the
    # `nix build` it shells out to (cli/kix/src/eval/build.rs), and Nix
    # only emits them when it actually has to build: a warm store prints
    # nothing. So whether a capture contains them records the state of
    # the machine that generated it, not the behaviour of the command.
    # Drift-only — a reader on a cold store really would see them.
    #
    # `Building cluster '...'` is kix's own line and stays; the pattern
    # requires the quote immediately after `Building`.
    strip-nix-build-progress = ''
      /^[[:space:]]*building '\/nix\/store\/.*\.\.\.$/d
      /^[[:space:]]*Building '[^']*'\.\.\.$/d
      /^[[:space:]]*copying path '\/nix\/store\/.*\.\.\.$/d
      /^[[:space:]]*this derivation will be built:$/d
      /^[[:space:]]*these [0-9]+ derivations will be built:$/d
    '';

    # Strip leading tree-drawing characters and whitespace. Used for
    # drift comparison of `kix graph --format tree`: the same DAG node
    # gets rendered at different indents depending on which parent the
    # traversal picks for it, and that choice isn't stable across runs.
    # After this pass `│ │ └── Foo` and `└── Foo` both become `Foo`,
    # so `sort -u` collapses them into one line. No-op for non-tree
    # output (no leading box-drawing chars to strip).
    strip-tree-indent = ''
      s/^[[:space:]│├└─]+//
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
    # Then drop nix build progress, while the store paths in those lines
    # are still literal and before any redaction rewrites them.
    "strip-nix-build-progress"
    # Literal-content redactions: shape-preserving placeholders for values
    # that are noise (hashes, IDs, addresses, times). Activation ID first
    # (it consumes the longer suffix); identity-hash second so it doesn't
    # also catch the activation suffix.
    "redact-activation-id"
    "normalize-nix-source-paths"
    "redact-identity-hash"
    "redact-nar-hash"
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
    # Tree-indent strip is the very last layer — it has to run after
    # everything else so the redactions still see their patterns at
    # the original positions.
    "strip-tree-indent"
  ];
in
{
  inherit programs displayTransforms driftOnlyTransforms;

  # Convenience: full pipeline used when producing drift content (display
  # transforms first, drift transforms layered on top).
  driftTransforms = displayTransforms ++ driftOnlyTransforms;
}

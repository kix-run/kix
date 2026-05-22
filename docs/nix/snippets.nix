# Snippet extraction: pull named regions out of `.nix` source files and
# emit each as a Markdown file with a fenced code block.
#
# Marker convention:
#   # region:NAME
#   <body>
#   # endregion
#
# - NAME matches [a-zA-Z][a-zA-Z0-9-]* (the brief specifies lowercase
#   but uses `isProxy` in its demo example; allow camelCase identifiers).
# - Markers must be on their own line (leading/trailing whitespace ok).
# - No nesting; no duplicate names per file.
# - Marker lines themselves are NOT included in the body.
# - Indentation is preserved (no dedent).

{ pkgs, lib }:

let
  # Regex matchers — `builtins.match` returns null on no match,
  # or a list of capture groups.
  startRe = "[[:space:]]*#[[:space:]]*region:([a-zA-Z][a-zA-Z0-9-]*)[[:space:]]*";
  endRe = "[[:space:]]*#[[:space:]]*endregion[[:space:]]*";

  matchStart = line: builtins.match startRe line;
  isEnd = line: builtins.match endRe line != null;

  # Extract all regions from one file.
  # Returns { regions = [{ name; body; }]; } or throws on validation failure.
  extractRegions =
    { file, fileLabel }:
    let
      content = builtins.readFile file;
      lines = lib.splitString "\n" content;

      # Fold over lines, threading state:
      #   { current = null | { name; startLine; bodyLines; };
      #     regions = [{ name; body; }];
      #     names   = [];  # for dup detection
      #     lineNo  = 1;
      #   }
      step =
        state: line:
        let
          startMatch = matchStart line;
          ending = isEnd line;
          inRegion = state.current != null;
        in
        if startMatch != null then
          # Opening marker.
          let
            name = builtins.head startMatch;
          in
          if inRegion then
            throw "snippets: ${fileLabel}: line ${toString state.lineNo}: nested region '${name}' inside region '${state.current.name}'"
          else if builtins.elem name state.names then
            throw "snippets: ${fileLabel}: line ${toString state.lineNo}: duplicate region name '${name}'"
          else
            state
            // {
              current = {
                inherit name;
                startLine = state.lineNo;
                bodyLines = [ ];
              };
              names = state.names ++ [ name ];
              lineNo = state.lineNo + 1;
            }
        else if ending then
          if !inRegion then
            throw "snippets: ${fileLabel}: line ${toString state.lineNo}: '# endregion' without a matching '# region:NAME'"
          else
            state
            // {
              current = null;
              regions = state.regions ++ [
                {
                  name = state.current.name;
                  body = builtins.concatStringsSep "\n" state.current.bodyLines;
                }
              ];
              lineNo = state.lineNo + 1;
            }
        else if inRegion then
          state
          // {
            current = state.current // {
              bodyLines = state.current.bodyLines ++ [ line ];
            };
            lineNo = state.lineNo + 1;
          }
        else
          state // { lineNo = state.lineNo + 1; };

      final = builtins.foldl' step {
        current = null;
        regions = [ ];
        names = [ ];
        lineNo = 1;
      } lines;
    in
    if final.current != null then
      throw "snippets: ${fileLabel}: unterminated region '${final.current.name}' (opened at line ${toString final.current.startLine})"
    else if final.regions == [ ] then
      throw "snippets: ${fileLabel}: no '# region:NAME' markers found"
    else
      final.regions;

  # Per-source processing: produces a list of { drv; subdir; filename; }
  # describing the files to emit, plus a manifest entry.
  #
  # Emit raw `.nix` source for each region (no frontmatter, no fence).
  # That makes the snippet directly consumable from MDX pages via
  # `import body from '/src/snippets/<name>/<region>.nix?raw'` and rendered
  # with Starlight's `<Code lang="nix" code={body} />`.
  #
  # `file` may be a Nix path OR a string (including a flake-store
  # interpolation like `"${kix-examples}/examples/.../scorecard.nix"`).
  # `builtins.readFile` accepts both, so we keep the value as-is and
  # don't coerce.
  processSource =
    { file, name }:
    let
      fileStr = toString file;
      regions = extractRegions {
        inherit file;
        fileLabel = fileStr;
      };
      files = map (
        r:
        let
          drv = pkgs.writeText "snippet-${name}-${r.name}.nix" r.body;
        in
        {
          subdir = name;
          filename = "${r.name}.nix";
          drv = drv;
        }
      ) regions;
      manifestEntry = {
        inherit name;
        file = fileStr;
        regions = map (r: r.name) regions;
      };
    in
    {
      inherit files manifestEntry;
    };

in
{
  mkSnippets =
    { sources }:
    let
      processed = map processSource sources;
      allFiles = builtins.concatLists (map (p: p.files) processed);
      manifest = {
        sources = map (p: p.manifestEntry) processed;
      };
      manifestFile = builtins.toFile "manifest.json" (builtins.toJSON manifest);

      copyCommands = lib.concatMapStringsSep "\n" (f: ''
        mkdir -p $out/${f.subdir}
        cp ${f.drv} $out/${f.subdir}/${f.filename}
      '') allFiles;
    in
    pkgs.runCommand "kix-doc-snippets" { } ''
      mkdir -p $out
      ${copyCommands}
      cp ${manifestFile} $out/manifest.json
    '';
}

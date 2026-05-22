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
                  # Line numbers of the first/last body lines (the `# region:`
                  # and `# endregion` lines themselves are excluded).
                  startLine = state.current.startLine + 1;
                  endLine = state.lineNo - 1;
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
  # Emit TWO files per region:
  # - `<region>.nix`  — raw code, importable as `?raw` for use with
  #   Starlight's `<Code lang="nix" code={...} />`.
  # - `<region>.json` — metadata + code: `{ code, source, startLine,
  #   endLine, url }`. Importable directly as JSON in MDX; wrap with
  #   the `<Snippet>` component to render code + a "View source" link.
  #
  # `sourceUrlBase` is optional; if null, `url` is omitted.
  # `file` may be a Nix path OR a flake-store interpolation string —
  # `builtins.readFile` accepts both, so we don't coerce.
  processSource =
    {
      file,
      name,
      sourceUrlBase,
    }:
    let
      fileStr = toString file;
      regions = extractRegions {
        inherit file;
        fileLabel = fileStr;
      };
      relPath = "${name}.nix";
      mkUrl =
        r:
        if sourceUrlBase == null then
          null
        else
          "${sourceUrlBase}/${relPath}#L${toString r.startLine}-L${toString r.endLine}";
      files = builtins.concatLists (
        map (
          r:
          let
            metadata = {
              code = r.body;
              source = relPath;
              startLine = r.startLine;
              endLine = r.endLine;
              url = mkUrl r;
            };
            nixDrv = pkgs.writeText "snippet-${name}-${r.name}.nix" r.body;
            jsonDrv = pkgs.writeText "snippet-${name}-${r.name}.json" (builtins.toJSON metadata);
          in
          [
            {
              subdir = name;
              filename = "${r.name}.nix";
              drv = nixDrv;
            }
            {
              subdir = name;
              filename = "${r.name}.json";
              drv = jsonDrv;
            }
          ]
        ) regions
      );
      manifestEntry = {
        inherit name;
        file = fileStr;
        regions = map (r: {
          inherit (r) name startLine endLine;
        }) regions;
      };
    in
    {
      inherit files manifestEntry;
    };

  mkSnippetsImpl =
    {
      sources,
      sourceUrlBase ? null,
    }:
    let
      processed = map (s: processSource (s // { inherit sourceUrlBase; })) sources;
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

  # Auto-discover: scan a directory tree for `.nix` files containing at
  # least one `# region:NAME` marker. Each discovered file becomes a
  # source; the snippet output path mirrors the file's location under
  # the tree, with `.nix` stripped from the filename component.
  #
  # Example: with `root = "${kix-examples}/examples"`, a marker inside
  # `06-scorecards/scorecard.nix` lands at
  # `$out/06-scorecards/scorecard/<region>.nix`.
  #
  # `sourceUrlBase` (optional): if set, emitted JSON sidecars include
  # a `url` pointing to the source line range. Format:
  # `<sourceUrlBase>/<rel>#L<start>-L<end>`. Example value:
  # `https://github.com/kix-ops/kix-examples/blob/main/examples`.
  mkSnippetsFromTreeImpl =
    {
      root,
      sourceUrlBase ? null,
    }:
    let
      # Recursively list .nix files under `dir`, returning records of
      # { abs; rel; } where `rel` is the path relative to root.
      listNixFiles =
        dir: prefix:
        let
          entries = builtins.readDir dir;
        in
        lib.concatLists (
          lib.mapAttrsToList (
            entryName: type:
            let
              entryPath = dir + "/${entryName}";
              relPath = if prefix == "" then entryName else "${prefix}/${entryName}";
            in
            if type == "directory" then
              listNixFiles entryPath relPath
            else if type == "regular" && lib.hasSuffix ".nix" entryName then
              [
                {
                  abs = entryPath;
                  rel = relPath;
                }
              ]
            else
              [ ]
          ) entries
        );

      # File contains at least one `# region:NAME` line?
      hasRegions =
        file:
        let
          lines = lib.splitString "\n" (builtins.readFile file);
        in
        lib.any (line: builtins.match startRe line != null) lines;

      allNixFiles = listNixFiles root "";
      withRegions = builtins.filter (f: hasRegions f.abs) allNixFiles;

      sources = map (f: {
        file = f.abs;
        name = lib.removeSuffix ".nix" f.rel;
      }) withRegions;
    in
    mkSnippetsImpl { inherit sources sourceUrlBase; };

in
{
  mkSnippets = mkSnippetsImpl;
  mkSnippetsFromTree = mkSnippetsFromTreeImpl;
}

# Snippet extraction: pull named regions out of `.nix` source files and
# emit raw code plus JSON metadata for MDX docs pages.
#
# Marker convention:
#   # region:NAME
#   <body>
#   # endregion:NAME
#
# - NAME matches [a-zA-Z][a-zA-Z0-9-]* (the brief specifies lowercase
#   but uses `isProxy` in its demo example; allow camelCase identifiers).
# - Markers must be on their own line (leading/trailing whitespace ok).
# - Nested regions are allowed; no duplicate names per file.
# - Marker lines themselves are NOT included in the body.
# - Indentation is preserved (no dedent).

{ pkgs, lib }:

let
  # Regex matchers — `builtins.match` returns null on no match,
  # or a list of capture groups.
  startRe = "[[:space:]]*#[[:space:]]*region:([a-zA-Z][a-zA-Z0-9-]*)[[:space:]]*";
  endRe = "[[:space:]]*#[[:space:]]*endregion:([a-zA-Z][a-zA-Z0-9-]*)[[:space:]]*";

  matchStart = line: builtins.match startRe line;
  matchEnd = line: builtins.match endRe line;

  # Extract all regions from one file.
  # Returns { regions = [{ name; body; }]; } or throws on validation failure.
  extractRegions =
    { file, fileLabel }:
    let
      content = builtins.readFile file;
      lines = lib.splitString "\n" content;

      closeRegion =
        state: endName:
        let
          stack = state.stack;
          top = builtins.head stack;
          rest = builtins.tail stack;
          bodyLen = builtins.length top.bodyLines;
          region = {
            name = top.name;
            body = builtins.concatStringsSep "\n" top.bodyLines;
            children = top.children;
            # Line numbers of the first/last body lines (the `# region:`
            # and `# endregion:NAME` lines themselves are excluded).
            startLine = top.startLine + 1;
            endLine = state.lineNo - 1;
          };
        in
        if stack == [ ] then
          throw "snippets: ${fileLabel}: line ${toString state.lineNo}: '# endregion:${endName}' without a matching '# region:${endName}'"
        else if endName != top.name then
          throw "snippets: ${fileLabel}: line ${toString state.lineNo}: '# endregion:${endName}' closes region '${top.name}'"
        else if rest == [ ] then
          state
          // {
            stack = [ ];
            regions = state.regions ++ [ region ];
            lineNo = state.lineNo + 1;
          }
        else
          let
            parent = builtins.head rest;
            parentRest = builtins.tail rest;
            childStart = top.parentBodyStartLine;
            childEnd = childStart + bodyLen - 1;
            parent' = parent // {
              bodyLines = parent.bodyLines ++ top.bodyLines;
              children = parent.children ++ [
                {
                  name = top.name;
                  startLine = childStart;
                  endLine = childEnd;
                }
              ];
            };
          in
          state
          // {
            stack = [ parent' ] ++ parentRest;
            regions = state.regions ++ [ region ];
            lineNo = state.lineNo + 1;
          };

      # Fold over lines, threading state:
      #   { stack   = [{ name; startLine; bodyLines; children; ... }];
      #     regions = [{ name; body; children; }];
      #     names   = [];  # for dup detection
      #     lineNo  = 1;
      #   }
      step =
        state: line:
        let
          startMatch = matchStart line;
          endMatch = matchEnd line;
          inRegion = state.stack != [ ];
        in
        if startMatch != null then
          # Opening marker.
          let
            name = builtins.head startMatch;
            parentBodyStartLine =
              if inRegion then (builtins.length (builtins.head state.stack).bodyLines) + 1 else null;
          in
          if builtins.elem name state.names then
            throw "snippets: ${fileLabel}: line ${toString state.lineNo}: duplicate region name '${name}'"
          else
            state
            // {
              stack = [
                {
                  inherit name parentBodyStartLine;
                  startLine = state.lineNo;
                  bodyLines = [ ];
                  children = [ ];
                }
              ]
              ++ state.stack;
              names = state.names ++ [ name ];
              lineNo = state.lineNo + 1;
            }
        else if endMatch != null then
          closeRegion state (builtins.head endMatch)
        else if builtins.match "[[:space:]]*#[[:space:]]*endregion[[:space:]]*" line != null then
          let
            exampleName = if inRegion then (builtins.head state.stack).name else "NAME";
          in
          throw "snippets: ${fileLabel}: line ${toString state.lineNo}: end marker must name the region, e.g. '# endregion:${exampleName}'"
        else if inRegion then
          let
            top = builtins.head state.stack;
            rest = builtins.tail state.stack;
          in
          state
          // {
            stack = [
              (
                top
                // {
                  bodyLines = top.bodyLines ++ [ line ];
                }
              )
            ]
            ++ rest;
            lineNo = state.lineNo + 1;
          }
        else
          state // { lineNo = state.lineNo + 1; };

      final = builtins.foldl' step {
        stack = [ ];
        regions = [ ];
        names = [ ];
        lineNo = 1;
      } lines;
    in
    if final.stack != [ ] then
      let
        top = builtins.head final.stack;
      in
      throw "snippets: ${fileLabel}: unterminated region '${top.name}' (opened at line ${toString top.startLine})"
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
              childRegions = r.children;
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
  # Example: with `root = "${kix-examples}"`, a marker inside
  # `examples/19-scorecards/scorecard.nix` lands at
  # `$out/examples/19-scorecards/scorecard/<region>.nix`.
  #
  # `sourceUrlBase` (optional): if set, emitted JSON sidecars include
  # a `url` pointing to the source line range. Format:
  # `<sourceUrlBase>/<rel>#L<start>-L<end>`. Example value:
  # `https://github.com/kix-ops/kix-examples/blob/main`.
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

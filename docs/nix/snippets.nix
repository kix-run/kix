# Snippet extraction: pull named regions out of supported source files and
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
  # Regex matchers: `builtins.match` returns null on no match,
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
  # - `<region>.<extension>`: raw code, importable as `?raw` for use with
  #   Starlight's `<Code>` component.
  # - `<region>.json`: metadata + code: `{ code, source, startLine,
  #   endLine, url }`. Importable directly as JSON in MDX; wrap with
  #   the `<Snippet>` component to render code + a "View source" link.
  #
  # `sourceUrlBase` is optional; if null, `url` is omitted.
  # `file` may be a Nix path OR a flake-store interpolation string:
  # `builtins.readFile` accepts both, so we don't coerce.
  processSource =
    {
      file,
      name,
      extension ? "nix",
      lang ? "nix",
      sourceUrlBase,
    }:
    let
      fileStr = toString file;
      regions = extractRegions {
        inherit file;
        fileLabel = fileStr;
      };
      relPath = "${name}.${extension}";
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
              inherit lang;
              source = relPath;
              startLine = r.startLine;
              endLine = r.endLine;
              url = mkUrl r;
            };
            sourceDrv = pkgs.writeText "snippet-${name}-${r.name}.${extension}" r.body;
            jsonDrv = pkgs.writeText "snippet-${name}-${r.name}.json" (builtins.toJSON metadata);
          in
          [
            {
              subdir = name;
              filename = "${r.name}.${extension}";
              drv = sourceDrv;
            }
            {
              subdir = name;
              filename = "${r.name}.json";
              drv = jsonDrv;
            }
          ]
        ) regions
      );
      # The manifest is metadata: keep it free of store-path
      # references so `builtins.toFile` works even when the
      # underlying source flake input hasn't yet been materialised
      # in the local Nix store (this comes up in CI where overrides
      # delay realisation).
      manifestEntry = {
        inherit name;
        file = relPath;
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

  # Auto-discover: scan a directory tree for supported files containing at
  # least one `# region:NAME` marker. Each discovered file becomes a
  # source; the snippet output path mirrors the file's location under
  # the tree, with the source extension stripped from the filename component.
  #
  # Example: with `root = "${kix-examples}"`, a marker inside
  # `examples/19-scorecards/scorecard.nix` lands at
  # `$out/examples/19-scorecards/scorecard/<region>.nix`.
  #
  # `sourceUrlBase` (optional): if set, emitted JSON sidecars include
  # a `url` pointing to the source line range. Format:
  # `<sourceUrlBase>/<rel>#L<start>-L<end>`. Example value:
  # `https://github.com/kix-run/kix-examples/blob/main`.
  mkSnippetsFromTreeImpl =
    {
      root,
      sourceUrlBase ? null,
    }:
    let
      languageFor =
        fileName:
        if lib.hasSuffix ".nix" fileName then
          {
            extension = "nix";
            lang = "nix";
          }
        else if lib.hasSuffix ".sh" fileName then
          {
            extension = "sh";
            lang = "sh";
          }
        else if lib.hasSuffix ".py" fileName then
          {
            extension = "py";
            lang = "python";
          }
        else
          null;

      # Recursively list supported files under `dir`, returning records of
      # { abs; rel; extension; lang; } where `rel` is relative to root.
      listSourceFiles =
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
              language = languageFor entryName;
            in
            if type == "directory" then
              listSourceFiles entryPath relPath
            else if type == "regular" && language != null then
              [
                {
                  abs = entryPath;
                  rel = relPath;
                  inherit (language) extension lang;
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

      allSourceFiles = listSourceFiles root "";
      withRegions = builtins.filter (f: hasRegions f.abs) allSourceFiles;

      sources = map (f: {
        file = f.abs;
        name = lib.removeSuffix ".${f.extension}" f.rel;
        inherit (f) extension lang;
      }) withRegions;
    in
    mkSnippetsImpl { inherit sources sourceUrlBase; };

in
{
  mkSnippets = mkSnippetsImpl;
  mkSnippetsFromTree = mkSnippetsFromTreeImpl;
}

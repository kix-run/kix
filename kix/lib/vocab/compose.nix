# Compose workload, Service, env, and policy helpers, and re-export the
# vocabulary modules under `kix.*`.
{ lib }:

let
  inherit (import ../core/error.nix { inherit lib; }) fail failOf;
  markers = import ../core/markers.nix { inherit lib; };

  kixAnnotations = import ../core/annotations.nix;
  kixKeys = kixAnnotations.keys;

  normalize = import ../core/normalize.nix { inherit lib; };
  versions = import ../core/version.nix { inherit lib; };

  quantity = import ./quantity.nix { inherit lib; };

  mounts = import ./mounts.nix { inherit lib; };
  optionsModule = import ./options.nix { inherit lib; };
  monitorModule = import ./monitor.nix { inherit lib; };
  exposeModule = import ./expose.nix { inherit lib; };

  argParsers = [
    "gnu"
    "go"
    "go-arg"
    "paerser"
  ];
  parserList = lib.concatMapStringsSep ", " (p: "\"${p}\"") argParsers;

  overlayHint = "To override the built resource directly, use partsOverlays on the instance, which runs after the package's checks.";

  # Return how `parser` matches words to command-line flags, for
  # `kix.mergeArgs` and `kix.argValues`. `isAttrs` says the flags are the
  # keys of an attribute set, which name a flag without dashes, though a key
  # written with them still reaches the program.
  flagMatcher =
    { parser, isAttrs }:
    let
      dashes = if parser == "go-arg" then "-+" else "--?";
      dashedName =
        word:
        let
          m = builtins.match "${dashes}([^-=][^=]*)(=.*)?" word;
        in
        if m == null then null else builtins.head m;
      isShortName = name: !isAttrs && parser == "gnu" && builtins.match "-[^-]" name != null;
    in
    rec {
      # Return the name of the flag `word` sets, or null when the parser
      # reads it as a value.
      nameOf =
        word:
        let
          n =
            if isAttrs then
              builtins.head (builtins.match "-*(.*)" word)
            else if parser == "gnu" then
              builtins.head (lib.splitString "=" word)
            else
              dashedName word;
        in
        if n != null && parser == "paerser" then lib.toLower n else n;

      # Return the name of the flag that a word the package passes sets, or
      # null when it is a value. Under "gnu", a word with one dash sets a
      # one-letter flag.
      wordName =
        word:
        if isAttrs then
          nameOf word
        else if !lib.hasPrefix "-" word then
          null
        else if parser == "gnu" && builtins.match "-[^-].*" word != null then
          builtins.substring 0 2 word
        else
          nameOf word;

      sets = name: word: nameOf word == name || (isShortName name && lib.hasPrefix name word);

      under =
        name: word:
        sets name word
        || (
          let
            n = nameOf word;
          in
          n != null && lib.hasPrefix "${name}." n
        );

      # Return the value that `word` carries for the flag `name` it sets,
      # or null when the value is the next word.
      attachedValue =
        name: word:
        let
          beforeEquals = builtins.stringLength (builtins.head (lib.splitString "=" word));
        in
        if isShortName name && word != name && !lib.hasPrefix "${name}=" word then
          builtins.substring 2 (-1) word
        else if beforeEquals < builtins.stringLength word then
          builtins.substring (beforeEquals + 1) (-1) word
        else
          null;
    };
in

rec {

  # Expose annotation keys from `core/annotations.nix`.
  keys = kixKeys;

  # Expose canonical annotation values from `core/annotations.nix`.
  keyValues = kixAnnotations.values;

  # Expose endpoint fact constructors (`core/facts.nix`).
  facts = {
    inherit (import ../core/facts.nix { inherit lib; }) refOnly connect structural;
  };

  # Format and inspect container image references (`{ repository; tag; digest?; }`).
  # These helpers do not validate digest syntax or query a registry. See
  # `pins.nix` for pin file loading and validation.
  image =
    let
      needField =
        caller: image: field:
        let
          v = image.${field} or null;
        in
        if v == null || v == "" then
          fail {
            message = "${caller}: '${field}' is missing or empty in image ${builtins.toJSON image}.";
            fix = "An image needs at least { repository, tag }.";
          }
        else
          v;
    in
    {
      # Render `repository:tag` with `@digest` appended when `digest` is non-null.
      # Discard string context so Nix-built image tags do not add build-time
      # store dependencies to rendered manifests while still allowing
      # `kix-image-sources.json` to classify the option value as `nix_built`.
      ref =
        image:
        builtins.unsafeDiscardStringContext (
          "${needField "kix.image.ref" image "repository"}:${needField "kix.image.ref" image "tag"}"
          + lib.optionalString (image.digest or null != null) "@${image.digest}"
        );

      # Return the version the image's tag names, or null when the tag names
      # none. A package publishes it as `out.version`, so an instance that
      # runs another image reports the version it runs.
      version =
        image:
        let
          tag = image.tag or null;
        in
        if tag == null then null else versions.ofTag (builtins.unsafeDiscardStringContext tag);

      # Return true when `image.digest` is present and non-null.
      isPinned = image: (image.digest or null) != null;

      # Return an assertion that the image's tag names the major.minor of
      # `release`, or one of the minors in `also` (such as "1.9"). A leading
      # `v` and anything after the minor number are ignored, because a user
      # may point the image at a rebuild that tags in another form. A
      # package puts it in `assertions` for each image whose files it
      # vendors from `release`. `reason` says what the release binds, and
      # `fix` says how to move the package to another release.
      checkRelease =
        {
          image,
          release,
          reason,
          option ? "image",
          also ? [ ],
          fix ? null,
        }:
        let
          tag = builtins.unsafeDiscardStringContext (needField "kix.image.checkRelease" image "tag");
          releaseMinor = versions.minorOf release;
          prefix = if builtins.match "[vV].*" release == null then "" else builtins.substring 0 1 release;
          minorText = m: prefix + lib.concatMapStringsSep "." toString m;
          accepted = map versions.minorOf also ++ [ releaseMinor ];
          acceptedText =
            let
              texts = map minorText accepted;
              n = builtins.length texts;
            in
            if n == 1 then
              builtins.head texts
            else
              lib.concatStringsSep ", " (lib.take (n - 1) texts) + ", or ${lib.last texts}";
          tagMinor = versions.minorOf tag;
          path = "${option}.tag";
        in
        if releaseMinor == null || builtins.elem null accepted then
          fail {
            message = "kix.image.checkRelease: release (${builtins.toJSON release}) or an entry in also (${builtins.toJSON also}) is missing major and minor version numbers, so Kix cannot check this image tag.";
            fix = "Pass a version with at least major and minor numbers, such as \"v1.10.0\" for release and \"1.9\" in also.";
          }
        else
          {
            assertion = builtins.elem tagMinor accepted;
            option = path;
            message = "${path} \"${tag}\" is not a ${acceptedText} release. Kix rejected it because ${reason}.";
            fix =
              "Set ${path} to a tag from the ${acceptedText} release series, or remove ${path} to use the default."
              + lib.optionalString (fix != null) " ${fix}";
          };
    };

  port = name: containerPort: {
    inherit name containerPort;
    protocol = "TCP";
  };

  # Convert an attrset of environment variables into a Kubernetes `env` list,
  # dropping null entries. Each value may be a string or a `valueFrom` attrset
  # (such as `secret.out.keyRef "password"`), which preserves its dependency
  # context so the workload is ordered after the referenced resource.
  mkEnvVars =
    attrs:
    lib.mapAttrsToList (
      name: value:
      if !builtins.isAttrs value || value ? outPath || value ? __toString then
        { inherit name value; }
      else if value ? valueFrom then
        value // { inherit name; }
      else
        fail {
          message = "kix.mkEnvVars: ${name} is an attrset with no `valueFrom`, which would render as an env var whose value is an object. Got: ${builtins.toJSON (builtins.attrNames value)}";
          fix = "Pass a string, or a source such as `secret.out.keyRef \"key\"`.";
        }
    ) (lib.filterAttrs (_: v: v != null) attrs);

  mkEnv = attrs: raw: (mkEnvVars attrs) ++ raw;

  # Merge `overrides` into `base` with `lib.recursiveUpdate`, failing if
  # `overrides` touches any attribute path in `locked` or replaces a parent of
  # a locked path with a non-attrset value. `option` is the instance option
  # that holds `overrides`, and the error names it. Set it to null when
  # `overrides` comes from somewhere else, such as an argument of a function
  # the package publishes in `out`. `object` names the Kubernetes object the
  # merge builds, `{ kind; name; namespace ? null; }`, when the instance
  # builds several from one option.
  mergeGuarded =
    {
      scope ? null,
      who ? null,
      locked,
      option ? "extraSpec",
      what ? null,
      object ? null,
    }:
    base: overrides:
    let
      scopeFail =
        let
          f = failOf "mergeGuarded" { inherit scope who; };
        in
        if what != null then
          f {
            id = "K0998";
            message = "kix.mergeGuarded no longer accepts `what`. That argument is now named `option`.";
            fix = "Rename `what` to `option`.";
          }
        else
          f;

      # Return the shortest proper prefix of `path` that `overrides` sets to a
      # non-attrset, or null when none exists.
      replacingAncestor =
        path:
        lib.findFirst (
          prefix:
          lib.hasAttrByPath prefix overrides && !builtins.isAttrs (lib.getAttrFromPath prefix overrides)
        ) null (map (n: lib.take n path) (lib.range 1 (builtins.length path - 1)));

      describe =
        path:
        let
          shown = lib.concatStringsSep "." path;
          ancestor = replacingAncestor path;
          value = lib.getAttrFromPath ancestor overrides;
        in
        if lib.hasAttrByPath path overrides then
          shown
        else if ancestor == null then
          null
        else
          "${shown} (replaced by `${lib.concatStringsSep "." ancestor} = ${
            if value == null then "null" else "<${builtins.typeOf value}>"
          }`)";

      touched = builtins.filter (d: d != null) (map describe locked);
    in
    if touched != [ ] then
      let
        pronoun = if builtins.length touched == 1 then "it" else "them";
      in
      scopeFail {
        inherit option object;
        message = "${
          if option == null then "The overrides set" else "${option} overrides"
        } ${lib.concatStringsSep ", " touched}, which this package sets itself.";
        fix = "Remove ${pronoun}${lib.optionalString (option != null) " from ${option}"}.";
      }
    else
      builtins.seq scopeFail (lib.recursiveUpdate base overrides);

  # Validate Kubernetes resource quantities (`vocab/quantity.nix`).
  types.quantity = quantity.type;

  # Parse a Kubernetes quantity `q` into millicores when `resource` is "cpu"
  # and into bytes otherwise, rounded down, or return null when `q` is not a
  # valid quantity.
  parseQuantity = quantity.parse;

  # Merge package `defaults`, user `env` (`kix.options.env`), and package-owned
  # variables into an attrset for `kix.mkEnvVars`.
  #
  # Each entry in `owned` has `{ vars ? { }; names ? [ ]; from; fix ? null; }`
  # or `{ names; reason; fix ? null; }`. Without `fix`, the error tells the
  # user to remove the variable from `option`. `vars` are added to the result, while
  # `names` reserves variables delivered via `envFrom` or refused outright.
  # Throws if `env` defines any key in `vars` or `names` (even as null). The
  # error names `option`, the instance option that holds `env`. It says a
  # variable comes `from` somewhere, or that the package does not accept it
  # and why, when the group gives a `reason`.
  mergeEnv =
    {
      scope ? null,
      who ? null,
      option ? "env",
      owned ? [ ],
      defaults ? { },
    }:
    env:
    let
      scopeFail = failOf "mergeEnv" { inherit scope who; };
      hits =
        group:
        builtins.filter (n: env ? ${n}) (builtins.attrNames (group.vars or { }) ++ group.names or [ ]);
      lines = builtins.concatMap (
        group:
        let
          h = hits group;
        in
        lib.optional (h != [ ]) {
          inherit option;
          message =
            "${option} sets ${lib.concatStringsSep ", " h}, which "
            + (
              if group ? reason then
                "this package does not accept: ${group.reason}"
              else
                "${if builtins.length h == 1 then "comes" else "come"} from ${group.from}."
            );
          fix = group.fix or "Remove ${if builtins.length h == 1 then "it" else "them"} from ${option}.";
        }
      ) owned;
    in
    if lines != [ ] then
      scopeFail lines
    else
      builtins.seq scopeFail (
        defaults // env // lib.foldl' (acc: group: acc // group.vars or { }) { } owned
      );

  # Merge the package's command-line arguments with the user's `extraArgs`
  # and return the container's whole argument list. Refuse an `extraArgs`
  # that sets a flag the package owns.
  #
  # `parser` says how the program reads its flags, and every call states it:
  #
  # - "gnu" fits getopt, clap, pflag, and kingpin. A word sets a flag when
  #   it equals the flag or starts with `<flag>=`. A one-letter flag such as
  #   `-c` also matches a word with its value attached (`-c/etc/x`), and so
  #   also matches `-vmodule=x` when `-v` is owned.
  # - "go" fits Go's `flag` package, which reads `-flag` and `--flag` as the
  #   same flag. A word sets the flag named by its text after one or two
  #   dashes and before any `=`.
  # - "go-arg" fits alexflint/go-arg, which reads flags as "go" does and
  #   accepts any number of leading dashes.
  # - "paerser" fits Traefik's flag parser, which reads flags as "go" does
  #   and ignores the letter case of the name.
  #
  # `args` lists what the package passes, in order. The user's `extraArgs`
  # follow it, and `after` lists what the package passes behind them. Each
  # entry is one of:
  #
  # - A string. It is passed as written, and `extraArgs` may set the same
  #   flag again.
  # - `{ defaults = [ "--flag=value" ]; }`. Each word is passed unless
  #   `extraArgs` sets the same flag, for a program that refuses a flag
  #   given twice. Write each default as one word. Under "gnu", a default
  #   with one dash is a one-letter flag.
  # - `{ owned ? [ ]; names ? [ ]; families ? [ ]; reason; fix ? null; }`,
  #   or the same with `from` in place of `reason`. The words in `owned` are
  #   passed as written, and `extraArgs` may not set their flags. A word in
  #   `owned` that starts with a dash names a flag, read as a default is.
  #   Any other word is a value of the flag before it. `names` reserves
  #   flags the package does not pass here, such as the short form of an
  #   owned flag or a flag the package does not support. `families` reserves
  #   a flag and every flag under it (`<flag>.<name>`), for a program that
  #   turns a feature on when any of its settings is set.
  #
  # The error names `option`, the instance option that holds `extraArgs`,
  # and the word the user wrote. It says the flag comes `from` somewhere, or
  # that the package does not accept it and why, when the entry gives a
  # `reason`. Without `fix`, the error tells the user to remove the flag
  # from `option`. Every error adds that `partsOverlays` can still change
  # the built resource. Set `id` to a change record id for the releases
  # after a package starts refusing a spelling it used to pass.
  #
  # `extraArgs` is either a list of command-line words or an attribute set
  # of flags keyed by flag name, the form a VictoriaMetrics resource's
  # `extraArgs` takes. For an attribute set, `owned` and `defaults` are
  # attribute sets of flag values, a string entry is refused, keys match
  # once their leading dashes are removed, and order has no meaning.
  mergeArgs =
    {
      scope ? null,
      option ? "extraArgs",
      parser ? null,
      args ? [ ],
      after ? [ ],
      id ? null,
    }:
    extraArgs:
    let
      scopeFail = failOf "mergeArgs" {
        inherit scope;
        who = null;
      };
      isAttrs = builtins.isAttrs extraArgs;
      matcher = flagMatcher { inherit parser isAttrs; };
      written = if isAttrs then builtins.attrNames extraArgs else extraArgs;
      form = if isAttrs then "an attribute set" else "a list";
      keysOf = v: if builtins.isAttrs v then builtins.attrNames v else v;
      entries = args ++ after;

      groupKeys = [
        "owned"
        "names"
        "families"
        "reason"
        "from"
        "fix"
      ];
      # Return what is wrong with the form of `entry`, or null.
      entryProblem =
        entry:
        let
          unknown = builtins.attrNames (removeAttrs entry groupKeys);
          wrongForm =
            key:
            "passes `${key}` as ${
              if isAttrs then "a list" else "an attribute set"
            }, while ${option} is ${form}";
        in
        if builtins.isString entry then
          if isAttrs then "is a string, while ${option} is ${form}" else null
        else if !builtins.isAttrs entry then
          "has type ${builtins.typeOf entry}; expected a string or an attribute set"
        else if entry ? defaults then
          if builtins.attrNames entry != [ "defaults" ] then
            "sets attributes other than `defaults`"
          else if builtins.isAttrs entry.defaults != isAttrs then
            wrongForm "defaults"
          else
            null
        else if unknown != [ ] then
          "sets unknown attribute${lib.optionalString (builtins.length unknown != 1) "s"} ${
            lib.concatMapStringsSep ", " (k: "`${k}`") unknown
          }"
        else if (entry ? reason) == (entry ? from) then
          "must set either `reason` or `from` (not both)"
        else if entry ? owned && builtins.isAttrs entry.owned != isAttrs then
          wrongForm "owned"
        else
          null;
      entryLines = builtins.concatMap (
        entry:
        let
          problem = entryProblem entry;
        in
        lib.optional (problem != null) {
          message = "kix.mergeArgs received an invalid entry ${
            builtins.toJSON (if builtins.isFunction entry then "<function>" else entry)
          }: it ${problem}.";
          fix = "Pass each entry as a flag string (when ${option} is a list), `{ defaults = ...; }`, or `{ owned ? ...; names ? ...; families ? ...; }` with either `reason` or `from`.";
        }
      ) entries;

      groups = builtins.filter (e: builtins.isAttrs e && !(e ? defaults)) entries;
      defaultWords = builtins.concatMap (e: keysOf e.defaults) (
        builtins.filter (e: builtins.isAttrs e && e ? defaults) entries
      );

      # Each flag or family a group reserves, with the group it belongs to.
      # A word in `owned` that names no flag is a value and reserves nothing.
      rulesOf =
        group:
        let
          rules =
            source: test: nameOf: flags:
            map (flag: {
              inherit
                group
                source
                test
                flag
                ;
              name = nameOf flag;
            }) flags;
        in
        builtins.filter (r: r.name != null) (
          rules "owned" matcher.sets matcher.wordName (keysOf (group.owned or [ ]))
        )
        ++ rules "names" matcher.sets matcher.nameOf (group.names or [ ])
        ++ rules "families" matcher.under matcher.nameOf (group.families or [ ]);
      allRules = builtins.concatMap rulesOf groups;

      # The first word of each `owned` list when it names no flag.
      strayValues = builtins.concatMap (
        group:
        let
          words = keysOf (group.owned or [ ]);
        in
        lib.optional (words != [ ] && matcher.wordName (builtins.head words) == null) (builtins.head words)
      ) groups;

      authorLines =
        if parser == null then
          [
            {
              message = "kix.mergeArgs is missing `parser`, so Kix does not know how the program parses flags.";
              fix = "Set `parser` to one of: ${parserList}.";
            }
          ]
        else if !builtins.elem parser argParsers then
          [
            {
              message = "kix.mergeArgs does not support parser \"${toString parser}\", so Kix cannot check ${option}.";
              fix = "Set `parser` to one of: ${parserList}.";
            }
          ]
        else if entryLines != [ ] then
          entryLines
        else
          map (d: {
            message = "kix.mergeArgs cannot read \"${d}\" in `defaults` as a flag, so Kix cannot check ${option}.";
            fix = "Write each default as one string starting with `-` or `--`, such as \"--flag=value\" instead of separate \"--flag\" and \"value\" items.";
          }) (builtins.filter (d: matcher.wordName d == null) defaultWords)
          ++ map (word: {
            message = "kix.mergeArgs cannot read \"${word}\" (the first item in `owned`) as a flag, so Kix cannot check ${option}.";
            fix = "Start each `owned` list with a flag, such as `[ \"--config\" \"/etc/app.yaml\" ]`.";
          }) strayValues
          ++ map (r: {
            message = "kix.mergeArgs cannot read \"${r.flag}\" in `${r.source}` as a flag under parser \"${parser}\", so Kix cannot check ${option}.";
            fix = "Start each flag name in `names` and `families` with `-` or `--`, such as \"--leader-elect\".";
          }) (builtins.filter (r: r.name == null) allRules);

      # Each word the user wrote with the first rule it breaks.
      hits = builtins.concatMap (
        word:
        let
          rule = lib.findFirst (r: r.test r.name word) null allRules;
          inherit (rule) group;
        in
        lib.optional (rule != null) (
          {
            inherit option;
            message =
              "${option} sets \"${word}\", which "
              + (
                if group ? reason then
                  "this package does not accept: ${group.reason}"
                else
                  "comes from ${group.from}."
              );
            fix = "${group.fix or "Remove it from ${option}."} ${overlayHint}";
          }
          // lib.optionalAttrs (id != null) { inherit id; }
        )
      ) written;

      replaced = d: builtins.any (matcher.sets (matcher.wordName d)) written;
      # Return the words that the entries in `list` pass.
      words = builtins.concatMap (
        e:
        if builtins.isString e then
          [ e ]
        else if e ? defaults then
          builtins.filter (d: !replaced d) e.defaults
        else
          e.owned or [ ]
      );
      # Return the flags that the entries pass under `key`.
      flags = key: lib.foldl' (acc: e: acc // e.${key} or { }) { } entries;
      result =
        if isAttrs then
          lib.filterAttrs (d: _: !replaced d) (flags "defaults") // extraArgs // flags "owned"
        else
          words args ++ extraArgs ++ words after;
    in
    if authorLines != [ ] then
      scopeFail authorLines
    else if hits != [ ] then
      scopeFail hits
    else
      builtins.seq scopeFail result;

  # Return the values `args` gives `flag`, one for each time it sets the
  # flag, matched as `kix.mergeArgs` matches under the same `parser`. A
  # value is the text after `=`, the text attached to a one-letter flag
  # under "gnu", or else the next word. Ask only for a flag that takes a
  # value, because the next word after a flag that takes none is not its
  # value. For an attribute set of flags, return the values of the keys
  # that name `flag`.
  argValues =
    { parser }:
    flag: args:
    let
      isAttrs = builtins.isAttrs args;
      matcher = flagMatcher { inherit parser isAttrs; };
      name = matcher.nameOf flag;
      step =
        acc: word:
        let
          value = matcher.attachedValue name word;
        in
        if acc.takesNext then
          {
            takesNext = false;
            values = acc.values ++ [ word ];
          }
        else if !matcher.sets name word then
          acc
        else if value == null then
          acc // { takesNext = true; }
        else
          acc // { values = acc.values ++ [ value ]; };
    in
    if !builtins.elem parser argParsers then
      fail {
        message = "kix.argValues does not support parser \"${toString parser}\", so Kix cannot read flag \"${flag}\".";
        fix = "Set `parser` to one of: ${parserList}.";
      }
    else if name == null then
      fail {
        message = "kix.argValues cannot read \"${flag}\" as a flag under parser \"${parser}\".";
        fix = "Start the flag name with `-` or `--`, such as \"--namespaces\".";
      }
    else if isAttrs then
      builtins.attrValues (lib.filterAttrs (key: _: matcher.sets name key) args)
    else
      (lib.foldl' step {
        takesNext = false;
        values = [ ];
      } args).values;

  # Refuse a call to the function `kix.mergeArgs` replaced.
  guardArgs =
    {
      scope ? null,
      ...
    }:
    (if scope == null then fail else scope.fail) {
      id = "K5396";
      message = "kix.guardArgs was removed and replaced by kix.mergeArgs, which builds the full argument list from the package's flags and extraArgs.";
      fix = "Replace kix.guardArgs with kix.mergeArgs, set `parser`, and pass the package's flags (including `{ owned = [ ... ]; reason = \"...\"; }` entries) in `args`.";
    };

  # Validate that a secret dependency `dep` declares all required `keys` (and
  # at least one key group in `anyOf` when set) in `dep.out.keys`, then return
  # `dep`. Read `keyRef` through the returned value so validation runs first.
  # `arg` is the name the package takes `dep` under, and the error names it
  # as the dependency of the instance in `scope`.
  checkSecretKeys =
    {
      scope ? null,
      who ? null,
      arg,
      dep,
      keys ? [ ],
      anyOf ? null,
    }:
    let
      declared = if dep.out.keys or null == null then [ ] else dep.out.keys;
      missingOf = names: builtins.filter (k: !(builtins.elem k declared)) names;
      missingKeys = missingOf keys;
      groupMet = anyOf == null || builtins.any (group: missingOf group == [ ]) anyOf;
      showGroup = group: "[${lib.concatStringsSep ", " group}]";
      wanted =
        lib.optional (missingKeys != [ ]) (lib.concatStringsSep ", " missingKeys)
        ++ lib.optional (!groupMet) "one of ${lib.concatMapStringsSep " or " showGroup anyOf}";
      declaredText = if declared == [ ] then "no keys" else lib.concatStringsSep ", " declared;
      scopeFail = failOf "checkSecretKeys" { inherit scope who; };
    in
    if dep == null || wanted == [ ] then
      builtins.seq scopeFail dep
    else
      scopeFail {
        dependency = arg;
        message = "deps.${arg} resolved to secret \"${dep.out.name}\", which declares ${declaredText}; this package reads ${lib.concatStringsSep " and " wanted}.";
        fix = "Add them to that instance's keys (a SOPS secret lists them in keys), or wire another secret with deps.${arg} = ref.<ns>.<instance>.";
      };

  # Build a network policy for operand pods created at runtime by an operator,
  # or return null when no policy is needed.
  #
  # Drops `ingress`/`ingressDeny` or `egress`/`egressDeny` sections for
  # directions the cluster does not enforce (`scope.networkPolicyEnforced`),
  # because including an unenforced direction would isolate the pods in that
  # direction. Returns null when `scope` has no enforcer or all sections were
  # dropped.
  operandPolicy =
    {
      scope,
      name,
      spec,
    }:
    let
      enforced = scope.networkPolicyEnforced;
      sections = {
        ingress = [
          "ingress"
          "ingressDeny"
        ];
        egress = [
          "egress"
          "egressDeny"
        ];
      };
      unenforced =
        lib.optionals (!enforced.ingress) sections.ingress
        ++ lib.optionals (!enforced.egress) sections.egress;
      enforcedSpec = removeAttrs spec unenforced;
      hasSection = s: builtins.any (k: s ? ${k}) (sections.ingress ++ sections.egress);
    in
    if scope.networkPolicyEnforcer == null || (hasSection spec && !hasSection enforcedSpec) then
      null
    else
      scope.networkPolicyEnforcer.netpol.mkPolicy {
        mkResource = scope.mkResource;
        extraArgs = {
          inherit name;
          spec = enforcedSpec;
          labels = {
            ${kixKeys.derived} = "true";
            ${kixKeys.policyType} = "operator-managed-workload";
          };
          extraDeps = [ ];
        };
      };

  service = {
    extractPorts =
      workload:
      let
        containers = workload.rawManifest.spec.template.spec.containers or [ ];
        allPorts = builtins.concatMap (c: c.ports or [ ]) containers;
      in
      map (
        cp:
        {
          port = cp.containerPort;
          protocol = cp.protocol or "TCP";
        }
        // lib.optionalAttrs (cp ? name) {
          name = cp.name;
        }
      ) allPorts;

    fromWorkload =
      {
        name,
        type ? "ClusterIP",
        ports ? null,
        ...
      }@cfg:
      workload:
      let
        finalPorts = if ports != null then ports else service.extractPorts workload;
        firstPort = if finalPorts != [ ] then toString (builtins.head finalPorts).port else null;
        autoOutputs = lib.optionalAttrs (firstPort != null) { port = firstPort; };
        passthrough = removeAttrs cfg [
          "name"
          "type"
          "ports"
        ];

        workloadPortNames = lib.unique (
          builtins.concatMap (c: builtins.catAttrs "name" (c.ports or [ ])) (
            workload.rawManifest.spec.template.spec.containers or [ ]
          )
        );
        workloadPortNumbers = builtins.listToAttrs (
          builtins.concatMap (
            c:
            map (cp: {
              name = cp.name;
              value = cp.containerPort;
            }) (builtins.filter (cp: cp ? name) (c.ports or [ ]))
          ) (workload.rawManifest.spec.template.spec.containers or [ ])
        );
        badTargets = builtins.filter (
          p:
          (p ? targetPort)
          && builtins.isString p.targetPort
          && !(builtins.elem p.targetPort workloadPortNames)
        ) finalPorts;
        # Resolve named `targetPort` values to numbers while the workload is
        # available, because Cilium 1.19 drops egress traffic when derived
        # network-policy rules use named ports.
        resolvedPorts = map (
          p:
          if (p ? targetPort) && builtins.isString p.targetPort then
            p // { targetPort = workloadPortNumbers.${p.targetPort}; }
          else
            p
        ) finalPorts;
        _portCheck =
          if ports != null && badTargets != [ ] then
            fail {
              message =
                "service.fromWorkload '${name}': targetPort(s) [${
                  builtins.concatStringsSep ", " (map (p: "\"${p.targetPort}\"") badTargets)
                }] do not match any named container port on the workload. "
                + "Declared container ports: [${builtins.concatStringsSep ", " workloadPortNames}].";
            }
          else
            null;
      in
      # Merge passthrough fields into the generated Service so additions such
      # as `spec.clusterIP` preserve its selector and ports.
      builtins.seq _portCheck (
        lib.recursiveUpdate {
          apiVersion = "v1";
          kind = "Service";
          inherit name;
          spec = {
            inherit type;
            selector = workload.out.selector;
            ports = resolvedPorts;
          };
          outputs = autoOutputs // (cfg.outputs or { });
        } (removeAttrs passthrough [ "outputs" ])
      );
  };

  inherit (normalize) keep;

  untrackedRef = markers.mkUntrackedRef;

  providedLoadBalancerClass = markers.mkProvidedLoadBalancerClass;

  inherit (mounts)
    mount
    _injectMounts
    withMounts
    withMountsOn
    ;

  options = optionsModule;

  healthCheck = import ./health-check.nix {
    inherit
      lib
      image
      mkEnvVars
      mount
      withMountsOn
      ;
  };

  inherit (exposeModule)
    ingress
    httpRoute
    gatewayPathType
    expose
    ;

  inherit (monitorModule)
    monitor
    alerts
    reconcileErrorsAlert
    ;
}

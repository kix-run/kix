# Instance pins, and where each image option's value comes from.
#
# An instance pin is an entry in a pin file's `instances` map:
# `"<namespace>/<instance>": { "<option path>": <pin> }`. It is applied as
# one more definition of the instance's config, from a module whose `_file`
# is the pin file, so the module system records the pin file as the place
# the value was defined. `check` refuses a pin that shares its option with
# a definition in code it does not win over, and `imageSources` reads those
# records back.
{ lib, packageDefaultPriority }:

let
  # Store paths of flake sources are `/nix/store/<hash>-source/<path>`.
  # Provenance reports the part after the source root, which is the path in
  # the repository for a flake at the repository root.
  relativeFile =
    file:
    let
      m = builtins.match "/nix/store/[^/]+/(.*)" file;
    in
    if m == null then file else builtins.head m;

  # The module system names a definition from a cluster module as
  # "<file>, via option instances.<ns>.<inst>.config", and an inline module
  # as "<unknown-file>, via option …".
  moduleFile =
    file:
    let
      m = builtins.match "(.*), via option .*" file;
      f = if m == null then file else builtins.head m;
    in
    if f == "<unknown-file>" then null else f;

  # Where one definition was written: the position of its first attribute
  # when the value is an attrset from Nix source, otherwise the module's file.
  # Values read from JSON have no position.
  definitionPlace =
    def:
    let
      positions =
        if builtins.isAttrs def.value then
          builtins.filter (p: p != null) (
            map (n: builtins.unsafeGetAttrPos n def.value) (builtins.attrNames def.value)
          )
        else
          [ ];
      file = moduleFile def.file;
    in
    if positions != [ ] then
      {
        file = relativeFile (builtins.head positions).file;
        line = (builtins.head positions).line;
      }
    else
      {
        file = if file == null then null else relativeFile file;
        line = null;
      };

  describePlace =
    def:
    let
      p = definitionPlace def;
    in
    if p.file == null then
      "a module with no file (${def.file})"
    else if p.line == null then
      p.file
    else
      "${p.file} line ${toString p.line}";

  # An image option is a submodule option declared by `kix.options.image`.
  isImageOption =
    opt:
    (builtins.tryEval (
      opt.type.name == "submodule"
      && (
        let
          sub = opt.type.getSubOptions [ ];
        in
        sub ? repository && sub ? tag && sub ? digest
      )
    )).value or false;

  # Paths of the image options in an evaluated options tree. Options inside
  # submodules are not entered: an instance pin addresses an option of the
  # package, not an element of one.
  imageOptionPaths =
    prefix: opts:
    builtins.concatLists (
      lib.mapAttrsToList (
        k: o:
        if lib.isOption o then
          lib.optional (isImageOption o) (prefix ++ [ k ])
        else if builtins.isAttrs o && !(o ? _type) then
          imageOptionPaths (prefix ++ [ k ]) o
        else
          [ ]
      ) opts
    );

  showPaths = paths: lib.concatMapStringsSep ", " (lib.concatStringsSep ".") paths;
in
{
  inherit relativeFile imageOptionPaths;

  # The module that applies one instance's pins. `instancePins` is
  # `{ file; options; }`: the pin file, and option path to pin.
  module = instancePins: {
    _file = instancePins.file;
    config = lib.foldl' lib.recursiveUpdate { } (
      lib.mapAttrsToList (
        option: pin: lib.setAttrByPath (lib.splitString "." option) pin
      ) instancePins.options
    );
  };

  # Throws unless each pinned option is an image option of the package and
  # the pin is its only definition outside the package. A value in code
  # beside the pin would otherwise merge with it field by field, or win over
  # it at a higher priority, with no sign of which one runs.
  #
  # A definition whose every field has a lower priority than the pin is left
  # out: the pin wins over it. That covers a package's defaults, such as a
  # follower image's `tag = lib.mkDefault config.image.tag` (lowered to
  # `packageDefaultPriority`), and a `lib.mkDefault` in cluster code. The
  # module system keeps such a definition here because the option itself,
  # the attrset around the field, is defined at the ordinary priority. A
  # package's `lib.mkForce` on a field is not weaker, so it is refused: the
  # instance would otherwise run the package's tag with the pin's digest.
  #
  # The declarations are checked first, against `packageOptions`: reading
  # the evaluated `options` with a pin for an undeclared option throws the
  # module system's own error, which does not list the options a pin can
  # set.
  check =
    {
      packageOptions,
      options,
      instancePins,
      instanceText,
    }:
    let
      where = relativeFile instancePins.file;
      pinned = builtins.attrNames instancePins.options;
      declared = builtins.foldl' (
        _: option:
        let
          opt = lib.attrByPath (lib.splitString "." option) null packageOptions;
        in
        if opt == null || !(lib.isOption opt) then
          throw "kix.pins: ${where} pins option '${option}' of ${instanceText}, and its package has no such option. Its image options are: ${
            let
              paths = imageOptionPaths [ ] packageOptions;
            in
            if paths == [ ] then "none" else showPaths paths
          }."
        else if !(isImageOption opt) then
          throw "kix.pins: ${where} pins option '${option}' of ${instanceText}, which is not an image option. A pin sets an option declared with kix.options.image."
        else
          null
      ) null pinned;
      alone = builtins.foldl' (
        _: option:
        let
          defs = (lib.getAttrFromPath (lib.splitString "." option) options).definitionsWithLocations;
          # `lib.mkOverride` wraps a field as `{ _type = "override"; priority; }`;
          # a higher number is a weaker definition.
          belowPin =
            v:
            builtins.isAttrs v
            && (v._type or null) == "override"
            && v.priority > (lib.mkOverride 100 null).priority;
          weaker =
            d:
            builtins.isAttrs d.value
            && !(d.value ? _type)
            && builtins.all belowPin (builtins.attrValues d.value);
          others = builtins.filter (d: d.file != instancePins.file && !(weaker d)) defs;
        in
        if others != [ ] then
          throw "kix.pins: ${where} pins option '${option}' of ${instanceText}, and ${
            lib.concatMapStringsSep " and " describePlace others
          } sets it too. Keep one of them: remove the other value, or delete the entry from the pin file."
        else
          null
      ) null pinned;
    in
    builtins.seq declared alone;

  # One record per image option of an evaluated instance: the value that
  # runs, the package's default, and the origin of the value.
  #
  #   package_default  no definition above the package's own defaults
  #   pin              the instance pin, or a cluster value equal to one of
  #                    the file's `images` pins (read with `pins.get`)
  #   injected         a dependency's config injection
  #   nix_built        a value that carries a Nix string context, so it was
  #                    derived from a build
  #   code             any other definition in the cluster's code
  #
  # A value that does not evaluate is left out; evaluating the cluster
  # reports it where it is used.
  imageSources =
    {
      namespaceName,
      instanceName,
      evaluation,
      packageConfigFile,
      instancePins ? null,
      pins ? null,
    }:
    builtins.concatMap (
      path:
      let
        opt = lib.getAttrFromPath path evaluation.options;
        value = lib.getAttrFromPath path evaluation.config;
        final = {
          repository = value.repository;
          tag = value.tag;
          digest = value.digest;
        };
        evaluates = (builtins.tryEval (builtins.deepSeq final true)).success;
        option = lib.concatStringsSep "." path;
        defs = opt.definitionsWithLocations;
        pinFile = if instancePins == null then null else instancePins.file;
        fromPin = instancePins != null && instancePins.options ? ${option};
        fromPackage =
          opt.highestPrio >= packageDefaultPriority || builtins.all (d: d.file == packageConfigFile) defs;
        injection = lib.findFirst (d: lib.hasPrefix "config injected into " d.file) null defs;
        imagePin =
          if pins == null then
            null
          else
            lib.findFirst (
              key:
              let
                p = pins.all.${key};
              in
              p.repository == final.repository && p.tag == final.tag && (p.digest or null) == final.digest
            ) null pins.keys;
        hasContext = builtins.hasContext final.repository || builtins.hasContext final.tag;
        code = lib.findFirst (d: d.file != packageConfigFile) (builtins.head defs) defs;
        place = definitionPlace code;
        noPlace = {
          file = null;
          line = null;
        };
        pinPlace = {
          file = if pins == null || pins.file == null then null else relativeFile pins.file;
          line = null;
        };

        origin =
          if fromPin then
            {
              origin = "pin";
              pin = {
                map = "instances";
                key = "${namespaceName}/${instanceName}";
              };
              dependency = null;
            }
            // {
              file = relativeFile pinFile;
              line = null;
            }
          else if fromPackage then
            {
              origin = "package_default";
              pin = null;
              dependency = null;
            }
            // noPlace
          else if injection != null then
            {
              origin = "injected";
              pin = null;
              dependency = builtins.head (builtins.match "config injected into .* by (.*)" injection.file);
            }
            // noPlace
          else if imagePin != null then
            {
              origin = "pin";
              pin = {
                map = "images";
                key = imagePin;
              };
              dependency = null;
            }
            // pinPlace
          else if hasContext then
            {
              origin = "nix_built";
              pin = null;
              dependency = null;
            }
            // place
          else
            {
              origin = "code";
              pin = null;
              dependency = null;
            }
            // place;

        default =
          if opt ? default && opt.default ? repository && opt.default ? tag then
            { inherit (opt.default) repository tag; }
          else
            null;
      in
      lib.optional evaluates (
        {
          namespace = namespaceName;
          instance = instanceName;
          inherit option default;
          # A Nix-built reference carries its build in its string context,
          # which `builtins.toFile` refuses.
          repository = builtins.unsafeDiscardStringContext final.repository;
          tag = builtins.unsafeDiscardStringContext final.tag;
          digest = if final.digest == null then null else builtins.unsafeDiscardStringContext final.digest;
        }
        // origin
      )
    ) (imageOptionPaths [ ] evaluation.options);
}

# Define the VolumeSnapshotClass option type (`kix.types.volumeSnapshotClass`)
# and the helpers that check and render a CSI driver's classes
# (`kix.storage.snapshotClassProblems` and `kix.storage.mkSnapshotClasses`).
#
# The VolumeSnapshotClass kind belongs to the provider of the
# `snapshotController` role, so a driver builds its classes from that
# dependency's CRD handle and has none without it.
{ lib }:

let
  defaultAnnotation = "snapshot.storage.kubernetes.io/is-default-class";

  # Join names as "a", "a and b", or "a, b, and c".
  joinNames =
    names:
    if builtins.length names < 3 then
      lib.concatStringsSep " and " names
    else
      "${lib.concatStringsSep ", " (lib.init names)}, and ${lib.last names}";

  type = lib.types.submodule {
    options = {
      deletionPolicy = lib.mkOption {
        type = lib.types.enum [
          "Delete"
          "Retain"
        ];
        default = "Delete";
        description = "What happens to the underlying snapshot when its VolumeSnapshot is deleted: `Delete` deletes it, and `Retain` keeps it.";
      };
      parameters = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Driver-specific snapshot parameters. Omitted from the manifest when empty.";
      };
      labels = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Labels on the VolumeSnapshotClass.";
      };
      annotations = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Annotations on the VolumeSnapshotClass. Setting `\"${defaultAnnotation}\" = \"true\"` makes this the default snapshot class for this driver's volumes.";
      };
    };
  };

  # Return the messages for the classes in `classes` that would not work:
  # classes with no provider of the snapshotController role, more than one
  # default class, and class names that Kix does not render as parts.
  # `snapshotController` is the dependency, or null when nothing provides it.
  snapshotClassProblems =
    {
      optionPath,
      classes,
      snapshotController,
    }:
    let
      names = builtins.attrNames classes;
      defaults = builtins.filter (
        n: (classes.${n}.annotations.${defaultAnnotation} or null) == "true"
      ) names;
    in
    lib.optional (names != [ ] && snapshotController == null)
      "${optionPath} defines ${lib.concatStringsSep ", " names}, but no instance in the cluster provides a snapshot controller (the snapshotController role), so Kix cannot build VolumeSnapshotClass resources. Add a packages.experimental.snapshot-controller instance, or remove ${optionPath}. If the cluster already runs a snapshot controller outside Kix, use a flavor that declares it or import it with kix.mkImport (setting roles = [ \"snapshotController\" ] and crds with VolumeSnapshotClass)."
    ++
      lib.optional (builtins.length defaults > 1)
        "${
          joinNames (map (n: "${optionPath}.${n}") defaults)
        } each set ${defaultAnnotation}=\"true\". A CSI driver can have at most one default VolumeSnapshotClass. With more than one default, creating a VolumeSnapshot without volumeSnapshotClassName fails. Keep this annotation on at most one class."
    # `instancePartResources` (`eval/helpers.nix`) skips keys named `root` or
    # `meta` at every depth, so a class under either key would not render.
    ++ map (
      n:
      "${optionPath}.${n}: Kix reserves the keys \"root\" and \"meta\", so this VolumeSnapshotClass cannot be built. Rename it."
    ) (builtins.filter (n: n == "root" || n == "meta") names);

  # Build one VolumeSnapshotClass for `driver` per entry of `classes`, keyed
  # like `classes`. Return no classes when `snapshotController` is null.
  mkSnapshotClasses =
    {
      scope,
      snapshotController,
      driver,
      classes,
      requires ? [ ],
    }:
    if snapshotController == null then
      { }
    else
      lib.mapAttrs (
        name: cls:
        scope.mkCR snapshotController.out.crds.VolumeSnapshotClass {
          inherit name requires;
          inherit (cls) labels annotations;
          extra = {
            inherit driver;
            inherit (cls) deletionPolicy;
          }
          // lib.optionalAttrs (cls.parameters != { }) { inherit (cls) parameters; };
        }
      ) classes;
in
{
  inherit type snapshotClassProblems mkSnapshotClasses;
}

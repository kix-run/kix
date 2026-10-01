# storage-classes: StorageClasses for CSI drivers already running in the
# cluster. It installs no provisioner; each class names a driver that some
# other installation (the environment, a cloud add-on, another package)
# provides.
#
# One instance provides the `storageClasses` role with a map of classes,
# hence the plural name: the role allows one provider per cluster.
# `out.storageClassName` is the class a consumer gets when it names none:
# the single class annotated `storageclass.kubernetes.io/is-default-class:
# "true"`, else the only class. With several classes and no single annotated
# one, reading it fails the build, so each consumer names its class.
#
# root = the first class by name; it requires every class.

{
  scope,
  lib,
  kix,
}:

{
  meta = {
    description = "StorageClasses for CSI drivers already installed in the cluster";
    owner = "platform";
    roles = [ "storageClasses" ];
  };

  options = {
    classes = lib.mkOption {
      type = lib.types.attrsOf (kix.types.storageClass { });
      example = lib.literalExpression ''
        {
          local-path-retain = {
            provisioner = "rancher.io/local-path";
            reclaimPolicy = "Retain";
            volumeBindingMode = "WaitForFirstConsumer";
          };
        }
      '';
      description = ''
        StorageClasses to create, keyed by class name. The CSI driver each
        class names in `provisioner` must already run in the cluster.
        Annotate one class `storageclass.kubernetes.io/is-default-class =
        "true"` to make it the cluster default; this is refused when the
        flavor reports that the environment already has a default class
        (`cluster.roles.storageClasses.binding = "shadowable"`).
      '';
    };
  };

  build =
    {
      self,
      config,
      clusterConfig,
      ...
    }:
    let
      who = "storage-classes ${scope.namespaceName}/${scope.instanceName}";
      sc = kix.storage.mkClasses {
        inherit scope clusterConfig who;
        optionPath = "config.classes";
        classes = config.classes;
      };
    in
    if config.classes == { } then
      throw "${who}: config.classes is empty. Declare at least one StorageClass, for example classes.local-path = { provisioner = \"rancher.io/local-path\"; volumeBindingMode = \"WaitForFirstConsumer\"; }."
    else
      {
        classes = sc.resources;
        root = {
          resource = self.classes.${builtins.head (builtins.attrNames config.classes)};
          requires = builtins.attrValues self.classes;
          out = {
            storageClasses = self.classes;
            inherit (sc) storageClassName;
          };
        };
      };
}

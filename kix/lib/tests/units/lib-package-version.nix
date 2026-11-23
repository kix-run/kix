# Tests for the version an instance reports. The PackageInstance record's
# `spec.version` and the `meta.compatibleWith` check of a consumer read the
# same value: the instance's `version`, else the `out.version` the package
# builds, else `meta.version`. Also tests `kix.image.version`, which reads
# a version from an image tag.
# Loaded by ../default.nix with the other files in this directory.

{
  lib,
  kixlib,
  eval,
  mkCluster,
  manifests,
  ofKind,
  ...
}:

let
  packageLib = import ../../core/package.nix { inherit lib; };

  # A ConfigMap package. `meta.version` and `out.version` are set only when
  # given, so the record sees the same shapes real packages produce.
  # `unreadableImage` publishes a null `out.version`, as a package does for
  # an image whose tag names no version.
  mkPackage =
    {
      metaVersion ? null,
      outVersion ? null,
      unreadableImage ? false,
      metaExtra ? { },
    }:
    {
      meta = {
        description = "version fixture";
        owner = "test";
      }
      // lib.optionalAttrs (metaVersion != null) { version = metaVersion; }
      // metaExtra;
      build =
        {
          self,
          scope,
          dep ? null,
          ...
        }:
        {
          cm = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "cm";
          };
          root = {
            resource = self.cm;
          }
          // lib.optionalAttrs (outVersion != null) { out.version = outVersion; }
          // lib.optionalAttrs unreadableImage { out.version = null; };
        };
    };

  # Build a consumer that accepts a dependency up to 1.5, and report whether
  # the cluster builds.
  consumerBuilds =
    dep:
    (builtins.tryEval (
      builtins.deepSeq (manifests (mkCluster [
        (
          { ref, ... }:
          {
            namespaces.x = { };
            namespaces.y = { };
            instances.y.dep = dep;
            instances.x.consumer = {
              package = mkPackage { metaExtra.compatibleWith.dep.maxVersion = "1.5"; };
              deps.dep = ref.y.dep;
            };
          }
        )
      ])) true
    )).success;

  recordOf =
    instance:
    builtins.head (
      ofKind "PackageInstance" (
        manifests (mkCluster [
          {
            namespaces.x = { };
            instances.x.app = instance;
          }
        ])
      )
    );

  specOf = instance: (recordOf instance).spec;
in
{
  lib-package-version-omitted-without-version =
    let
      spec = specOf { package = mkPackage { }; };
    in
    !(spec ? version) || throw "spec carries a version: ${builtins.toJSON spec}";

  lib-package-version-from-out =
    let
      spec = specOf { package = mkPackage { outVersion = "17"; }; };
    in
    (spec.version or null) == "17" || throw "spec: ${builtins.toJSON spec}";

  lib-package-version-out-over-meta =
    let
      spec = specOf {
        package = mkPackage {
          metaVersion = "1.2.3";
          outVersion = "1.1.0";
        };
      };
    in
    (spec.version or null) == "1.1.0" || throw "spec: ${builtins.toJSON spec}";

  lib-package-version-from-meta =
    let
      spec = specOf { package = mkPackage { metaVersion = "1.2.3"; }; };
    in
    (spec.version or null) == "1.2.3" || throw "spec: ${builtins.toJSON spec}";

  # A null `out.version` means the instance runs an unknown version, so the
  # record does not fall back to `meta.version`.
  lib-package-version-omitted-for-unreadable-image =
    let
      spec = specOf {
        package = mkPackage {
          metaVersion = "1.2.3";
          unreadableImage = true;
        };
      };
    in
    !(spec ? version) || throw "spec carries a version: ${builtins.toJSON spec}";

  # The consumer accepts up to 1.5. The check reads what the dependency
  # runs, in the same order as the record.
  lib-package-version-compatible-with-reads-instance-version =
    let
      package = mkPackage {
        metaVersion = "1.0.0";
        outVersion = "2.0.0";
      };
    in
    (
      consumerBuilds { package = mkPackage { metaVersion = "1.0.0"; }; }
      && !(consumerBuilds { inherit package; })
      && consumerBuilds {
        inherit package;
        version = "1.4.0";
      }
      && !(consumerBuilds {
        package = mkPackage { metaVersion = "1.0.0"; };
        version = "2.0.0";
      })
    )
    || throw "compatibleWith did not follow the instance's version";

  # An import's `version` overrides the `out.version` it states, as for a
  # package.
  lib-package-version-compatible-with-reads-import-version =
    let
      package = eval.mkImport { out.version = "1.0.0"; };
    in
    (
      consumerBuilds { inherit package; }
      && !(consumerBuilds {
        inherit package;
        version = "2.0.0";
      })
      && consumerBuilds {
        package = eval.mkImport { out.version = "2.0.0"; };
        version = "1.2.3";
      }
    )
    || throw "compatibleWith did not follow the import's version";

  # A warning about a dependency's version names the instance that checks
  # it, with its namespace, in the same form as every instance warning.
  lib-package-version-compatible-with-warning-names-instance =
    let
      cluster = mkCluster [
        (
          { ref, ... }:
          {
            namespaces.x = { };
            namespaces.y = { };
            instances.y.dep.package = mkPackage { };
            instances.x.consumer = {
              package = mkPackage { metaExtra.compatibleWith.dep.maxVersion = "1.5"; };
              deps.dep = ref.y.dep;
            };
          }
        )
      ];
      expected = {
        instance = "x/consumer";
        dependency = "dep";
        message = "cannot check meta.compatibleWith.dep: dependency 'dep' reports no version, so Kix skipped this version check.";
      };
      listed = builtins.fromJSON (builtins.readFile cluster.activationFiles.warnings);
    in
    builtins.elem expected listed || throw "warnings: ${builtins.toJSON listed}";

  lib-package-version-image-version =
    let
      of = tag: kixlib.image.version { inherit tag; };
      got = map of [
        "1.2.3"
        "v1.2.3"
        "v1.37.1-alpine"
        "v3.0.3-cuda@sha256:abc"
        "2.0.0-rc1"
        "26.3.33.24"
        "latest"
        "release"
        "config-reloader-1.2.3"
      ];
      want = [
        "1.2.3"
        "1.2.3"
        "1.37.1"
        "3.0.3"
        "2.0.0-rc1"
        "26.3.33.24"
        null
        null
        null
      ];
    in
    (got == want && kixlib.image.version { } == null)
    || throw "kix.image.version: ${builtins.toJSON got}";

  lib-package-version-instance-over-out =
    let
      spec = specOf {
        package = mkPackage { outVersion = "17"; };
        version = "pinned";
      };
    in
    (spec.version or null) == "pinned" || throw "spec: ${builtins.toJSON spec}";

  # Kix reads `meta.version` without a leading `v`, so a package can set it
  # to the upstream tag. The record, the catalog, and `compatibleWith` all
  # see the bare version.
  lib-package-version-meta-drops-leading-v =
    let
      package = mkPackage { metaVersion = "v1.2.3"; };
      spec = specOf { inherit package; };
      metaOf =
        package:
        packageLib.metaOf {
          inherit package;
          kix = kixlib;
        };
      peeked = metaOf package;
    in
    (
      (spec.version or null) == "1.2.3"
      && peeked.version == "1.2.3"
      &&
        (metaOf (mkPackage {
          metaVersion = "bundled";
        })).version == "bundled"
      && consumerBuilds { package = mkPackage { metaVersion = "v1.4.0"; }; }
      && !(consumerBuilds { package = mkPackage { metaVersion = "v1.6.0"; }; })
    )
    || throw "spec ${builtins.toJSON spec}, meta ${builtins.toJSON peeked}";

  # `kix.image.checkRelease` accepts a tag of the release's major.minor, or
  # of a minor in `also`, written with the release's leading `v` or without
  # it as the release is.
  lib-package-version-check-release =
    let
      check =
        release: tag: extra:
        kixlib.image.checkRelease (
          {
            image = { inherit tag; };
            inherit release;
            reason = "the CRDs are vendored from ${release}";
          }
          // extra
        );
      passes = release: tag: (check release tag { }).assertion;
      fails = release: tag: !(check release tag { }).assertion;
      minor = check "v1.10.0" "v1.11.0" { };
      prefix = check "v1.10.0" "1.10.2" { };
      noPrefix = check "0.15.1" "v0.15.1" { option = "webhook.image"; };
      older = check "v1.10.0" "v1.4.0" {
        also = [
          "1.8"
          "1.9"
        ];
        fix = "Run the script.";
      };
    in
    (
      passes "v1.10.0" "v1.10.0"
      && passes "v1.10.0" "v1.10.7"
      && passes "v1.10.0" "v1.10.1-alpine"
      && passes "0.15.1" "0.15.9"
      && fails "v1.10.0" "latest"
      && fails "v1.10.0" "v1"
      && (check "v1.10.0" "v1.9.2" { also = [ "1.9" ]; }).assertion
      && minor.option == "image.tag"
      &&
        minor.message
        == ''image.tag "v1.11.0" is not a v1.10 release, and the CRDs are vendored from v1.10.0.''
      && minor.fix == "Set image.tag to a tag such as v1.10.0, or remove it."
      &&
        prefix.message
        == ''image.tag "1.10.2" has no leading "v", and upstream tags this image like v1.10.0.''
      && noPrefix.option == "webhook.image.tag"
      &&
        noPrefix.message
        == ''webhook.image.tag "v0.15.1" starts with "v", and upstream tags this image like 0.15.1.''
      &&
        older.message
        == ''image.tag "v1.4.0" is not a v1.8, v1.9, or v1.10 release, and the CRDs are vendored from v1.10.0.''
      && older.fix == "Set image.tag to a tag such as v1.10.0, or remove it. Run the script."
    )
    || throw "kix.image.checkRelease: ${
      builtins.toJSON {
        inherit
          minor
          prefix
          noPrefix
          older
          ;
      }
    }";
}

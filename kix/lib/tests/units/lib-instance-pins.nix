# Tests for instance pins (vocab/pins.nix `instances`, eval/instance-pins.nix)
# and the image sources a cluster reports for `kix-image-sources.json`.
# Loaded by ../default.nix with the other files in this directory.

{
  lib,
  eval,
  kixlib,
  baseInstances,
  manifests,
  byName,
  ...
}:

let
  throws = v: !(builtins.tryEval (builtins.deepSeq v v)).success;

  digestA = "sha256:" + lib.concatStrings (lib.replicate 64 "a");
  digestB = "sha256:" + lib.concatStrings (lib.replicate 64 "b");

  # Two image options, one nested, rendered into a ConfigMap so a test can
  # read what each one resolved to.
  webPackage = {
    meta.version = "test";
    options.image = kixlib.options.image {
      repository = "reg.example/web";
      tag = "1.0";
      digest = digestA;
    };
    options.sidecar.image = kixlib.options.image {
      repository = "reg.example/sidecar";
      tag = "2.0";
    };
    options.replicas = lib.mkOption {
      type = lib.types.int;
      default = 1;
    };
    build =
      {
        self,
        scope,
        config,
        ...
      }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${scope.instanceName}-images";
          extra.data = {
            image = kixlib.image.ref config.image;
            sidecar = kixlib.image.ref config.sidecar.image;
          };
        };
        root = self.cm;
      };
  };

  # The same package, with its own `mkDefault` for the tag.
  webPackageWithDefault = webPackage // {
    config.image.tag = lib.mkDefault "1.5";
  };

  # A consumer that injects a tag into its `target` dependency.
  injectingConsumer = {
    meta.version = "test";
    deps.target.config.image.tag = "injected";
    build =
      {
        self,
        scope,
        target,
        ...
      }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "consumer";
          extra.data.dep = target.out.name;
        };
        root = self.cm;
      };
  };

  pinsFile = kixlib.pins ./instance-pins/pins.json;

  build =
    pins: instances:
    eval.buildCluster {
      name = "test";
      modules = [
        baseInstances
        { inherit instances; }
      ];
      inherit pins;
    };

  imagesOf = cluster: name: (byName "${name}-images" (manifests cluster)).data;

  sourcesOf = cluster: cluster.imageSources.images;

  sourceOf =
    cluster: inst: option:
    lib.findFirst (
      s: s.instance == inst && s.option == option
    ) (throw "no source for ${inst} ${option}") (sourcesOf cluster);

  # A Nix string context, as an image tag derived from a build carries one.
  # Evaluating `outPath` builds nothing.
  built = builtins.derivation {
    name = "image";
    system = "x86_64-linux";
    builder = "/bin/sh";
  };
in
{
  # A version 1 file, enveloped or bare, reads as before and has no
  # instance pins.
  lib-instance-pins-version-1-still-reads =
    let
      enveloped = kixlib.pins {
        version = 1;
        managedBy = "kix pin";
        images.web = {
          repository = "reg.example/web";
          tag = "v1";
        };
      };
      bare = kixlib.pins {
        web = {
          repository = "reg.example/web";
          tag = "v1";
        };
      };
    in
    (
      enveloped.ref "web" == "reg.example/web:v1"
      && bare.ref "web" == "reg.example/web:v1"
      && enveloped.instances == { }
      && bare.instances == { }
    )
    || throw "a version 1 pin file no longer reads";

  # A version this Kix does not read is refused, as a Kix that reads only
  # version 1 refuses version 2. Instance pins in a file that declares
  # version 1 are refused rather than ignored.
  lib-instance-pins-unknown-version-refused =
    throws
      (kixlib.pins {
        version = 3;
        images = { };
      }).keys
    &&
      throws
        (kixlib.pins {
          version = 1;
          images = { };
          instances."app/web".image = {
            repository = "r";
            tag = "1";
          };
        }).instances;

  lib-instance-pins-malformed-refused =
    let
      instancesOf =
        instances:
        builtins.deepSeq
          (kixlib.pins {
            version = 2;
            inherit instances;
          }).instances
          true;
    in
    throws (instancesOf {
      web.image.repository = "r";
    })
    && throws (instancesOf {
      "app/web"."image." = {
        repository = "r";
        tag = "1";
      };
    })
    && throws (instancesOf {
      "app/web".image.repository = "r";
    })
    && throws (instancesOf {
      "app/web" = { };
    });

  # An instance pin sets the option with no code reading it, nested option
  # paths included, and the package's default applies where nothing is
  # pinned.
  lib-instance-pins-applied =
    let
      cluster = build pinsFile {
        app.web.package = webPackage;
        app.other.package = webPackage;
      };
      web = imagesOf cluster "web";
      other = imagesOf cluster "other";
    in
    (
      web.image == "reg.example/web:1.1@${digestB}"
      && web.sidecar == "reg.example/sidecar:2.1"
      && other.image == "reg.example/web:1.0@${digestA}"
    )
    || throw "instance pins applied wrong: ${builtins.toJSON { inherit web other; }}";

  # A pin and a value in code on the same option is an error, whether the
  # values agree, differ, or the code forces its own.
  lib-instance-pins-pin-and-literal-refused =
    let
      withConfig =
        config:
        manifests (
          build pinsFile {
            app.web = {
              package = webPackage;
              inherit config;
            };
          }
        );
    in
    throws (withConfig {
      image.tag = "1.1";
    })
    && throws (withConfig {
      image.tag = "9.9";
    })
    && throws (withConfig {
      image = lib.mkForce {
        repository = "r";
        tag = "1";
      };
    })
    && throws (withConfig {
      sidecar.image.repository = "reg.example/other";
    })
    # Other options of the same instance are free.
    && !(throws (withConfig {
      replicas = 2;
    }));

  # A pin for an instance the cluster lacks, for an option the package
  # lacks, or for an option that is not an image, is an error.
  lib-instance-pins-unknown-target-refused =
    let
      pinsFor =
        instances:
        kixlib.pins {
          version = 2;
          inherit instances;
        };
      pin = {
        repository = "r";
        tag = "1";
      };
      clusterWith = instances: manifests (build (pinsFor instances) { app.web.package = webPackage; });
    in
    throws (clusterWith {
      "app/missing".image = pin;
    })
    && throws (clusterWith {
      "app/web".imag = pin;
    })
    && throws (clusterWith {
      "app/web".replicas = pin;
    })
    && !(throws (clusterWith {
      "app/web".image = pin;
    }));

  # Each origin, for one image option each.
  lib-instance-pins-sources-name-each-origin =
    let
      cluster = build pinsFile {
        app.web.package = webPackage;
        app.plain.package = webPackage;
        app.mkdefault.package = webPackageWithDefault;
        app.coded = {
          package = webPackage;
          config.image.tag = "9.9";
        };
        app.fromget = {
          package = webPackage;
          config.image = pinsFile.get "shared";
        };
        app.nixbuilt = {
          package = webPackage;
          config.image = {
            repository = "reg.example/built";
            tag = "nix-" + builtins.substring 11 8 built.outPath;
          };
        };
        app.target.package = webPackage;
        app.consumer.package = injectingConsumer;
      };
      s = sourceOf cluster;
      pinned = s "web" "image";
      coded = s "coded" "image";
      fromget = s "fromget" "image";
      checks = {
        pinned =
          pinned.origin == "pin"
          &&
            pinned.pin == {
              map = "instances";
              key = "app/web";
            }
          && lib.hasSuffix "instance-pins/pins.json" pinned.file
          && pinned.tag == "1.1"
          && pinned.digest == digestB
          &&
            pinned.default == {
              repository = "reg.example/web";
              tag = "1.0";
            };
        nested = (s "web" "sidecar.image").origin == "pin";
        packageDefault =
          (s "plain" "image").origin == "package_default"
          && (s "plain" "image").file == null
          && (s "plain" "sidecar.image").origin == "package_default";
        packageMkDefault =
          (s "mkdefault" "image").origin == "package_default" && (s "mkdefault" "image").tag == "1.5";
        code =
          coded.origin == "code"
          && lib.hasSuffix "units/lib-instance-pins.nix" coded.file
          && builtins.isInt coded.line
          && coded.tag == "9.9"
          && coded.repository == "reg.example/web";
        fromImagesMap =
          fromget.origin == "pin"
          &&
            fromget.pin == {
              map = "images";
              key = "shared";
            }
          && lib.hasSuffix "instance-pins/pins.json" fromget.file;
        nixBuilt =
          (s "nixbuilt" "image").origin == "nix_built" && !(builtins.hasContext (s "nixbuilt" "image").tag);
        injected =
          (s "target" "image").origin == "injected" && (s "target" "image").dependency == "app/consumer";
        envelope =
          cluster.imageSources.version == 1
          && cluster.imageSources.cluster == "test"
          && lib.hasSuffix "instance-pins/pins.json" cluster.imageSources.pinsFile;
        # It is written with builtins.toFile, which refuses a string context.
        serialises = builtins.isString (
          builtins.toFile "kix-image-sources.json" (builtins.toJSON cluster.imageSources)
        );
      };
    in
    builtins.all (x: x) (builtins.attrValues checks)
    || throw "image sources wrong: ${builtins.toJSON (lib.filterAttrs (_: ok: !ok) checks)} ${
      builtins.toJSON (map (x: removeAttrs x [ "default" ]) (sourcesOf cluster))
    }";

  # Moving a value from code to an instance pin changes the image sources
  # and nothing that is deployed, so the Activation keeps its name.
  lib-instance-pins-move-to-pin-keeps-the-activation =
    let
      value = {
        repository = "reg.example/web";
        tag = "1.1";
        digest = digestB;
      };
      inCode = build null {
        app.web = {
          package = webPackage;
          config.image = value;
        };
      };
      inPin =
        build
          (kixlib.pins {
            version = 2;
            instances."app/web".image = value;
          })
          {
            app.web.package = webPackage;
          };
      strip = builtins.unsafeDiscardStringContext;
    in
    (
      strip (builtins.toJSON (manifests inCode)) == strip (builtins.toJSON (manifests inPin))
      && inCode.activation.outPath == inPin.activation.outPath
      && (sourceOf inCode "web" "image").origin == "code"
      && (sourceOf inPin "web" "image").origin == "pin"
      && inCode.imageSources.pinsFile == null
    )
    || throw "moving a value to a pin changed what is deployed";
}

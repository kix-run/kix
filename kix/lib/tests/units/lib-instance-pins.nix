# Tests for instance pins (vocab/pins.nix `instances`, eval/instance-pins.nix)
# and the image sources a cluster reports for `kix-image-sources.json`.
# Loaded by ../default.nix with the other files in this directory.

{
  lib,
  k8s,
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

  # Two images from one release: `webhook.image.tag` follows `image.tag`
  # through the package's `config`, as cert-manager's webhook does.
  releasePackage = {
    meta.version = "test";
    options.image = kixlib.options.image {
      repository = "reg.example/controller";
      tag = "1.0";
      digest = digestA;
    };
    options.webhook.image = kixlib.options.image {
      repository = "reg.example/webhook";
      tag = "1.0";
      digest = digestB;
      tagText = "config.image.tag";
    };
    config =
      { config, ... }:
      {
        webhook.image.tag = lib.mkDefault config.image.tag;
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
            webhook = kixlib.image.ref config.webhook.image;
          };
        };
        root = self.cm;
      };
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

  # A version Kix does not read is refused, as a Kix that reads only
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
    && throws (withConfig {
      image.tag = lib.mkForce "9.9";
    })
    && throws (withConfig {
      image = {
        tag = lib.mkDefault "9.9";
        repository = "reg.example/other";
      };
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
          && coded.file == "kix/lib/tests/units/lib-instance-pins.nix"
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
          && fromget.file == "kix/lib/tests/units/instance-pins/pins.json";
        nixBuilt =
          (s "nixbuilt" "image").origin == "nix_built" && !(builtins.hasContext (s "nixbuilt" "image").tag);
        injected =
          (s "target" "image").origin == "injected" && (s "target" "image").dependency == "app/consumer";
        envelope =
          cluster.imageSources.version == 1
          && cluster.imageSources.cluster == "test"
          && cluster.imageSources.pinsFile == "kix/lib/tests/units/instance-pins/pins.json"
          && cluster.imageSources.pinsFileUnknown == null;
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

  # A value read with `pins.get` in a cluster that does not pass its pin
  # file to buildCluster is `code`, and its place is never Kix's own reader.
  lib-instance-pins-get-without-pins-names-no-kix-file =
    let
      src = sourceOf (build null {
        app.fromget = {
          package = webPackage;
          config.image = pinsFile.get "shared";
        };
      }) "fromget" "image";
    in
    (src.origin == "code" && (src.file == null || !(lib.hasSuffix "vocab/pins.nix" src.file)))
    || throw "pins.get value placed at ${builtins.toJSON src}";

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

  # A follower image can be pinned: the package's `mkDefault` for its tag is
  # one of the package's defaults, not a second definition. Pinning the main
  # image alone moves the follower's tag and drops its digest, which belongs
  # to the old tag, so a release is pinned image by image.
  lib-instance-pins-follower-image =
    let
      pin = repository: tag: digest: { inherit repository tag digest; };
      digestC = "sha256:" + lib.concatStrings (lib.replicate 64 "c");
      digestD = "sha256:" + lib.concatStrings (lib.replicate 64 "d");
      clusterWith =
        options:
        build (kixlib.pins {
          version = 2;
          instances."app/rel" = options;
        }) { app.rel.package = releasePackage; };
      both = imagesOf (clusterWith {
        image = pin "reg.example/controller" "1.1" digestC;
        "webhook.image" = pin "reg.example/webhook" "1.1" digestD;
      }) "rel";
      followerOnly = imagesOf (clusterWith {
        "webhook.image" = pin "reg.example/webhook" "1.2" digestD;
      }) "rel";
      mainOnly = clusterWith { image = pin "reg.example/controller" "1.1" digestC; };
      checks = {
        both =
          both == {
            image = "reg.example/controller:1.1@${digestC}";
            webhook = "reg.example/webhook:1.1@${digestD}";
          };
        followerOnly =
          followerOnly == {
            image = "reg.example/controller:1.0@${digestA}";
            webhook = "reg.example/webhook:1.2@${digestD}";
          };
        mainOnly = (imagesOf mainOnly "rel").webhook == "reg.example/webhook:1.1";
        followerOrigin = (sourceOf mainOnly "rel" "webhook.image").origin == "package_default";
      };
    in
    builtins.all (x: x) (builtins.attrValues checks)
    || throw "follower pins wrong: ${builtins.toJSON { inherit checks both followerOnly; }}";

  # A package that forces a field of its image cannot be pinned: the
  # instance would run the package's tag with the pin's digest.
  lib-instance-pins-package-mkforce-refused = throws (
    manifests (
      build pinsFile {
        app.web.package = webPackage // {
          config.image.tag = lib.mkForce "1.0";
        };
      }
    )
  );

  # A `lib.mkDefault` in the cluster's code is below the pin, so the pin
  # wins and evaluation does not fail.
  lib-instance-pins-win-over-mkdefault-in-code =
    let
      web = imagesOf (build pinsFile {
        app.web = {
          package = webPackage;
          config.image.tag = lib.mkDefault "9.9";
        };
      }) "web";
    in
    web.image == "reg.example/web:1.1@${digestB}" || throw "mkDefault beat the pin: ${web.image}";

  # A pin states its digest. One without a digest, under another
  # repository at the package's tag, does not inherit the package's digest.
  lib-instance-pins-digestless-pin-keeps-no-package-digest =
    let
      web = imagesOf (build (kixlib.pins {
        version = 2;
        instances."app/web".image = {
          repository = "mirror.example/web";
          tag = "1.0";
        };
      }) { app.web.package = webPackage; }) "web";
    in
    web.image == "mirror.example/web:1.0"
    || throw "a digest-less pin kept the package digest: ${web.image}";

  # Both readers check the image reference grammar and the envelope's
  # fields; the Rust tests in cli/kix/src/pins/mod.rs cover the same cases.
  lib-instance-pins-reference-grammar =
    let
      refused =
        pin:
        throws
          (kixlib.pins {
            version = 2;
            instances."app/web".image = pin;
          }).instances;
    in
    refused {
      repository = "reg.example/web";
      tag = "1.1@${digestB}";
    }
    && refused {
      repository = "Reg/Web";
      tag = "1";
    }
    && refused {
      repository = "reg.example//web";
      tag = "1";
    }
    && refused {
      repository = "reg.example/web";
      tag = "-1";
    }
    && !(refused {
      repository = "localhost:5000/team/web-server";
      tag = "v1.2_3";
    })
    &&
      throws
        (kixlib.pins {
          version = 2;
          images = { };
          holds = { };
        }).keys;

  # A pin file outside the flake `self` (another flake input) has no path in
  # the image sources, and says why; so does a cluster whose caller did not
  # name its flake. Nothing names a path in a repository that does not hold
  # the file.
  lib-instance-pins-pin-file-outside-the-flake-has-no-path =
    let
      clusterIn =
        self:
        (import ../../eval { inherit lib k8s self; }).buildCluster {
          name = "test";
          modules = [
            baseInstances
            {
              instances.app.web = {
                package = webPackage;
              };
            }
          ];
          pins = pinsFile;
        };
      # Another directory stands in for the flake: the pin file is not in it.
      elsewhere = clusterIn ../../core;
      unnamed = clusterIn null;
      web = cluster: sourceOf cluster "web" "image";
    in
    (
      elsewhere.imageSources.pinsFile == null
      && elsewhere.imageSources.pinsFileUnknown == "outside_flake"
      && (web elsewhere).origin == "pin"
      && (web elsewhere).file == null
      && unnamed.imageSources.pinsFile == null
      && unnamed.imageSources.pinsFileUnknown == "flake_unknown"
      && (web unnamed).file == null
    )
    || throw "a pin file outside the flake was named: ${
      builtins.toJSON {
        elsewhere = removeAttrs elsewhere.imageSources [ "images" ];
        unnamed = removeAttrs unnamed.imageSources [ "images" ];
      }
    }";
}

# Tests for a plain value in `deps.<name>`, which binds a dependency to the
# value as it is: a required dependency accepts one, and the package's
# `assertions` receive it in `deps` (`meta.nix`), as `build` does.
{
  lib,
  k8s,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  ...
}:

let
  helpers = import ../caught.nix { inherit lib; };
  evalCaught = helpers.loadCaught ../../eval {
    inherit lib k8s;
    self = ../../../..;
  };
  failedOf =
    modules:
    (evalCaught.buildCluster {
      name = "test";
      inherit modules;
    }).diagnostics.failedAssertions;

  # Writes its required `greeting` dependency into a ConfigMap, and asserts
  # that the value is not "bad".
  greeter = {
    meta.version = "test";
    assertions =
      { deps, ... }:
      [
        {
          assertion = (deps.greeting or null) != "bad";
          message = "greeting is bad";
        }
      ];
    build =
      {
        self,
        scope,
        greeting,
        ...
      }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "greeting";
          data.text = greeting;
        };
        root = self.cm;
      };
  };

  withGreeting = deps: [
    {
      instances.app.greeter = {
        package = greeter;
        inherit deps;
      };
    }
  ];
in
{
  # A required dependency given a plain value builds and reads it. Without
  # the value it fails, because no instance answers the name.
  lib-plain-deps-required-dependency-takes-a-value =
    let
      text =
        (byName "greeting" (
          ofKind "ConfigMap" (
            manifests (
              mkCluster (withGreeting {
                greeting = "hello";
              })
            )
          )
        )).data.text;
    in
    (text == "hello" && evalFails (mkCluster (withGreeting { })))
    || throw "plain required dependency: ${builtins.toJSON text}";

  # `assertions` receive a plain value in `deps`, so a package can check it.
  lib-plain-deps-assertions-see-the-value =
    let
      bad = failedOf (withGreeting {
        greeting = "bad";
      });
      good = failedOf (withGreeting {
        greeting = "hello";
      });
    in
    (builtins.any (a: a.message == "greeting is bad") bad && good == [ ])
    || throw "assertions on a plain value: bad ${builtins.toJSON bad}, good ${builtins.toJSON good}";
}

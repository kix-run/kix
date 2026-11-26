# clusters/test-pins.nix: a deployable cluster whose image reference comes
# from a committed pin file rather than from a literal in this file.
#
# This is the worked example for `discussions/archive/138`. Three things are shown
# here that are hard to see from the code alone:
#
#   1. The reference is resolved. `pins.get "web"` returns a repository, a tag
#      and a digest, and `kix.image.ref` renders all three, so what the
#      cluster pulls is fixed even if somebody moves the tag afterwards.
#   2. The value is committed. `clusters/pins.json` is in the repository, so
#      a clean checkout of this file deploys something real. There is no step
#      where CI edits a working tree and does not commit it.
#   3. Promotion is a command anybody can run. `kix pin set` writes the pin
#      from a laptop or from CI, identically, with no cluster evaluation.
#
# A second instance, `web-next`, shows the other kind of pin. Nothing in this
# file reads it: `clusters/pins.json` pins `kix-pins/web-next`'s `image`
# option under `instances`, and `kix.buildCluster` applies it because the
# file is passed as `pins`. Removing that entry returns the instance to its
# package's default; no Nix changes either way.
#
# Promote:  kix pin set web --tag 1.27-alpine --pins-file clusters/pins.json
#           kix pin set kix-pins/web-next --tag 1.29-alpine --pins-file clusters/pins.json
# Verify:   kix pin check --pins-file clusters/pins.json
# Build:    kix build pins
# Deploy:   kix deploy pins --context kind-kix-pins -y
#
# `pins` is the committed record of what each image reference resolved to,
# already loaded. The path to it is declared once, in the repository's
# `flake.nix`, so this file never names it. A missing key throws here, at
# evaluation, naming the command that adds it.
{
  kix,
  packages,
  pins,
}:

let
  # The same file read the other way. `pins` comes from the flake and is the
  # spelling to prefer; `kix.pins` is what a cluster with a pin file of its
  # own uses. Asserting they agree keeps the documented escape hatch working,
  # because nothing else in this repository exercises it.
  direct = kix.pins ./pins.json;

  webPackage = {
    meta.version = "test";

    # The digest slot is declared once, the same way in every package,
    # so `kix pin` always has somewhere to put a resolution.
    # region:pinnedImageOption
    options.image = kix.kixlib.options.image {
      repository = "docker.io/nginxinc/nginx-unprivileged";
      tag = "1.27-alpine";
    };
    # endregion:pinnedImageOption

    build = [
      (
        {
          self,
          config,
          scope,
          kix,
          ...
        }:
        {
          root = self.svc;

          deployment = scope.mkDeployment {
            name = scope.instanceName;
            spec = {
              selector.matchLabels = scope.selectorLabels;
              template.spec.containers = [
                {
                  name = scope.instanceName;
                  # repository:tag@digest. The tag is what a person
                  # reads; the digest is what the runtime pulls.
                  # region:renderPinnedImage
                  image = kix.image.ref config.image;
                  imagePullPolicy = config.image.pullPolicy;
                  # endregion:renderPinnedImage
                  ports = [ (kix.port "http" 8080) ];
                  resources = {
                    requests = {
                      cpu = "10m";
                      memory = "16Mi";
                    };
                    limits.memory = "64Mi";
                  };
                  securityContext = {
                    runAsNonRoot = true;
                    runAsUser = 101;
                    allowPrivilegeEscalation = false;
                    capabilities.drop = [ "ALL" ];
                  };
                }
              ];
            };
          };

          svc =
            self.deployment |> kix.service.fromWorkload { name = scope.instanceName; } |> scope.mkResource;
        }
      )
    ];
  };
in
assert direct.get "web" == pins.get "web";

kix.buildCluster {
  name = "pins";
  # Applies the file's instance pins. Its image pins are read below.
  # region:applyInstancePins
  inherit pins;
  # endregion:applyInstancePins
  modules = [
    {
      # The placeholder ratchet, at error severity. `sha-REPLACE_ME` and its
      # relatives cannot reach a manifest in this cluster: they pass every
      # other check, because they are valid tag strings, and this is the only
      # rule that looks at them.
      # Warning is the rule's shipped severity, so a repository can adopt
      # it without a flag day. A cluster that deploys something you care
      # about promotes it, which is the same move a lab1-style flavor makes
      # with noLatestTag.
      scorecard.ruleOverrides.byNamespace."*"."security.noUnresolvedPlaceholder".severity = "error";

      namespaces.kix-pins = { };

      instances.kix-pins.web = {
        package = webPackage;

        # The whole point: the reference is read, not written.
        # region:consumePin
        config.image = pins.get "web";
        # endregion:consumePin
      };

      # No config: the instance pin in pins.json sets `image`.
      instances.kix-pins.web-next.package = webPackage;
    }
  ];
}

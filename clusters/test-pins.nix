# clusters/test-pins.nix: a deployable cluster whose image reference comes
# from a committed pin file rather than from a literal in this file.
#
# This is the worked example for `v2_discussions/138`. Three things are shown
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
# Promote:  kix --flake ./clusters pin set web --tag 1.27-alpine
# Verify:   kix --flake ./clusters pin check
# Build:    nix build ./clusters#cluster-pins --extra-experimental-features pipe-operators
# Deploy:   kix --flake ./clusters --context kind-kix-pins deploy pins -y
#
# `pins` is the committed record of what each image reference resolved to,
# already loaded. The path to it is declared once, in `clusters/flake.nix`,
# so this file never names it and neither does the command line. A missing
# key throws here, at evaluation, naming the command that adds it.
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
in
assert direct.get "web" == pins.get "web";

kix.buildCluster {
  name = "pins";
  modules = [
    {
      # The placeholder ratchet, at error severity. `sha-REPLACE_ME` and its
      # relatives cannot reach a manifest in this cluster: they pass every
      # other check, because they are valid tag strings, and this is the only
      # rule that looks at them.
      scorecard = {
        enable = true;
        rules.security.noUnresolvedPlaceholder = kix.rules.security.noUnresolvedPlaceholder // {
          # Warning is the shipped default, so a repository can adopt the rule
          # without a flag day. A cluster that deploys something you care
          # about promotes it, which is the same move a lab1-style flavor makes
          # with noLatestTag.
          severity = "error";
        };
      };

      namespaces.kix-pins = { };

      instances.kix-pins.web = {
        package = {
          meta.version = "test";

          # The digest slot is declared once, the same way in every package,
          # so `kix pin` always has somewhere to put a resolution.
          options.image = kix.kixlib.options.image {
            repository = "docker.io/nginxinc/nginx-unprivileged";
            tag = "1.27-alpine";
          };

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
                  name = "web";
                  spec = {
                    selector.matchLabels = scope.selectorLabels;
                    template.spec.containers = [
                      {
                        name = "web";
                        # repository:tag@digest. The tag is what a person
                        # reads; the digest is what the runtime pulls.
                        image = kix.image.ref config.image;
                        imagePullPolicy = config.image.pullPolicy;
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

                svc = self.deployment |> kix.service.fromWorkload { name = "web"; } |> scope.mkResource;
              }
            )
          ];
        };

        # The whole point: the reference is read, not written.
        config.image = pins.get "web";
      };
    }
  ];
}

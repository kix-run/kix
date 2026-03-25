Current state

  Images are opaque strings. kix has zero visibility into what's inside them:

  image = {
    repository = "ghcr.io/immich-app/immich-server";
    tag = "v2.0.0";
  };
  # becomes → "ghcr.io/immich-app/immich-server:v2.0.0"

  No supply chain guarantees, no hash pinning, no rebuild-from-source.

  What Nix can do today

  nixpkgs ships dockerTools.buildLayeredImage / dockerTools.streamLayeredImage which produce OCI images as Nix
   derivations. The image is a store path — content-addressed, reproducible, cacheable.

  # Hypothetical: a kix package that builds its own image
  myImage = pkgs.dockerTools.buildLayeredImage {
    name = "my-app";
    contents = [ pkgs.coreutils myAppDerivation ];
    config.Cmd = [ "${myAppDerivation}/bin/my-app" ];
  };
  # → /nix/store/abc123...-my-app.tar.gz

  Three tiers of integration

  Tier 1: Nix-built images, pushed to registry (easiest)

  The image option accepts a derivation instead of a string. kix deploy gains an image-push phase:

  # Package definition
  options.image = lib.mkOption {
    type = lib.types.either kix.types.imageRef kix.types.nixImage;
  };

  # Usage — from nixpkgs or custom
  image = pkgs.dockerTools.buildLayeredImage { ... };
  # OR still works:
  image = { repository = "ghcr.io/..."; tag = "v2.0.0"; };

  kix deploy would:
  1. nix build the image derivation
  2. skopeo copy or crane push to a configured registry
  3. Rewrite the manifest image ref to registry.example.com/my-app@sha256:...

  What this buys you: reproducible builds, content-addressed images (the Nix hash is the version), supply
  chain from source to manifest. But still requires a registry and traditional image pull.

  Tier 2: nix-snapshotter (skip the registry entirely)

  nix-snapshotter is a containerd snapshotter that resolves image references directly from the Nix store. No
  registry, no Docker daemon, no image layers.

  # Image ref becomes a nix store path
  image = "nix:0${myImage}";
  # containerd pulls directly from /nix/store/...

  The cluster nodes need the Nix store (or a binary cache). This is natural for NixOS nodes, harder for
  managed k8s.

  What this buys you: no registry infrastructure, deduplication at the Nix store layer (shared packages across
   images are stored once), instant "pulls" on the same node.

  Tier 3: Full vertical (the end-state vision)

  The package is the image is the deployment:

  # A kix package that goes from source to running pod
  {
    build = { self, config, ... }: {
      # The binary — a normal Nix derivation
      binary = pkgs.buildGoModule { src = ./.; ... };

      # The image — derived from the binary
      image = kix.mkImage {
        app = self.binary;
        port = 8080;
      };

      # The deployment — derived from the image
      deployment = self.image
        |> kix.asDeployment { name = "my-app"; }
        |> scope.mkDeployment;

      service = self.deployment
        |> kix.service.fromWorkload { name = "my-app"; }
        |> scope.mkResource;

      main = self.service;
    };
  }

  The entire pipeline from Go source → binary → container image → deployment manifest → dependency graph is
  one Nix expression. Change a line of Go, and Nix rebuilds only what changed. The content hash on the
  deployment changes, kix-diff shows it, kix deploy rolls it out.

  What kix would need

  1. Image type system — kix.types.image that accepts either a string ref or a Nix derivation, and normalizes
  to an image reference for the manifest:

  # In lib, something like:
  resolveImage = img:
    if builtins.isString img then img          # "ghcr.io/..."
    else if img ? imageName then               # dockerTools output
      "${registry}/${img.imageName}@${hashOf img}"
    else throw "not a valid image";

  2. Image build/push phase in kix deploy — Today deploy only applies manifests. It would need a pre-phase
  that builds and pushes any Nix-built images. The dependency graph already gives you the order.

  3. Registry configuration — Cluster-level config for where to push:

  # In cluster definition
  cluster.imageRegistry = {
    url = "registry.internal:5000";
    # or: useNixSnapshotter = true;
  };

  4. kix.mkImage helper — A thin wrapper around dockerTools.buildLayeredImage with kix conventions (labels,
  health check defaults, non-root by default):

  kix.mkImage {
    app = derivation;        # the binary/runtime
    port = 8080;             # auto-wired to container port
    extraPackages = [ ];     # additional store paths
    user = "nobody";         # non-root default (security!)
  };

  5. Content-hash coherence — The image's Nix store hash would naturally feed into kix's content-hash
  annotations. Change the source → new image hash → new deployment hash → kix-diff detects it → kix deploy
  rolls it out. This is the "canary rollouts" item on the roadmap for free.

  What it means for immich specifically

  Immich is a third-party app — you won't build it from source. So it stays at Tier 1: pin the upstream image
  by digest, optionally wrap it through Nix for hash verification:

  image = pkgs.dockerTools.pullImage {
    imageName = "ghcr.io/immich-app/immich-server";
    imageDigest = "sha256:abc123...";
    sha256 = "..."; # Nix hash of the pulled image
  };

  This gives you supply-chain pinning (the image is in your Nix store, content-addressed) without needing to
  rebuild from source.

  For your own services or simpler tools (CoreDNS from nixpkgs, custom operators), Tier 3 is the compelling
  story.

  Practical starting point

  I'd start with:
  1. kix.types.image — polymorphic image option (string or derivation)
  2. kix.mkImage — convenience wrapper around dockerTools.buildLayeredImage
  3. Registry config on the cluster definition
  4. One proof-of-concept package that builds from nixpkgs (CoreDNS is a natural candidate since "Full CoreDNS
   binary building" is already on the roadmap)

  nix-snapshotter is the exciting long-term play but requires NixOS nodes. Registry push works everywhere and
  gets you 80% of the value.

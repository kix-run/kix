# The Immich release that `immich` and `immich-machine-learning` default to.
# Upstream publishes immich-server and immich-machine-learning under one tag,
# and the server calls machine-learning endpoints of its own release, so a
# bump changes `version` and both digests together.
let
  version = "3.4.1";
in
{
  inherit version;
  tag = "v${version}";

  # Multi-arch index digests of `tag` (`crane digest <repository>:<tag>`).
  digests = {
    server = "sha256:7c489add298fc2f92cda4c777de6462aa206877e04087b815f62c7664af0b53b";
    machineLearning = "sha256:8adebf414256f6e4f837bfbb66fa94f14f4da7260e3a1d65cbba49e4e35d8764";
  };
}

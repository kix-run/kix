# The Immich release that `immich` and `immich-machine-learning` default to.
# Upstream publishes immich-server and immich-machine-learning under one tag,
# and the server calls machine-learning endpoints of its own release, so a
# bump changes `version` and both digests together.
let
  version = "3.3.5";
in
{
  inherit version;
  tag = "v${version}";

  # Multi-arch index digests of `tag` (`crane digest <repository>:<tag>`).
  digests = {
    server = "sha256:485d546a2e31d6a8b4db8423fcba5c109de8c218d93410af115fd1ccfc4352a6";
    machineLearning = "sha256:5b28c9352c8374b8a1ed96fbdd8d6755fea6e43510ec43fdf6538aa02ea40f56";
  };
}

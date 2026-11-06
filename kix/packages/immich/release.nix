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

  # The release an image tag names: "3.0.3" for `v3.0.3`, for the hardware
  # variants `v3.0.3-cuda`, `-openvino`, `-rocm`, `-armnn`, `-rknn`, and for
  # `v3.0.3@sha256:...`. Null for a tag that names no release, such as
  # `release`.
  of =
    tag:
    let
      m = builtins.match "v?([0-9]+\\.[0-9]+\\.[0-9]+)([-@].*)?" tag;
    in
    if m == null then null else builtins.head m;
}

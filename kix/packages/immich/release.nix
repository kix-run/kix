# The Immich release that `immich` and `immich-machine-learning` default to.
# Upstream publishes immich-server and immich-machine-learning under one tag,
# and the server calls machine-learning endpoints of its own release, so a
# bump changes `version` and both digests together.
let
  version = "3.0.3";
in
{
  inherit version;
  tag = "v${version}";

  # Multi-arch index digests of `tag` (`crane digest <repository>:<tag>`).
  digests = {
    server = "sha256:c716dc20f957aafd89fa9d284a2ec63e25c9e2d8d8e87c6197d540a3dce237db";
    machineLearning = "sha256:d76fe88b69282c09a97eac4f82dafa82cfd77bce274bc742591cde974f87dacb";
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

# The Immich release both `immich` and `immich-machine-learning` default
# to. Upstream tags immich-server and immich-machine-learning together, and
# the server calls machine-learning endpoints of its own release (a v3
# server's OCR job fails against a v2 worker), so bump both by changing
# `version`.
{
  version = "v3.0.3";

  # The release an image tag names: "v3.0.3" for `v3.0.3`, the hardware
  # variants `v3.0.3-cuda`, `-openvino`, `-rocm`, `-armnn`, `-rknn`, and
  # digest pins such as `v3.0.3@sha256:...`. Null for a tag that names no
  # release, such as `release` or a bare digest.
  of =
    tag:
    let
      m = builtins.match "v?([0-9]+\\.[0-9]+\\.[0-9]+)([-@].*)?" tag;
    in
    if m == null then null else "v${builtins.head m}";
}

# The `spec.image` field of a VictoriaMetrics operator CR, built from a
# `kix.options.image` value. The field takes repository, tag and pullPolicy.
# Operator v0.74.1 renders the container image as `repository:tag`, or as
# `repository@tag` when the tag is a bare `sha256:` digest (Image.Reference in
# api/operator/v1beta1/vmextra_types.go).
{ lib, kix }:
let
  # A pinned digest rides on the tag as `tag@sha256:...`, which the operator
  # renders as `repository:tag@sha256:...`.
  crImage =
    image:
    {
      inherit (image) repository;
      tag = lib.removePrefix "${image.repository}:" (kix.image.ref image);
    }
    // lib.optionalAttrs (image.pullPolicy != null) { inherit (image) pullPolicy; };
in
{
  inherit crImage;

  # For a CR whose tag the operator also parses as a semantic version. For
  # VMAlertmanager it decides `--enable-feature=utf8-strict-mode` from the tag
  # (addFeatureFlags in internal/controller/operator/factory/vmalertmanager/
  # statefulset.go) and skips the flag when the parse fails, so neither
  # `tag@digest` nor a bare digest can carry the pin. `option` names the
  # instance option for the error.
  crImageVersionTag =
    option: image:
    if kix.image.isPinned image then
      throw "${option}: digest ${image.digest} cannot be applied. The VictoriaMetrics operator parses this CR's spec.image.tag as a semantic version to choose Alertmanager feature flags, and a tag carrying a digest fails that parse and silently drops --enable-feature=utf8-strict-mode. Set ${option}.digest = null."
    else
      crImage image;
}

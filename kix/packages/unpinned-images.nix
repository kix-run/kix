# Package image options whose default may not carry a digest, for the
# image-digests test (kix/lib/tests/units/image-digests.nix). Each entry is
# `"<package>.<option path>" = "<why>"`. Add an entry only when the image
# cannot run with a digest, and say what breaks.
{
  "victoria-metrics-alert.alertmanager.image" =
    "VMAlertmanager has no separate digest field, and the VictoriaMetrics operator reads `spec.image.tag` as a version number to set Alertmanager flags. Putting a digest in `spec.image.tag` breaks that check and drops `--enable-feature=utf8-strict-mode` (victoria-metrics-operator/cr-image.nix).";
}

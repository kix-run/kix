# Package image options whose default may not carry a digest, for the
# image-digests test (kix/lib/tests/units/image-digests.nix). Each entry is
# `"<package>.<option path>" = "<why>"`. Add an entry only when the image
# cannot run with a digest, and say what breaks.
{
  "victoria-metrics-alert.alertmanager.image" =
    "The VictoriaMetrics operator parses the VMAlertmanager tag as a semantic version to choose Alertmanager feature flags, and a tag with a digest fails that parse (victoria-metrics-operator/cr-image.nix).";
}

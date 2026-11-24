# Return the `cloud-identity` instance for a platform that gives pods a cloud
# identity through `mechanism`, such as `kix.cloudIdentity.irsa { }`.
#
# The import claims the `cloudIdentity` role, so a cloud identity that an
# instance gives its package as a dependency renders through `mechanism`. It also declares the
# annotation domains the platform's webhook reads, so the scorecard accepts
# them on any instance. They default to the mechanism's, and a platform whose
# webhook reads a domain the chosen mechanism does not write names it. A
# package that runs the webhook in the cluster claims the same role and
# domains and takes precedence.

{ kix }:
{
  mechanism,
  annotationDomains ? mechanism.annotationDomains,
}:
{
  package = kix.mkImport {
    roles = [ "cloudIdentity" ];
    inherit annotationDomains;
    out.cloudIdentity = mechanism;
  };
}

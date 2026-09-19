# cert-manager CRD definitions.

{
  self,
  config,
  clusterConfig,
  scope,
  lib,
}:
let
  common = import ./common.nix { instanceName = scope.instanceName; };

  mkCRD =
    categories: attrs:
    scope.mkCRD (
      attrs |> scope.crd.withLabels common.controllerLabels |> scope.crd.withCategories categories
    );

  mkCertManagerCRD = mkCRD [ "cert-manager" ];
  mkAcmeCRD = mkCRD [
    "cert-manager"
    "cert-manager-acme"
  ];
in
{
  crds = {
    certificates = mkCertManagerCRD (
      scope.crd.fromKind "Certificate" { spec.group = "cert-manager.io"; }
      |> scope.crd.withShortNames [
        "cert"
        "certs"
      ]
      |> scope.crd.withPrinterColumns [
        {
          jsonPath = ".status.conditions[?(@.type==\"Ready\")].status";
          name = "Ready";
          type = "string";
        }
        {
          jsonPath = ".spec.secretName";
          name = "Secret";
          type = "string";
        }
        {
          jsonPath = ".spec.issuerRef.name";
          name = "Issuer";
          type = "string";
        }
        {
          jsonPath = ".status.conditions[?(@.type==\"Ready\")].message";
          name = "Status";
          priority = 1;
          type = "string";
        }
        {
          jsonPath = ".metadata.creationTimestamp";
          name = "Age";
          type = "date";
        }
      ]
      |> scope.crd.withSchema (builtins.elemAt (builtins.fromJSON (builtins.readFile ./crds/certificates.cert-manager.io.json)).spec.versions 0)
      .schema.openAPIV3Schema.properties.spec
    );

    certificateRequests = mkCertManagerCRD (
      scope.crd.fromKind "CertificateRequest" { spec.group = "cert-manager.io"; }
      |> scope.crd.withShortNames [
        "cr"
        "crs"
      ]
      |> scope.crd.withPrinterColumns [
        {
          jsonPath = ".status.conditions[?(@.type==\"Approved\")].status";
          name = "Approved";
          type = "string";
        }
        {
          jsonPath = ".status.conditions[?(@.type==\"Denied\")].status";
          name = "Denied";
          type = "string";
        }
        {
          jsonPath = ".status.conditions[?(@.type==\"Ready\")].status";
          name = "Ready";
          type = "string";
        }
        {
          jsonPath = ".spec.issuerRef.name";
          name = "Issuer";
          type = "string";
        }
        {
          jsonPath = ".spec.username";
          name = "Requester";
          type = "string";
        }
        {
          jsonPath = ".status.conditions[?(@.type==\"Ready\")].message";
          name = "Status";
          priority = 1;
          type = "string";
        }
        {
          jsonPath = ".metadata.creationTimestamp";
          name = "Age";
          type = "date";
        }
      ]
    );

    challenges = mkAcmeCRD (
      scope.crd.fromKind "Challenge" { spec.group = "acme.cert-manager.io"; }
      |> scope.crd.withPrinterColumns [
        {
          jsonPath = ".status.state";
          name = "State";
          type = "string";
        }
        {
          jsonPath = ".spec.dnsName";
          name = "Domain";
          type = "string";
        }
        {
          jsonPath = ".status.reason";
          name = "Reason";
          priority = 1;
          type = "string";
        }
        {
          jsonPath = ".metadata.creationTimestamp";
          name = "Age";
          type = "date";
        }
      ]
    );

    clusterIssuers = mkCertManagerCRD (
      scope.crd.fromKind "ClusterIssuer" { spec.group = "cert-manager.io"; }
      |> scope.crd.clusterScoped
      |> scope.crd.withPrinterColumns [
        {
          jsonPath = ".status.conditions[?(@.type==\"Ready\")].status";
          name = "Ready";
          type = "string";
        }
        {
          jsonPath = ".status.conditions[?(@.type==\"Ready\")].message";
          name = "Status";
          priority = 1;
          type = "string";
        }
        {
          jsonPath = ".metadata.creationTimestamp";
          name = "Age";
          type = "date";
        }
      ]
    );

    issuers = mkCertManagerCRD (
      scope.crd.fromKind "Issuer" { spec.group = "cert-manager.io"; }
      |> scope.crd.withPrinterColumns [
        {
          jsonPath = ".status.conditions[?(@.type==\"Ready\")].status";
          name = "Ready";
          type = "string";
        }
        {
          jsonPath = ".status.conditions[?(@.type==\"Ready\")].message";
          name = "Status";
          priority = 1;
          type = "string";
        }
        {
          jsonPath = ".metadata.creationTimestamp";
          name = "Age";
          type = "date";
        }
      ]
    );

    orders = mkAcmeCRD (
      scope.crd.fromKind "Order" { spec.group = "acme.cert-manager.io"; }
      |> scope.crd.withPrinterColumns [
        {
          jsonPath = ".status.state";
          name = "State";
          type = "string";
        }
        {
          jsonPath = ".spec.issuerRef.name";
          name = "Issuer";
          type = "string";
        }
        {
          jsonPath = ".status.reason";
          name = "Reason";
          priority = 1;
          type = "string";
        }
        {
          jsonPath = ".metadata.creationTimestamp";
          name = "Age";
          type = "date";
        }
      ]
    );
  };
}

# Define the OTLP endpoint contract for packages that answer the `otlp` alias
# and receive OpenTelemetry traces, metrics, or logs (`kix.contracts.otlpEndpoint`).
#
# Provider packages call `check`, which requires every field. Consumers
# validate their `otlp` dependency with `assertions`, which requires only the
# `required` fields so a `kix.mkImport` stand-in only needs to publish the two
# base URLs.
{ lib }:
let
  inherit (import ./contract.nix { inherit lib; }) mkContract;

  # Return true when `v` is an `http://` or `https://` base URL without a path,
  # since gRPC exporters reject paths and HTTP exporters append `/v1/<signal>`.
  isBaseUrl = v: builtins.isString v && builtins.match "https?://[^/]+" v != null;

  fields = {
    otlpGrpcUrl = {
      required = true;
      shape = "the OTLP/gRPC base URL, scheme://host:port with no path (port 4317 by convention)";
      test = isBaseUrl;
    };
    # HTTP exporters append the signal path (such as `/v1/traces`) to this base.
    otlpHttpUrl = {
      required = true;
      shape = "the OTLP/HTTP base URL, scheme://host:port with no path (port 4318 by convention)";
      test = isBaseUrl;
    };
    tls = {
      required = false;
      shape = "true or false for whether the receivers serve TLS, or null when the provider cannot tell";
      test = v: v == null || builtins.isBool v;
    };
  };

  contract = mkContract {
    name = "OTLP endpoint";
    alias = "otlp";
    remedyNoun = "endpoint";
    here = "kix/lib/vocab/otlp-endpoint.nix";
    inherit fields;
  };
in
{
  inherit (contract)
    alias
    fields
    problems
    check
    assertions
    ;
}

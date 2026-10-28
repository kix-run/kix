# Define the OTLP endpoint contract for packages that answer the `otlp` alias
# and receive OpenTelemetry traces, metrics, or logs (`kix.contracts.otlpEndpoint`).
#
# Provider packages call `check`, which requires every field. Consumers
# validate their `otlp` dependency with `assertions`, which requires only the
# `required` fields so a `kix.mkImport` stand-in only needs to publish the two
# base URLs.
{ lib }:
let
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

  # Return a list of validation errors for `out`. When `all` is true, require
  # optional fields as well.
  problemsWith =
    all: out:
    builtins.concatMap (
      field:
      let
        f = fields.${field};
      in
      if !(out ? ${field}) then
        lib.optional (all || f.required) "${field} is missing (${f.shape})"
      else if !(f.test out.${field}) then
        [ "${field} is not ${f.shape}" ]
      else
        [ ]
    ) (builtins.attrNames fields);

  here = "kix/lib/vocab/otlp-endpoint.nix";
in
{
  alias = "otlp";
  inherit fields;

  # Return the contract violations a consumer reports for `out`.
  problems = problemsWith false;

  # Validate a provider's `root.out` and return it, or throw if any field is
  # missing or malformed.
  check =
    who: out:
    let
      found = problemsWith true out;
    in
    if found == [ ] then
      out
    else
      throw "${who}: root.out does not honour the OTLP endpoint contract: ${lib.concatStringsSep "; " found} (${here})";

  # Return dependency assertions that validate `dep.out` against the contract.
  # Dependency assertions run after `build`, so missing attributes that `build`
  # evaluates directly will fail earlier with a missing-attribute error.
  assertions =
    who: dep:
    let
      found = problemsWith false (dep.out or { });
      meta = dep._meta or { };
      provider =
        if meta ? namespaceName && meta ? instanceName then
          "${meta.namespaceName}/${meta.instanceName}"
        else
          "the instance it resolved to";
    in
    lib.optional (found != [ ]) {
      assertion = false;
      message = "${who}: deps.otlp resolved to ${provider}, whose out does not honour the OTLP endpoint contract: ${lib.concatStringsSep "; " found}. Set them on that instance's out (a kix.mkImport sets them in `out`), or wire another endpoint with deps.otlp = ref.<ns>.<instance> (${here}).";
    };
}

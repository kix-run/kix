# The OTLP endpoint contract: what a package answering the `otlp` alias
# publishes on root.out, the addresses where it receives OpenTelemetry
# traces, metrics, or logs. A trace store (tempo) and a collector both
# publish it, so an application written against these fields sends to
# either.
#
# A provider package passes its out through `check`, which requires every
# field. A consumer holds its dependency to the contract through
# `assertions`, which requires the fields marked `required` and checks the
# shape of the others when they are present, so a kix.mkImport stand-in may
# publish only the two URLs. Packages reach this file as
# `kix.contracts.otlpEndpoint`.
{ lib }:
let
  # OTLP exporters take a scheme, host, and port, and a gRPC exporter
  # rejects a path, so the URL ends at the port.
  isBaseUrl = v: builtins.isString v && builtins.match "https?://[^/]+" v != null;

  fields = {
    otlpGrpcUrl = {
      required = true;
      shape = "the OTLP/gRPC base URL, scheme://host:port with no path (port 4317 by convention)";
      test = isBaseUrl;
    };
    # Exporters append the signal path (`/v1/traces`) to this base.
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

  # Problems with `out`, one string per field. `all` requires every field;
  # otherwise only the required ones.
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

  # The problems a consumer's assertion reports for `out`.
  problems = problemsWith false;

  # For a provider: `root.out = kix.contracts.otlpEndpoint.check who { ... }`.
  # Returns `out`, or throws naming every missing or misshapen field.
  check =
    who: out:
    let
      found = problemsWith true out;
    in
    if found == [ ] then
      out
    else
      throw "${who}: root.out does not honour the OTLP endpoint contract: ${lib.concatStringsSep "; " found} (${here})";

  # For a consumer:
  # `deps.otlp.assertions = dep: kix.contracts.otlpEndpoint.assertions who dep;`.
  # The message names the instance the dependency resolved to. Dependency
  # assertions are evaluated after the build, so a field the build reads
  # and `out` lacks fails first with Nix's missing-attribute error.
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

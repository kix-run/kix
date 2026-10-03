# Tests for the OTLP endpoint contract (kix/lib/vocab/otlp-endpoint.nix):
# `check` on the provider side and `assertions` on the consumer side.

{
  lib,
  kixlib,
  ...
}:

let
  contract = kixlib.contracts.otlpEndpoint;

  # What a kix.mkImport stand-in must publish.
  importOut = {
    otlpGrpcUrl = "http://collector.example.net:4317";
    otlpHttpUrl = "http://collector.example.net:4318";
  };

  # What a provider package publishes.
  providerOut = importOut // {
    tls = false;
  };

  depOf = out: {
    inherit out;
    _meta = {
      namespaceName = "tracing";
      instanceName = "collector";
    };
  };

  messagesOf = assertions: map (a: a.message) (builtins.filter (a: !a.assertion) assertions);
  checks = out: (builtins.tryEval (contract.check "provider tracing/collector" out)).success;
in
{
  # A provider out with every field passes `check` unchanged, extra fields
  # included; one without `tls`, with a non-boolean `tls`, or with a path
  # after the port is refused.
  otlp-endpoint-check-requires-every-field =
    contract.check "provider tracing/collector" (providerOut // { queryUrl = "x"; })
    == providerOut // { queryUrl = "x"; }
    && checks (providerOut // { tls = null; })
    && !checks importOut
    && !checks (providerOut // { tls = "no"; })
    && !checks (providerOut // { otlpHttpUrl = "http://collector.example.net:4318/v1/traces"; })
    && !checks (providerOut // { otlpGrpcUrl = "collector.example.net:4317"; });

  # A consumer's assertion accepts an import with only the URLs, and refuses
  # one without `otlpGrpcUrl` with a message naming the consumer, the
  # provider instance, and the field.
  otlp-endpoint-assertions-name-instance-and-field =
    let
      missing = messagesOf (
        contract.assertions "app apps/app" (depOf (builtins.removeAttrs importOut [ "otlpGrpcUrl" ]))
      );
    in
    messagesOf (contract.assertions "app apps/app" (depOf importOut)) == [ ]
    && messagesOf (contract.assertions "app apps/app" (depOf providerOut)) == [ ]
    && builtins.length missing == 1
    && lib.hasInfix "app apps/app" (builtins.head missing)
    && lib.hasInfix "tracing/collector" (builtins.head missing)
    && lib.hasInfix "otlpGrpcUrl is missing" (builtins.head missing);

  # An optional field is still checked when present.
  otlp-endpoint-assertions-check-present-fields =
    let
      found = messagesOf (contract.assertions "app" (depOf (importOut // { tls = "yes"; })));
    in
    builtins.length found == 1 && lib.hasInfix "tls is not" (builtins.head found);
}

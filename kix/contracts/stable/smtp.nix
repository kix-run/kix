# Define the SMTP contract for `smtp` dependencies (`kix.contracts.smtp`),
# the consumer helpers that read it, and the shared `mail` option set
# (`kix.contracts.smtp.options`).
#
# An `smtp` instance is one application's way to send mail: a server, and
# the login the application uses there. A server outside the cluster is a
# `kix.mkImport`. Without a login, one import serves every namespace. With a
# login, `out.credentials` names a secret, and a pod reads Secrets only from
# its own namespace, so each namespace gets its own import (a Nix `let` can
# share the common settings).
{
  lib,
  mkContract,
  credentialsField,
  compose,
  ...
}:
let
  inherit (import ../../lib/core/error.nix { inherit lib; }) fail;

  tlsModes = [
    "starttls"
    "implicit"
    "none"
  ];

  isPortText = v: builtins.isString v && builtins.match "[0-9]+" v != null;
  isPort =
    v:
    let
      n =
        if builtins.isInt v then
          v
        else if isPortText v then
          lib.toInt v
        else
          0;
    in
    n >= 1 && n <= 65535;

  isAddress = v: builtins.isString v && builtins.match "[^@[:space:]]+@[^@[:space:]]+" v != null;

  fields = {
    host = {
      required = true;
      shape = "the server's hostname or IP address";
      test = v: builtins.isString v && builtins.match "[^[:space:]:/]+" v != null;
    };
    # A string keeps the string context an in-cluster provider attaches,
    # which is how Kix derives the network edge to it.
    port = {
      required = true;
      shape = "the server's port, as a string or an integer from 1 to 65535";
      test = isPort;
    };
    tls = {
      required = true;
      shape = "one of ${lib.concatMapStringsSep ", " builtins.toJSON tlsModes}";
      test = v: builtins.elem v tlsModes;
    };
    credentials = credentialsField {
      keys = [
        "username"
        "password"
      ];
      required = false;
    };
    from = {
      required = false;
      shape = "the default sender address, such as \"noreply@example.org\", or null";
      test = v: v == null || isAddress v;
    };
    external = {
      required = false;
      shape = "true when the server is outside the cluster, false when it runs in it";
      test = builtins.isBool;
    };
  };

  contract = mkContract {
    name = "SMTP";
    alias = "smtp";
    remedyNoun = "SMTP server";
    inherit fields;

    helpers = {
      # Validate the `smtp` dependency and return its connection details, or
      # null when no server is wired. `from` is the server's `out.from` or
      # null. For an application that keeps its sender elsewhere, such as
      # Keycloak's realms.
      inherit server;

      # Validate the `smtp` dependency and return its settings with a sender,
      # or null when no server is wired. `from` is the instance's `mail.from`,
      # which replaces the server's `out.from`.
      settings =
        {
          who,
          smtp,
          from ? null,
        }:
        let
          found = server { inherit who smtp; };
          sender = if from != null then from else found.from;
        in
        if found == null then
          null
        else if sender == null then
          fail {
            message = "${who}: deps.smtp has no sender address.";
            fix = "Set out.from on the SMTP instance, or mail.from on this instance.";
          }
        else
          found // { from = sender; };

      # Build a network policy that lets the pods `selector` matches reach an
      # external server on its port, or return null for a server in the
      # cluster. The rule allows any address on that port, because the enforcer
      # cannot name a host outside the cluster.
      egressPolicy =
        {
          scope,
          name,
          selector,
          smtp,
        }:
        if smtp == null || !smtp.external then
          null
        else
          compose.operandPolicy {
            inherit scope name;
            spec =
              let
                netpol = scope.networkPolicyEnforcer.netpol;
              in
              netpol.mkEndpointSelector selector
              // {
                egress =
                  (netpol.translateIntentRules {
                    intents.mail.egress = [
                      {
                        to = "world";
                        ports = [
                          {
                            port = smtp.portNumber;
                            protocol = "TCP";
                          }
                        ];
                      }
                    ];
                  }).egressRules;
              };
          };

      # Build the `mail` option set for a package that takes `smtp`.
    };

    options = {
      from = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching "[^@[:space:]]+@[^@[:space:]]+");
        default = null;
        example = "vault@example.org";
        description = "Sender address for this instance's mail. Null uses the `smtp` instance's `out.from`.";
      };
    };
  };

  # A server without `external = false` counts as outside the cluster, so
  # `tls = "none"` is refused there: the password and the mail would cross
  # the internet in clear text.
  server =
    { who, smtp }:
    if smtp == null then
      null
    else
      let
        out = (contract.require who smtp).out;
        external = out.external or true;
      in
      if out.tls == "none" && external then
        fail {
          message = "${who}: deps.smtp is a server outside the cluster with tls = \"none\", so the password and the mail would cross the internet in clear text.";
          fix = "Set tls to \"starttls\" (usually port 587) or \"implicit\" (usually port 465) on its out. A server inside the cluster sets external = false.";
        }
      else
        {
          inherit (out) host tls;
          inherit external;
          port = toString out.port;
          portNumber = if builtins.isInt out.port then out.port else lib.toInt out.port;
          from = out.from or null;
          credentials = out.credentials or null;
        };
in
contract

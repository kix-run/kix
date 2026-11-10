# Define the SMTP relay contract for `smtp` dependencies
# (`kix.contracts.smtpRelay`), the consumer helpers that read it, and the
# shared `mail` option set (`kix.options.mail`).
#
# The relay and its credentials are two dependencies. `smtp` carries only
# plain settings, so a `kix.mkImport` can declare one relay for the whole
# cluster. `smtpCredentials` is a secret with keys `username` and `password`
# in the consumer's own namespace, because a pod reads Secrets only from its
# own namespace. Each application can then have its own login at the relay.
{ lib }:
let
  inherit (import ./contract.nix { inherit lib; }) mkContract;
  compose = import ./compose.nix { inherit lib; };

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
      shape = "the relay's hostname or IP address";
      test = v: builtins.isString v && builtins.match "[^[:space:]:/]+" v != null;
    };
    # A string keeps the string context an in-cluster provider attaches,
    # which is how Kix derives the network edge to it.
    port = {
      required = true;
      shape = "the relay's port, as a string or an integer from 1 to 65535";
      test = isPort;
    };
    tls = {
      required = true;
      shape = "one of ${lib.concatMapStringsSep ", " builtins.toJSON tlsModes}";
      test = v: builtins.elem v tlsModes;
    };
    from = {
      required = false;
      shape = "the default sender address, such as \"noreply@example.org\", or null";
      test = v: v == null || isAddress v;
    };
    external = {
      required = false;
      shape = "true when the relay is outside the cluster, false when it runs in it";
      test = builtins.isBool;
    };
  };

  contract = mkContract {
    name = "SMTP relay";
    alias = "smtp";
    remedyNoun = "relay";
    here = "kix/lib/vocab/smtp-relay.nix";
    inherit fields;
  };

  credentialKeys = [
    "username"
    "password"
  ];
in
{
  inherit (contract)
    alias
    fields
    problems
    check
    assertions
    ;

  inherit credentialKeys;

  # Validate the `smtp` and `smtpCredentials` dependencies and return the
  # relay's settings, or null when no relay is wired. `from` is the
  # instance's `mail.from`, which replaces the relay's `out.from`.
  #
  # A relay without `external = false` counts as outside the cluster, so
  # `tls = "none"` is refused there: the password and the mail would cross
  # the internet in clear text.
  requireRelay =
    {
      who,
      smtp,
      credentials,
      from ? null,
    }:
    if smtp == null then
      if credentials != null then
        throw "${who}: deps.smtpCredentials is wired, but no relay is. Declare the relay and wire it with deps.smtp = ref.<ns>.<instance> (a kix.mkImport whose out sets host, port, and tls), or remove smtpCredentials."
      else
        null
    else
      let
        out = (contract.require who smtp).out;
        external = out.external or true;
        sender = if from != null then from else out.from or null;
        checked =
          if credentials == null then
            null
          else
            compose.checkSecretKeys {
              inherit who;
              arg = "smtpCredentials";
              dep = credentials;
              keys = credentialKeys;
            };
      in
      if out.tls == "none" && external then
        throw "${who}: deps.smtp is a relay outside the cluster with tls = \"none\", so the password and the mail would cross the internet in clear text. Set tls to \"starttls\" (usually port 587) or \"implicit\" (usually port 465) on the relay's out. A relay inside the cluster sets external = false."
      else if sender == null then
        throw "${who}: deps.smtp has no sender address. Set out.from on the relay, or mail.from on this instance."
      else
        {
          inherit (out) host tls;
          inherit external;
          port = toString out.port;
          portNumber = if builtins.isInt out.port then out.port else lib.toInt out.port;
          from = sender;
          credentials = checked;
        };

  # Build a network policy that lets the pods `selector` matches reach an
  # external relay on its port, or return null for a relay in the cluster.
  # The rule allows any address on that port, because the enforcer cannot
  # name a host outside the cluster.
  egressPolicy =
    {
      scope,
      name,
      selector,
      relay,
    }:
    if relay == null || !relay.external then
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
                        port = relay.portNumber;
                        protocol = "TCP";
                      }
                    ];
                  }
                ];
              }).egressRules;
          };
      };

  # Build the `mail` option set for a package that takes `smtp`.
  options = {
    from = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "[^@[:space:]]+@[^@[:space:]]+");
      default = null;
      example = "vault@example.org";
      description = "Sender address for this instance's mail. Null uses the `smtp` relay's `out.from`.";
    };
  };
}

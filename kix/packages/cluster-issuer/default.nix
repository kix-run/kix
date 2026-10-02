# cluster-issuer: one cert-manager ClusterIssuer, named after the instance.
#
# `spec` is the ClusterIssuer's `spec` as cert-manager documents it. The
# package checks it at evaluation against the ClusterIssuer CRD that the wired
# cert-manager vendors (`certManager.out.clusterIssuerSpecSchema`): an unknown
# field, a missing required field, a spec with no issuer type or two, and an
# ACME solver with no challenge or DNS provider or two all fail the build.
#
# An instance lives in cert-manager's cluster resource namespace
# (`certManager.out.clusterResourceNamespace`). cert-manager reads a
# ClusterIssuer's Secrets only from there, and `secret` and `secret-ref`
# instances serve only their own namespace, so the credentials instance must
# be there too. Instance names are unique within a namespace, so two
# ClusterIssuers built by this package never share a name.
#
#   instances.cert-manager.selfsigned = {
#     package = packages.cluster-issuer;
#     config.spec.selfSigned = { };
#   };
#
# DI deps:
#   certManager (required)        the cert-manager instance; supplies the CRD
#                                 handle, the schema, and the namespace.
#   issuerCredentials (optional)  a `secret` or `secret-ref` that declares
#                                 every key the spec's Secret key selectors
#                                 name. The dependency is named for what it
#                                 holds; the Secret is this issuer's alone.
#
# The package fills in two things:
#   - `acme.privateKeySecretRef.name`, when unset, with
#     `<instance>-acme-account-key`. cert-manager creates that Secret.
#   - every other Secret key selector in the spec (a schema node whose
#     properties are exactly `key` and `name`, such as
#     `dns01.cloudflare.apiTokenSecretRef`). A selector that leaves `name`
#     out gets the issuerCredentials Secret's tracked name, after its `key`
#     is checked against the keys that Secret declares. A literal `name` is
#     refused; `kix.untrackedRef` opts out of the check.
#
# Not tracked: `ca.secretName`, `venafi.*.credentialsRef.name`,
# `vault.auth.kubernetes.serviceAccountRef.name`, and anything inside a
# webhook solver's `config` (a free-form object in the CRD).
#
# HTTP-01 solvers are accepted, and warn when a network policy enforcer is
# present: cert-manager creates the solver pods at runtime, and no derived
# policy admits the ingress controller to them.
#
# out:
#   out.name       the ClusterIssuer's name.
#   out.withCert   adds `cert-manager.io/cluster-issuer` to a resource's
#                  annotations; `kix.expose` calls it for Ingress TLS.

{
  scope,
  lib,
  ...
}:

let
  ns = scope.namespaceName;
  who = "cluster-issuer ${ns}/${scope.instanceName}";
  accountKeyPath = "spec.acme.privateKeySecretRef";

  listOrNone = xs: if xs == [ ] then "none" else lib.concatStringsSep ", " xs;
  isPreserved = schema: schema."x-kubernetes-preserve-unknown-fields" or false;

  # cert-manager's SecretKeySelector: `{ name; key; }`, name required.
  isKeySelectorSchema =
    schema:
    builtins.attrNames (schema.properties or { }) == [
      "key"
      "name"
    ];

  # The solvers of an ACME spec, each with its path. Empty for any other
  # issuer type or a malformed `acme`.
  solversOf =
    spec:
    let
      acme = spec.acme or null;
      solvers = if builtins.isAttrs acme then acme.solvers or [ ] else [ ];
    in
    lib.optionals (builtins.isList solvers) (
      lib.imap0 (i: solver: {
        path = "spec.acme.solvers[${toString i}]";
        inherit solver;
      }) solvers
    );

  # Messages for every field the schema does not define and every required
  # field the value leaves out or sets to null, below `path`. Types are left
  # to the API server. A Secret key selector's required `name` is not
  # reported here: the fill step either sets it or reports why it could not.
  schemaErrors =
    path: schema: value:
    if isPreserved schema then
      [ ]
    else if builtins.isAttrs value && schema ? properties then
      let
        props = schema.properties;
        present = builtins.attrNames value;
        unknown = builtins.filter (k: !(props ? ${k})) present;
        missing = lib.optionals (!isKeySelectorSchema schema) (
          builtins.filter (k: (value.${k} or null) == null) (schema.required or [ ])
        );
      in
      map (
        k:
        "${path} has no field \"${k}\". It accepts: ${lib.concatStringsSep ", " (builtins.attrNames props)}."
      ) unknown
      ++ map (k: "${path} requires \"${k}\".") missing
      ++ lib.concatMap (k: schemaErrors "${path}.${k}" props.${k} value.${k}) (
        builtins.filter (k: props ? ${k}) present
      )
    else if builtins.isAttrs value && builtins.isAttrs (schema.additionalProperties or null) then
      lib.concatMap (k: schemaErrors "${path}.${k}" schema.additionalProperties value.${k}) (
        builtins.attrNames value
      )
    else if builtins.isList value && schema ? items then
      lib.concatLists (lib.imap0 (i: v: schemaErrors "${path}[${toString i}]" schema.items v) value)
    else
      [ ];
in
{
  meta = {
    description = "A cert-manager ClusterIssuer; `kix.expose` uses it for Ingress TLS";
    owner = "platform";
    defaultAliases = [ "clusterIssuer" ];
  };

  options.spec = lib.mkOption {
    # Read structurally, and checked against the vendored CRD schema in the
    # build.
    type = lib.types.attrsOf lib.types.anything;
    example = lib.literalExpression ''
      {
        acme = {
          server = "https://acme-v02.api.letsencrypt.org/directory";
          email = "platform@example.com";
          solvers = [
            {
              dns01.cloudflare.apiTokenSecretRef.key = "api-token";
              selector.dnsZones = [ "example.com" ];
            }
          ];
        };
      }
    '';
    description = ''
      The ClusterIssuer `spec`, in cert-manager's API. Set exactly one issuer
      type: `acme`, `ca`, `selfSigned`, `vault`, or `venafi`. A self-signed
      issuer is `{ selfSigned = { }; }`.

      Fields the vendored ClusterIssuer CRD does not define fail the build.
      `acme.privateKeySecretRef.name` defaults to
      `<instance>-acme-account-key`, a Secret cert-manager creates.

      Leave `name` out of every other Secret key selector (such as
      `dns01.cloudflare.apiTokenSecretRef`) and set only `key`: the package
      fills in the Secret of the `issuerCredentials` dependency and checks
      that it declares the key. An issuer that needs several credentials,
      such as an ACME external account binding and a DNS token, keeps them
      as several keys of that one Secret. `name = kix.untrackedRef "<name>"`
      names a Secret Kix does not check.
    '';
  };

  warnings =
    { config, ... }:
    let
      http01Paths = map (s: s.path) (
        builtins.filter (s: builtins.isAttrs s.solver && s.solver ? http01) (solversOf config.spec)
      );
    in
    lib.optionals (scope.networkPolicyEnforcer != null) (
      map (
        path:
        "${path} uses an HTTP-01 solver. cert-manager creates the solver pods at runtime in each Certificate's namespace, and Kix's derived network policy does not admit the ingress controller to them on port 8089, so the challenge will not complete while policy is enforced. Use a dns01 solver, or add a networkPolicy.platformIntents entry that admits ingress from all-pods on TCP 8089 to pods labelled acme.cert-manager.io/http01-solver=true."
      ) http01Paths
    );

  build =
    {
      self,
      config,
      certManager,
      issuerCredentials ? null,
      ...
    }:
    let
      schema = certManager.out.clusterIssuerSpecSchema;
      cmNs = certManager.out.clusterResourceNamespace;
      issuerTypes = builtins.attrNames schema.properties;
      dns01Schema = schema.properties.acme.properties.solvers.items.properties.dns01;
      dnsProviders = builtins.attrNames (
        lib.filterAttrs (_: s: (s.type or null) == "object") dns01Schema.properties
      );

      credKeys = if issuerCredentials == null then [ ] else issuerCredentials.out.keys or [ ];
      credName = if issuerCredentials == null then "" else issuerCredentials.out.name;

      accountKeyName = "${scope.instanceName}-acme-account-key";
      withAccountKey =
        spec:
        let
          acme = spec.acme or null;
          ref = if builtins.isAttrs acme then acme.privateKeySecretRef or { } else null;
        in
        if builtins.isAttrs ref && !(ref ? name) then
          spec
          // {
            acme = acme // {
              privateKeySecretRef = ref // {
                name = accountKeyName;
              };
            };
          }
        else
          spec;

      ok = value: {
        inherit value;
        errors = [ ];
      };
      bad = value: message: {
        inherit value;
        errors = [ message ];
      };

      fillSelector =
        path: sel:
        if sel ? name then
          if builtins.isString sel.name && builtins.hasContext sel.name then
            ok sel
          else
            bad sel "${path}.name is the literal \"${toString sel.name}\". Leave name out and wire the Secret as issuerCredentials, so Kix can check its keys, or write name = kix.untrackedRef \"${toString sel.name}\" to opt out explicitly."
        else if !(sel ? key) then
          bad sel "${path} leaves name out but sets no key. Set key to the Secret key that holds the credential."
        else if issuerCredentials == null then
          bad sel "${path} names key \"${sel.key}\" but no issuerCredentials dependency is wired. Add a secret or secret-ref instance in namespace \"${cmNs}\" that declares \"${sel.key}\", and set deps.issuerCredentials = ref.${cmNs}.<that instance>. The issuer and its credentials both live in \"${cmNs}\", because cert-manager reads ClusterIssuer Secrets only from there."
        else if !(builtins.elem sel.key credKeys) then
          bad sel "${path} asks for key \"${sel.key}\", and issuerCredentials \"${credName}\" declares: ${listOrNone credKeys}. Add the key to that instance's keys."
        else
          ok (sel // (issuerCredentials.out.keyRef sel.key).valueFrom.secretKeyRef);

      # Walks `value` beside its schema and fills every Secret key selector
      # except the ACME account key. Returns the filled value and the
      # messages, in path order.
      fill =
        path: nodeSchema: value:
        let
          collect = results: {
            value = lib.mapAttrs (_: r: r.value) results;
            errors = lib.concatMap (k: results.${k}.errors) (builtins.attrNames results);
          };
        in
        if isPreserved nodeSchema then
          ok value
        else if builtins.isAttrs value && isKeySelectorSchema nodeSchema && path != accountKeyPath then
          fillSelector path value
        else if builtins.isAttrs value && nodeSchema ? properties then
          collect (
            lib.mapAttrs (
              k: v:
              if nodeSchema.properties ? ${k} then fill "${path}.${k}" nodeSchema.properties.${k} v else ok v
            ) value
          )
        else if builtins.isAttrs value && builtins.isAttrs (nodeSchema.additionalProperties or null) then
          collect (lib.mapAttrs (k: v: fill "${path}.${k}" nodeSchema.additionalProperties v) value)
        else if builtins.isList value && nodeSchema ? items then
          let
            results = lib.imap0 (i: v: fill "${path}[${toString i}]" nodeSchema.items v) value;
          in
          {
            value = map (r: r.value) results;
            errors = lib.concatMap (r: r.errors) results;
          }
        else
          ok value;

      filled = fill "spec" schema (withAccountKey config.spec);

      namespaceErrors =
        lib.optional (ns != cmNs)
          "cluster-issuer instances live in cert-manager's cluster resource namespace \"${cmNs}\", where cert-manager reads issuer Secrets and where instance names are unique so two ClusterIssuers cannot share a name. Move this instance, and any issuerCredentials instance, from \"${ns}\" to \"${cmNs}\".";

      setTypes = builtins.filter (k: builtins.elem k issuerTypes) (builtins.attrNames config.spec);
      typeErrors =
        lib.optional (builtins.length setTypes != 1)
          "a ClusterIssuer needs exactly one issuer type, and spec has ${listOrNone setTypes}. Set one of: ${lib.concatStringsSep ", " issuerTypes}.";

      solvers = solversOf config.spec;

      challengeErrors = lib.concatMap (
        { path, solver }:
        let
          set = builtins.filter (k: builtins.isAttrs solver && solver ? ${k}) [
            "http01"
            "dns01"
          ];
        in
        lib.optional (builtins.length set != 1)
          "${path} sets ${
            if set == [ ] then "neither" else lib.concatStringsSep ", " set
          }. A solver sets exactly one of http01 or dns01."
      ) solvers;

      providerErrors = lib.concatMap (
        { path, solver }:
        let
          dns01 = if builtins.isAttrs solver then solver.dns01 or null else null;
          set = builtins.filter (k: dns01 ? ${k}) dnsProviders;
        in
        lib.optional (builtins.isAttrs dns01 && builtins.length set != 1)
          "${path}.dns01 sets ${
            if set == [ ] then "no provider" else lib.concatStringsSep ", " set
          }. A dns01 solver uses exactly one of: ${lib.concatStringsSep ", " dnsProviders}."
      ) solvers;

      errors =
        namespaceErrors
        ++ typeErrors
        ++ filled.errors
        ++ schemaErrors "spec" schema filled.value
        ++ challengeErrors
        ++ providerErrors;

      checked =
        if errors == [ ] then
          true
        else
          throw (
            "${who}: the ClusterIssuer spec has ${toString (builtins.length errors)} problem(s):\n"
            + lib.concatMapStringsSep "\n" (e: "- ${e}") errors
          );
    in
    {
      # The check is forced with the resource, so neither the manifest nor
      # `out` can be read from a spec that failed it.
      issuer = builtins.seq checked (
        scope.mkCR certManager.out.crds.ClusterIssuer {
          name = scope.instanceName;
          spec = filled.value;
        }
      );

      root = {
        resource = self.issuer;
        out.withCert =
          args:
          args
          // {
            annotations = (args.annotations or { }) // {
              "cert-manager.io/cluster-issuer" = self.issuer.out.name;
            };
          };
      };
    };
}

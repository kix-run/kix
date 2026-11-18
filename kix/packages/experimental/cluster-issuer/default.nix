# cluster-issuer: one cert-manager ClusterIssuer, named after the instance.
#
# `spec` is the ClusterIssuer's `spec` as cert-manager documents it. The
# package checks it at evaluation against the ClusterIssuer CRD that the wired
# cert-manager vendors (`certManager.out.clusterIssuerSpecSchema`). These fail
# the build: a field the CRD does not define, a missing required field, a
# value of the wrong type (such as `solvers` written as an attribute set), a
# spec with no issuer type or two, an ACME solver that sets neither or both of
# `http01` and `dns01`, and a `dns01` solver with no provider or two. A field
# set to null counts as absent and is not rendered.
#
# The option is the whole spec. Metadata the package does not set, such as
# labels and annotations on the ClusterIssuer, goes through the instance's
# `partsOverlays.issuer`.
#
# An instance lives in cert-manager's cluster resource namespace
# (`certManager.out.clusterResourceNamespace`). cert-manager reads a
# ClusterIssuer's Secrets only from there, and `secret` and `secret-ref`
# instances serve only their own namespace, so the credentials instance must
# be there too. Instance names are unique within a namespace, so two
# ClusterIssuers built by this package never share a name.
#
#   instances.cert-manager.selfsigned = {
#     package = packages.experimental.cluster-issuer;
#     config.spec.selfSigned = { };
#   };
#
# Dependencies:
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
#     refused. A name that carries Kix context, from `kix.untrackedRef` or
#     another Secret's `out.name`, is kept as written and its key is not
#     checked.
#
# Not tracked: `ca.secretName`, `venafi.*.credentialsRef.name`,
# `vault.auth.kubernetes.serviceAccountRef.name`, the HTTP-01 solver's
# Ingress, IngressClass, and Gateway references, and anything inside a
# webhook solver's `config` (a free-form object in the CRD).
#
# HTTP-01 solvers: cert-manager starts the solver pods at runtime in each
# Certificate's namespace. For an Ingress that `kix.expose` builds, expose
# reads `out.http01SolverSelector` and writes a policy admitting the ingress
# controller to those pods on TCP 8089. A Certificate made any other way
# needs its own policy under an enforcer.
#
# `out`:
#   out.name       the ClusterIssuer's name.
#   out.withCert   adds `cert-manager.io/cluster-issuer` to a resource's
#                  annotations; `kix.expose` calls it for Ingress TLS.
#   out.http01SolverSelector
#                  the labels of cert-manager's HTTP-01 solver pods when a
#                  solver uses `http01`, else null.
#   out.needsHttp01
#                  true for an ACME issuer with no `dns01` solver, which can
#                  prove a name only by answering an HTTP request for it. It
#                  cannot issue a wildcard name.
#   out.mkCertificate
#                  `scope: { name; dnsNames; secretName ? name; }` builds a
#                  cert-manager Certificate in the caller's namespace that
#                  this issuer signs. A Gateway package calls it for a
#                  listener's certificate.

{
  scope,
  lib,
  ...
}:

let
  ns = scope.namespaceName;
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

  # Removes attributes set to null, except inside free-form subtrees, so the
  # checks and the rendered ClusterIssuer treat them as absent.
  dropNulls =
    schema: value:
    if isPreserved schema then
      value
    else if builtins.isAttrs value then
      lib.mapAttrs (
        k:
        dropNulls (
          schema.properties.${k} or (
            if builtins.isAttrs (schema.additionalProperties or null) then schema.additionalProperties else { }
          )
        )
      ) (lib.filterAttrs (_: v: v != null) value)
    else if builtins.isList value then
      map (dropNulls (schema.items or { })) value
    else
      value;

  describeValue =
    v:
    if builtins.isAttrs v then
      "an attribute set"
    else if builtins.isList v then
      "a list"
    else if builtins.isString v then
      "a string"
    else if builtins.isInt v then
      "an integer"
    else if builtins.isFloat v then
      "a float"
    else if builtins.isBool v then
      "a boolean"
    else if v == null then
      "null"
    else
      builtins.typeOf v;

  # The CRD's JSON schema types, in the Nix terms a cluster file uses. A
  # node with neither `type` nor `x-kubernetes-int-or-string` accepts any
  # value.
  schemaTypes = {
    object = {
      text = "an attribute set";
      matches = builtins.isAttrs;
    };
    array = {
      text = "a list";
      matches = builtins.isList;
    };
    string = {
      text = "a string";
      matches = builtins.isString;
    };
    integer = {
      text = "an integer";
      matches = builtins.isInt;
    };
    number = {
      text = "a number";
      matches = v: builtins.isInt v || builtins.isFloat v;
    };
    boolean = {
      text = "a boolean";
      matches = builtins.isBool;
    };
  };
  expectedType =
    schema:
    if schema."x-kubernetes-int-or-string" or false then
      {
        text = "an integer or a string";
        matches = v: builtins.isInt v || builtins.isString v;
      }
    else
      schemaTypes.${schema.type or ""} or null;

  # Messages for every value whose type the schema does not allow, every
  # field the schema does not define, and every required field the value
  # leaves out, below `path`. A Secret key selector's required `name` is not
  # reported here: the fill step either sets it or reports why it could not.
  schemaErrors =
    path: schema: value:
    let
      expected = expectedType schema;
    in
    if expected != null && !(expected.matches value) then
      [
        "${path} is ${describeValue value}, and the ClusterIssuer CRD expects ${expected.text}."
      ]
    else if isPreserved schema then
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
    # A ClusterIssuer is cluster-scoped, so consumers in any namespace find
    # it by name.
    scope = "cluster";
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

      Fields the vendored ClusterIssuer CRD does not define, and values of a
      type it does not allow, fail the build. A field set to null is left
      out.
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

  build =
    {
      self,
      config,
      certManager,
      issuerCredentials ? null,
      ...
    }:
    let
      # A `kix.mkImport` answering certManager has none of these.
      cmOut =
        let
          out = certManager.out or { };
        in
        if
          out ? clusterIssuerSpecSchema && out ? clusterResourceNamespace && (out.crds or { }) ? ClusterIssuer
        then
          out
        else
          scope.fail {
            package = "cluster-issuer";
            message = "deps.certManager resolved to an instance whose out has no clusterIssuerSpecSchema, clusterResourceNamespace, or crds.ClusterIssuer, such as a kix.mkImport. This package needs the cert-manager package.";
            fix = "For a cert-manager installed outside Kix, declare the existing ClusterIssuer as a kix.mkImport { out.withCert = ...; } instance with aliases = [ \"clusterIssuer\" ] instead.";
          };
      schema = cmOut.clusterIssuerSpecSchema;
      cmNs = cmOut.clusterResourceNamespace;
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

      # A `name` or `key` that is not a string is left as written; the
      # schema check reports its type.
      fillSelector =
        path: sel:
        if sel ? name then
          if !(builtins.isString sel.name) || builtins.hasContext sel.name then
            ok sel
          else
            bad sel "${path}.name is the literal \"${sel.name}\". Leave name out and wire the Secret as issuerCredentials, so Kix can check its keys, or write name = kix.untrackedRef \"${sel.name}\" to opt out explicitly."
        else if !(sel ? key) then
          bad sel "${path} leaves name out but sets no key. Set key to the Secret key that holds the credential."
        else if !(builtins.isString sel.key) then
          ok sel
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

      spec = dropNulls schema config.spec;
      filled = fill "spec" schema (withAccountKey spec);

      namespaceErrors =
        lib.optional (ns != cmNs)
          "cluster-issuer instances live in cert-manager's cluster resource namespace \"${cmNs}\", where cert-manager reads issuer Secrets and where instance names are unique so two ClusterIssuers cannot share a name. Move this instance, and any issuerCredentials instance, from \"${ns}\" to \"${cmNs}\".";

      setTypes = builtins.filter (k: builtins.elem k issuerTypes) (builtins.attrNames spec);
      typeErrors =
        lib.optional (builtins.length setTypes != 1)
          "a ClusterIssuer needs exactly one issuer type, and spec has ${listOrNone setTypes}. Set one of: ${lib.concatStringsSep ", " issuerTypes}.";

      solvers = solversOf spec;

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
          scope.fail (
            map (message: {
              package = "cluster-issuer";
              inherit message;
            }) errors
          );
    in
    {
      # The check is forced with the resource, so neither the manifest nor
      # `out` can be read from a spec that failed it.
      issuer = builtins.seq checked (
        scope.mkCR cmOut.crds.ClusterIssuer {
          name = scope.instanceName;
          spec = filled.value;
        }
      );

      root = {
        resource = self.issuer;
        out.http01SolverSelector =
          if
            builtins.any (s: builtins.isAttrs s.solver && (s.solver.http01 or null) != null) (
              solversOf config.spec
            )
          then
            cmOut.operandSelectors.acmesolver
          else
            null;
        out.name = self.issuer.out.name;
        out.needsHttp01 =
          config.spec ? acme
          && !(builtins.any (s: builtins.isAttrs s.solver && (s.solver.dns01 or null) != null) (
            solversOf config.spec
          ));
        out.mkCertificate =
          callerScope:
          {
            name,
            dnsNames,
            secretName ? name,
          }:
          callerScope.mkCR cmOut.crds.Certificate {
            inherit name;
            spec = {
              inherit secretName dnsNames;
              issuerRef = {
                group = "cert-manager.io";
                kind = "ClusterIssuer";
                name = self.issuer.out.name;
              };
            };
          };
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

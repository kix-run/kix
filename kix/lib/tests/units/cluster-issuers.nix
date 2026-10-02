# Tests for the cluster-issuer package: the rendered ClusterIssuer, the
# Secret key selector fill from `issuerCredentials`, the ACME account key
# default, the refusals checked against cert-manager's vendored CRD schema,
# the namespace rule, the HTTP-01 warning under an enforcer, and
# `out.withCert`. cert-manager runs as instance `cert-manager` in namespace
# `cert-manager`. `evalFails` cannot read a message; the messages are checked
# by evaluating the failing clusters directly.

{
  lib,
  kixKeys,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  netpolOn,
  ...
}:

let
  inherit (import ../../vocab { inherit lib; }) untrackedRef;
  certManagerPackage = import ../../../packages/cert-manager;
  issuerPackage = import ../../../packages/cluster-issuer;
  secretPackage = import ../../../packages/secret;
  secretRefPackage = import ../../../packages/secret-ref;

  certManager.instances.cert-manager.cert-manager.package = certManagerPackage;

  issuer = ns: name: spec: extra: {
    instances.${ns}.${name} = {
      package = issuerPackage;
      config.spec = spec;
    }
    // extra;
  };

  credentials = ns: keys: extra: {
    instances.${ns}.cf-token = {
      package = secretRefPackage;
      config.keys = keys;
    }
    // extra;
  };

  acme = solvers: {
    server = "https://acme.example.test/directory";
    email = "platform@example.test";
    inherit solvers;
  };
  cloudflare = {
    dns01.cloudflare.apiTokenSecretRef.key = "api-token";
  };
  acmeSpec = solvers: { acme = acme solvers; };

  issuerOf = name: cluster: byName name (ofKind "ClusterIssuer" (manifests cluster));
  specOf = name: cluster: (issuerOf name cluster).spec;
  dependsOn = m: lib.splitString "," ((m.metadata.annotations or { }).${kixKeys.dependsOn} or "");

  # DNS-01 through a secret-ref in cert-manager's namespace.
  wiredCluster =
    credentialsExtra: issuerExtra:
    mkCluster [
      certManager
      (credentials "cert-manager" [ "api-token" ] credentialsExtra)
      (issuer "cert-manager" "letsencrypt" (acmeSpec [ cloudflare ]) issuerExtra)
    ];
  explicitCluster = mkCluster [
    certManager
    (credentials "cert-manager" [ "api-token" ] { })
    (
      { ref, ... }:
      issuer "cert-manager" "letsencrypt" (acmeSpec [ cloudflare ]) {
        deps.issuerCredentials = ref.cert-manager.cf-token;
      }
    )
  ];
  aliasCluster = wiredCluster { aliases = [ "issuerCredentials" ]; } { };

  tokenRef = {
    name = "cf-token";
    key = "api-token";
  };
  tokenRefOf =
    cluster:
    (builtins.head (specOf "letsencrypt" cluster).acme.solvers).dns01.cloudflare.apiTokenSecretRef;

  failsWith =
    spec:
    evalFails (mkCluster [
      certManager
      (credentials "cert-manager" [ "api-token" ] { aliases = [ "issuerCredentials" ]; })
      (issuer "cert-manager" "bad" spec { })
    ]);

  warningsOf =
    modules:
    (mkCluster ([ certManager ] ++ modules)).instances.cert-manager.solver._diagnostics.warnings;
  http01Issuer = issuer "cert-manager" "solver" (acmeSpec [
    { http01.ingress.ingressClassName = "nginx"; }
  ]) { };
  hasHttp01Warning = ws: builtins.any (lib.hasInfix "uses an HTTP-01 solver") ws;
in
{
  # (a) The spec renders as given, named after the instance.
  cluster-issuers-self-signed =
    let
      m = issuerOf "selfsigned" (mkCluster [
        certManager
        (issuer "cert-manager" "selfsigned" { selfSigned = { }; } { })
      ]);
    in
    (m != null && m.spec == { selfSigned = { }; } && m.apiVersion == "cert-manager.io/v1")
    || throw "expected ClusterIssuer selfsigned with spec { selfSigned = { }; }, got ${builtins.toJSON m}";

  # (b) An explicit issuerCredentials fills the selector's name, and the
  # ClusterIssuer depends on the secret-ref marker.
  cluster-issuers-dns01-explicit-credentials =
    let
      # depends-on entries name a resource by its store path hash.
      marker = builtins.substring 11 32 (
        builtins.unsafeDiscardStringContext explicitCluster.instances.cert-manager.cf-token.raw.ref.outPath
      );
    in
    (
      tokenRefOf explicitCluster == tokenRef
      && builtins.elem marker (dependsOn (issuerOf "letsencrypt" explicitCluster))
    )
    || throw "expected apiTokenSecretRef ${builtins.toJSON tokenRef} and a dependency on the secret-ref, got ${builtins.toJSON (issuerOf "letsencrypt" explicitCluster)}";

  # (c) A secret-ref aliased `issuerCredentials` in the same namespace
  # resolves without an explicit dependency.
  cluster-issuers-dns01-alias-credentials =
    tokenRefOf aliasCluster == tokenRef
    || throw "expected apiTokenSecretRef ${builtins.toJSON tokenRef}, got ${builtins.toJSON (tokenRefOf aliasCluster)}";

  # (d) The ACME account key defaults to <instance>-acme-account-key; a
  # user-set `key` on it is kept and not treated as a credential selector.
  cluster-issuers-account-key-default =
    let
      ref =
        (specOf "letsencrypt" (
          wiredCluster { aliases = [ "issuerCredentials" ]; } {
            config.spec.acme = acme [ cloudflare ] // {
              privateKeySecretRef.key = "tls.key";
            };
          }
        )).acme.privateKeySecretRef;
    in
    (
      (specOf "letsencrypt" aliasCluster).acme.privateKeySecretRef == {
        name = "letsencrypt-acme-account-key";
      }
      &&
        ref == {
          name = "letsencrypt-acme-account-key";
          key = "tls.key";
        }
    )
    || throw "unexpected privateKeySecretRef: ${builtins.toJSON ref}";

  # (e) A name marked with kix.untrackedRef is kept without a credentials
  # dependency.
  cluster-issuers-untracked-name-kept =
    let
      cluster = mkCluster [
        certManager
        (issuer "cert-manager" "letsencrypt" (acmeSpec [
          {
            dns01.cloudflare.apiTokenSecretRef = {
              name = untrackedRef "external-token";
              key = "token";
            };
          }
        ]) { })
      ];
      got = tokenRefOf cluster;
    in
    (builtins.unsafeDiscardStringContext got.name == "external-token" && got.key == "token")
    || throw "expected the untracked name to be kept, got ${builtins.toJSON got}";

  # (f) A Secret aliased `issuerCredentials` in another namespace is not a
  # candidate, so a self-signed issuer in cert-manager's namespace builds.
  cluster-issuers-foreign-credentials-ignored =
    let
      cluster = mkCluster [
        certManager
        {
          instances.other.cf-token = {
            package = secretPackage;
            aliases = [ "issuerCredentials" ];
            config.stringData.api-token = "token";
          };
        }
        (issuer "cert-manager" "selfsigned" { selfSigned = { }; } { })
      ];
    in
    issuerOf "selfsigned" cluster != null || throw "expected the self-signed issuer to build";

  # (g) Refusals: schema S (an unknown selector field, an unknown top-level
  # field, a missing acme.server), E1 (no type, two types), E2 (no
  # credentials), E3 (a literal Secret name), E4a (an undeclared key), E4b
  # (a selector with neither name nor key), E7 (http01 and dns01 in one
  # solver), and E8 (two DNS providers in one solver).
  cluster-issuers-refusals =
    let
      cases = {
        unknownSelectorField = acmeSpec [ (cloudflare // { selector.dnsZone = [ "example.com" ]; }) ];
        unknownTopLevel = {
          selfSigned = { };
          issuer = { };
        };
        missingServer.acme = removeAttrs (acme [ cloudflare ]) [ "server" ];
        noType = { };
        twoTypes = {
          selfSigned = { };
          acme = acme [ cloudflare ];
        };
        literalName = acmeSpec [
          { dns01.cloudflare.apiTokenSecretRef = tokenRef; }
        ];
        undeclaredKey = acmeSpec [
          { dns01.cloudflare.apiTokenSecretRef.key = "other"; }
        ];
        noKey = acmeSpec [
          { dns01.cloudflare.apiTokenSecretRef = { }; }
        ];
        twoChallenges = acmeSpec [ (cloudflare // { http01.ingress = { }; }) ];
        twoProviders = acmeSpec [
          {
            dns01 = cloudflare.dns01 // {
              digitalocean.tokenSecretRef.key = "api-token";
            };
          }
        ];
      };
      passed = builtins.attrNames (lib.filterAttrs (_: spec: !(failsWith spec)) cases);
      noCredentials = evalFails (mkCluster [
        certManager
        (issuer "cert-manager" "bad" (acmeSpec [ cloudflare ]) { })
      ]);
    in
    (passed == [ ] && noCredentials)
    || throw "expected every case to fail; these built: ${
      builtins.toJSON (passed ++ lib.optional (!noCredentials) "noCredentials")
    }";

  # (h) E5: an issuer outside cert-manager's namespace fails.
  cluster-issuers-namespace-refused =
    evalFails (mkCluster [
      certManager
      (issuer "other" "selfsigned" { selfSigned = { }; } { })
    ])
    || throw "expected an issuer in namespace other to fail";

  # (i) E5 with E2: the issuer in `other` finds no credentials, because the
  # namespace-scoped secret-ref in cert-manager is not a candidate there.
  cluster-issuers-namespace-refused-without-credentials =
    evalFails (mkCluster [
      certManager
      (credentials "cert-manager" [ "api-token" ] { aliases = [ "issuerCredentials" ]; })
      (issuer "other" "letsencrypt" (acmeSpec [ cloudflare ]) { })
    ])
    || throw "expected a DNS-01 issuer in namespace other to fail";

  # (j) An explicit cross-namespace issuerCredentials fails in the lib.
  cluster-issuers-cross-namespace-credentials-refused =
    evalFails (mkCluster [
      certManager
      (credentials "cert-manager" [ "api-token" ] { })
      (
        { ref, ... }:
        issuer "other" "letsencrypt" (acmeSpec [ cloudflare ]) {
          deps.issuerCredentials = ref.cert-manager.cf-token;
        }
      )
    ])
    || throw "expected an explicit cross-namespace issuerCredentials to fail";

  # (k) An HTTP-01 solver warns when an enforcer is present, and only then.
  cluster-issuers-http01-warns-under-enforcer =
    let
      withEnforcer = warningsOf [
        netpolOn
        http01Issuer
      ];
      without = warningsOf [ http01Issuer ];
    in
    (hasHttp01Warning withEnforcer && !(hasHttp01Warning without))
    || throw "expected the HTTP-01 warning only under an enforcer; with: ${builtins.toJSON withEnforcer}; without: ${builtins.toJSON without}";

  # (l) withCert adds the cluster-issuer annotation and keeps the others.
  cluster-issuers-with-cert =
    let
      consumer =
        { scope, ... }:
        {
          meta.version = "test";
          build =
            { self, clusterIssuer, ... }:
            {
              cm = scope.mkResource (
                clusterIssuer.out.withCert {
                  apiVersion = "v1";
                  kind = "ConfigMap";
                  name = "consumer";
                  annotations.keep = "yes";
                }
              );
              root = self.cm;
            };
        };
      cluster = mkCluster [
        certManager
        (issuer "cert-manager" "selfsigned" { selfSigned = { }; } { })
        { instances.apps.consumer.package = consumer; }
      ];
      annotations = (byName "consumer" (ofKind "ConfigMap" (manifests cluster))).metadata.annotations;
    in
    (
      annotations."cert-manager.io/cluster-issuer" or null == "selfsigned"
      && annotations.keep or null == "yes"
    )
    || throw "unexpected consumer annotations: ${builtins.toJSON annotations}";
}

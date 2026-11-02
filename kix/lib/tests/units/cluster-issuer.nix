# Tests for the cluster-issuer package: the rendered ClusterIssuer, the
# Secret key selector fill from `issuerCredentials`, the ACME account key
# default, the refusals checked against cert-manager's vendored CRD schema,
# the namespace rule, `out.http01SolverSelector` and the solver policy
# kix.expose writes from it, and `out.withCert`. cert-manager runs as instance `cert-manager` in namespace
# `cert-manager`. The refusal tests see only that evaluation fails, not which
# message it fails with.

{
  lib,
  eval,
  kixKeys,
  mkCluster,
  kixlib,
  containerBase,
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
  ]) { aliases = [ "clusterIssuer" ]; };
  dns01Issuer = issuer "cert-manager" "solver" (acmeSpec [ cloudflare ]) {
    aliases = [ "clusterIssuer" ];
  };

  # A Deployment and Service on 8080, exposed through ingress-nginx with TLS
  # from the `clusterIssuer` alias.
  backend = {
    meta.version = "test";
    build = [
      (
        {
          self,
          scope,
          kix,
          ...
        }:
        {
          deployment = scope.mkDeployment {
            name = "web";
            spec = {
              replicas = 1;
              selector.matchLabels = scope.selectorLabels;
              template = {
                metadata.labels = scope.selectorLabels;
                spec.containers = [
                  (
                    {
                      name = "web";
                      image = "web:1";
                      ports = [ { containerPort = 8080; } ];
                    }
                    // containerBase
                  )
                ];
              };
            };
          };
          service = self.deployment |> kix.service.fromWorkload { name = "web"; } |> scope.mkResource;
          root = self.service;
        }
      )
      (kixlib.expose { service = "service"; })
    ];
  };
  solverPolicyWith =
    issuerModule: extra:
    byName "web-acme-solver-from-ingress-controller" (
      ofKind "CiliumNetworkPolicy" (
        manifests (mkCluster [
          certManager
          netpolOn
          extra
          (credentials "cert-manager" [ "api-token" ] { aliases = [ "issuerCredentials" ]; })
          issuerModule
          {
            cluster.domain = "test.local";
            instances.ingress.ingress-nginx.package = import ../../../packages/ingress-nginx;
            instances.appns.web.package = backend;
          }
        ])
      )
    );
in
{
  # The spec renders as given, named after the instance.
  cluster-issuer-self-signed =
    let
      m = issuerOf "selfsigned" (mkCluster [
        certManager
        (issuer "cert-manager" "selfsigned" { selfSigned = { }; } { })
      ]);
    in
    (m != null && m.spec == { selfSigned = { }; } && m.apiVersion == "cert-manager.io/v1")
    || throw "expected ClusterIssuer selfsigned with spec { selfSigned = { }; }, got ${builtins.toJSON m}";

  # An explicit issuerCredentials fills the selector's name, and the
  # ClusterIssuer depends on the secret-ref marker.
  cluster-issuer-dns01-explicit-credentials =
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

  # A secret-ref aliased `issuerCredentials` in the same namespace
  # resolves without an explicit dependency.
  cluster-issuer-dns01-alias-credentials =
    tokenRefOf aliasCluster == tokenRef
    || throw "expected apiTokenSecretRef ${builtins.toJSON tokenRef}, got ${builtins.toJSON (tokenRefOf aliasCluster)}";

  # The ACME account key defaults to <instance>-acme-account-key; a
  # user-set `key` on it is kept and not treated as a credential selector.
  cluster-issuer-account-key-default =
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

  # A name marked with kix.untrackedRef is kept without a credentials
  # dependency.
  cluster-issuer-untracked-name-kept =
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

  # A Secret aliased `issuerCredentials` in another namespace is not a
  # candidate, so a self-signed issuer in cert-manager's namespace builds.
  cluster-issuer-foreign-credentials-ignored =
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

  # Each spec fails the build: an unknown selector field, an unknown
  # top-level field, a missing acme.server, a value of the wrong type
  # (solvers as an attribute set, a numeric server, a numeric key), no
  # issuer type (also when the only one is null), two issuer types, a
  # literal Secret name, a key the credentials Secret does not declare, a
  # selector with neither name nor key, a solver with both http01 and
  # dns01, and a dns01 solver with two providers. A DNS-01 issuer with no
  # credentials dependency fails as well.
  cluster-issuer-refusals =
    let
      cases = {
        unknownSelectorField = acmeSpec [ (cloudflare // { selector.dnsZone = [ "example.com" ]; }) ];
        unknownTopLevel = {
          selfSigned = { };
          issuer = { };
        };
        missingServer.acme = removeAttrs (acme [ cloudflare ]) [ "server" ];
        solversAsAttrs.acme = acme [ cloudflare ] // {
          solvers = cloudflare;
        };
        numericServer.acme = acme [ cloudflare ] // {
          server = 5;
        };
        numericKey = acmeSpec [ { dns01.cloudflare.apiTokenSecretRef.key = 5; } ];
        noType = { };
        nullType.selfSigned = null;
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

  # An issuer outside cert-manager's namespace fails.
  cluster-issuer-namespace-refused =
    evalFails (mkCluster [
      certManager
      (issuer "other" "selfsigned" { selfSigned = { }; } { })
    ])
    || throw "expected an issuer in namespace other to fail";

  # A DNS-01 issuer outside cert-manager's namespace fails, and finds no
  # credentials, because the namespace-scoped secret-ref in cert-manager is
  # not a candidate there.
  cluster-issuer-namespace-refused-without-credentials =
    evalFails (mkCluster [
      certManager
      (credentials "cert-manager" [ "api-token" ] { aliases = [ "issuerCredentials" ]; })
      (issuer "other" "letsencrypt" (acmeSpec [ cloudflare ]) { })
    ])
    || throw "expected a DNS-01 issuer in namespace other to fail";

  # An explicit cross-namespace issuerCredentials fails in the lib.
  cluster-issuer-cross-namespace-credentials-refused =
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

  # An HTTP-01 issuer publishes the solver pods' labels and no longer warns;
  # a DNS-01 issuer publishes null.
  cluster-issuer-http01-solver-selector =
    let
      outOf =
        issuerModule:
        (mkCluster [
          certManager
          (credentials "cert-manager" [ "api-token" ] { aliases = [ "issuerCredentials" ]; })
          issuerModule
        ]).instances.cert-manager.solver.out.http01SolverSelector;
      warnings = warningsOf [
        netpolOn
        http01Issuer
      ];
    in
    (
      outOf http01Issuer == {
        "acme.cert-manager.io/http01-solver" = "true";
      }
      && outOf dns01Issuer == null
      && !(builtins.any (lib.hasInfix "HTTP-01") warnings)
    )
    || throw "http01SolverSelector: ${builtins.toJSON (outOf http01Issuer)}; warnings ${builtins.toJSON warnings}";

  # kix.expose admits the ingress controller to the solver pods on 8089 in
  # the Ingress's namespace when the issuer solves HTTP-01, and writes
  # nothing for a DNS-01 issuer or where ingress is not enforced.
  cluster-issuer-expose-admits-http01-solver =
    let
      policy = solverPolicyWith http01Issuer { };
      rule = builtins.head policy.spec.ingress;
    in
    (
      policy.metadata.namespace == "appns"
      && policy.spec.endpointSelector.matchLabels == { "acme.cert-manager.io/http01-solver" = "true"; }
      && rule.callerNamespace == "ingress"
      &&
        rule.ports == [
          {
            port = 8089;
            protocol = "TCP";
          }
        ]
      && solverPolicyWith dns01Issuer { } == null
      && solverPolicyWith http01Issuer { networkPolicy.directions = "egress"; } == null
    )
    || throw "solver policy: ${builtins.toJSON policy}";

  # A certManager dependency answered by a kix.mkImport fails the build.
  cluster-issuer-imported-cert-manager-refused =
    evalFails (mkCluster [
      {
        instances.cert-manager.cm = {
          package = eval.mkImport { };
          aliases = [ "certManager" ];
        };
      }
      (issuer "cert-manager" "selfsigned" { selfSigned = { }; } { })
    ])
    || throw "expected an issuer whose certManager is an import to fail";

  # A field set to null is not rendered, and the null ACME account key is
  # filled as if it were absent.
  cluster-issuer-null-fields-dropped =
    let
      spec = specOf "letsencrypt" (
        wiredCluster { aliases = [ "issuerCredentials" ]; } {
          config.spec = {
            acme = acme [ cloudflare ] // {
              privateKeySecretRef = null;
            };
            selfSigned = null;
          };
        }
      );
    in
    (
      !(spec ? selfSigned) && spec.acme.privateKeySecretRef == { name = "letsencrypt-acme-account-key"; }
    )
    || throw "expected null fields to be dropped, got ${builtins.toJSON spec}";

  # withCert adds the cluster-issuer annotation and keeps the others.
  cluster-issuer-with-cert =
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

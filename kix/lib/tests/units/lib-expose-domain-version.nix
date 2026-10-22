# Tests for the kix.expose exposure record and Gateway listener matching,
# build-entry part collisions, helm-dag pickRoot, the cluster domain in
# subscopes, core/version.nix and the version checks in meta.nix, and the
# architecture.clusterDomainLiteral rule.

{
  lib,
  kixlib,
  eval,
  mkCluster,
  manifests,
  ofKind,
  namesOf,
  byName,
  evalFails,
  ...
}:

let
  versions = import ../../core/version.nix { inherit lib; };
  helmDag = import ../../helm-dag.nix { inherit lib; };
  normalize = import ../../core/normalize.nix { inherit lib; };
  rules = import ../../rules/architecture.nix { inherit lib; };
  envoyGatewayPackage = import ../../../packages/envoy-gateway;

  # A web Deployment and Service exposed through kix.expose. The Deployment
  # reads the record's `urlField` of the same instance into PUBLIC_URL.
  mkWebPackage =
    {
      exposeArgs ? { },
      extraEntries ? [ ],
      exposurePart ? "exposure",
      urlField ? "url",
    }:
    {
      meta.version = "test";
      options.ingress.host = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
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
                    {
                      name = "web";
                      image = "web:1";
                      ports = [
                        {
                          name = "http";
                          containerPort = 8080;
                        }
                      ];
                      env = kix.mkEnvVars { PUBLIC_URL = self.${exposurePart}.${urlField}; };
                    }
                  ];
                };
              };
            };
            service = self.deployment |> kix.service.fromWorkload { name = "web"; } |> scope.mkResource;
            root = self.service;
          }
        )
        (kixlib.expose ({ service = "service"; } // exposeArgs))
      ]
      ++ extraEntries;
    };

  stubIngressNginx = {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        class = scope.mkClusterResource {
          apiVersion = "networking.k8s.io/v1";
          kind = "IngressClass";
          name = "nginx";
          spec.controller = "k8s.io/ingress-nginx";
        };
        root = {
          resource = self.class;
          out.ingressClassName = self.class.out.name;
        };
      };
  };

  stubClusterIssuer = {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "issuer";
        };
        root = {
          resource = self.cm;
          out.withCert = lib.id;
        };
      };
  };

  # Builds a cluster with the web app in `appNs` and the given exposure
  # instances; `deps` names which of them the app is wired to.
  mkExposeCluster =
    {
      app ? mkWebPackage { },
      appNs ? "appns",
      appConfig ? { },
      gatewayConfig ? null,
      gatewayNs ? "gwns",
      gatewayPackage ? envoyGatewayPackage,
      ingress ? false,
      issuer ? false,
      domain ? "example.test",
    }:
    mkCluster (
      [
        (
          { ref, ... }:
          {
            cluster.domain = domain;
            instances.${appNs}.web = {
              package = app;
              config = appConfig;
              deps =
                lib.optionalAttrs (gatewayConfig != null) { gateway = ref.${gatewayNs}.gateway; }
                // lib.optionalAttrs ingress { ingressNginx = ref.ingressns.ingress-nginx; }
                // lib.optionalAttrs issuer { clusterIssuer = ref.issuerns.issuer; };
            };
          }
        )
      ]
      ++ lib.optional (gatewayConfig != null) {
        instances.${gatewayNs}.gateway = {
          package = gatewayPackage;
        }
        // lib.optionalAttrs (gatewayConfig != { }) { config = gatewayConfig; };
      }
      ++ lib.optional ingress { instances.ingressns.ingress-nginx.package = stubIngressNginx; }
      ++ lib.optional issuer { instances.issuerns.issuer.package = stubClusterIssuer; }
    );

  recordOf =
    {
      cluster,
      appNs ? "appns",
      part ? "exposure",
    }:
    cluster.instances.${appNs}.web.raw.${part};

  publicUrlEnv =
    cluster:
    let
      d = byName "web" (ofKind "Deployment" (manifests cluster));
      env = (builtins.head d.spec.template.spec.containers).env or [ ];
    in
    (lib.findFirst (e: e.name == "PUBLIC_URL") { value = null; } env).value;

  urlFor =
    args:
    (recordOf {
      cluster = mkExposeCluster args;
      appNs = args.appNs or "appns";
    }).url;

  httpAll = {
    name = "http";
    port = 80;
    protocol = "HTTP";
    allowedRoutes.namespaces.from = "All";
  };
  httpsAll = {
    name = "https";
    port = 443;
    protocol = "HTTPS";
    tls.certificateRefs = [ { name = "wildcard-tls"; } ];
    allowedRoutes.namespaces.from = "All";
  };

  failsWith = args: !(builtins.tryEval (builtins.deepSeq (urlFor args) true)).success;
  fails = v: !(builtins.tryEval (builtins.deepSeq v true)).success;

  # A kix.mkImport gateway: out.gatewayRef and no listeners.
  importedGateway = eval.mkImport {
    out.gatewayRef = {
      name = "shared";
      namespace = "gwns";
    };
  };

  # Cluster-level rule check with the given domain.
  domainRule =
    domain: resources:
    let
      rule = rules.clusterDomainLiteral;
      ctx = {
        allResources = resources;
        clusterConfig.clusterDomain = domain;
      };
    in
    if rule.appliesTo ctx then rule.check ctx else [ ];

  configMapWith = value: {
    apiVersion = "v1";
    kind = "ConfigMap";
    metadata = {
      name = "cfg";
      namespace = "app";
    };
    data.url = value;
  };

  # A package with meta constraints, and a dependency reporting `depVersion`.
  versionedDep = depVersion: {
    meta.version = depVersion;
    build =
      { self, scope, ... }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "dep";
        };
        root = self.cm;
      };
  };
  constrained = metaExtra: {
    meta = {
      version = "test";
    }
    // metaExtra;
    build =
      {
        self,
        scope,
        dep ? null,
        ...
      }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "constrained";
        };
        root = self.cm;
      };
  };
  diagnosticsOf =
    {
      metaExtra,
      depVersion ? null,
      k8sVersion ? null,
    }:
    let
      cluster = mkCluster (
        [
          (
            { ref, ... }:
            {
              inherit k8sVersion;
              instances.app.consumer = {
                package = constrained metaExtra;
              }
              // lib.optionalAttrs (depVersion != null) { deps.dep = ref.app.dep; };
            }
          )
        ]
        ++ lib.optional (depVersion != null) { instances.app.dep.package = versionedDep depVersion; }
      );
    in
    cluster.instances.app.consumer._diagnostics;
  hasWarning =
    infix: diag: builtins.any (w: lib.hasInfix infix w) diag.warnings && diag.failedAssertions == [ ];
  # A failed meta assertion fails the cluster before its diagnostics can be
  # read.
  diagnosticsFail = args: !(builtins.tryEval (builtins.deepSeq (diagnosticsOf args) true)).success;
  metaLib = import ../../meta.nix { inherit lib; };
  staticAssertions =
    { packageMeta, depVersion }:
    (metaLib.checkMetaStatic {
      inherit packageMeta;
      instanceName = "consumer";
      namespaceName = "app";
      clusterConfig.k8sVersion = null;
      resolvedDepMeta.dep.targets = [ { instance._meta.packageMeta.version = depVersion; } ];
      resolutionIndex.byKey = { };
    }).assertions;

  mkWorkload = kind: name: {
    inherit kind name;
  };
  pickFails = rs: !(builtins.tryEval (helmDag.pickRoot "rel" rs)).success;
in
{
  # The record: ingress with a cluster-issuer is https, without one http.
  # The Deployment of the same instance reads it without recursion.
  lib-expose-domain-version-record-ingress =
    let
      withIssuer = mkExposeCluster {
        ingress = true;
        issuer = true;
      };
      plain = mkExposeCluster { ingress = true; };
      r1 = recordOf { cluster = withIssuer; };
      r2 = recordOf { cluster = plain; };
    in
    (
      r1 == {
        _type = "kix-exposure";
        via = "ingress";
        host = "web.example.test";
        scheme = "https";
        url = "https://web.example.test";
        urlOrNull = "https://web.example.test";
      }
      && r2.url == "http://web.example.test"
      && publicUrlEnv withIssuer == "https://web.example.test"
      && publicUrlEnv plain == "http://web.example.test"
    )
    || throw "record (ingress): ${builtins.toJSON r1} / ${builtins.toJSON r2}";

  # With nothing wired, or no host, there is no route: `urlOrNull` is null
  # and reading `url` fails, also from a Deployment of the instance.
  lib-expose-domain-version-record-nothing-wired =
    let
      lenient = mkWebPackage { urlField = "urlOrNull"; };
      cluster = mkExposeCluster { app = lenient; };
      r = recordOf { inherit cluster; };
      noHost = recordOf {
        cluster = mkExposeCluster {
          app = lenient;
          ingress = true;
          domain = null;
        };
      };
    in
    (
      removeAttrs r [ "url" ] == {
        _type = "kix-exposure";
        via = null;
        host = null;
        scheme = null;
        urlOrNull = null;
      }
      && fails r.url
      && publicUrlEnv cluster == null
      && cluster.instances.appns.web.raw.route == null
      && noHost.via == null
      && noHost.urlOrNull == null
      && fails noHost.url
      && evalFails (mkExposeCluster { })
    )
    || throw "record with nothing wired: ${builtins.toJSON (removeAttrs r [ "url" ])}";

  lib-expose-domain-version-record-both-wired-fails = failsWith {
    ingress = true;
    gatewayConfig.listeners = [ httpAll ];
  };

  lib-expose-domain-version-record-config-host-wins =
    let
      r = recordOf {
        cluster = mkExposeCluster {
          ingress = true;
          appConfig.ingress.host = "app.other.test";
        };
      };
    in
    r.url == "http://app.other.test" || throw "config.ingress.host: ${builtins.toJSON r}";

  # deriveHost = false: with cluster.domain and an ingress controller but no
  # config.ingress.host there is no route and no error; with a host the
  # route renders. The default (deriveHost = true) still derives
  # <instance>.<cluster.domain>.
  lib-expose-domain-version-derive-host-off =
    let
      app = mkWebPackage {
        exposeArgs.deriveHost = false;
        urlField = "urlOrNull";
      };
      noHost = mkExposeCluster {
        inherit app;
        ingress = true;
      };
      noHostGateway = mkExposeCluster {
        inherit app;
        gatewayConfig.listeners = [ httpAll ];
      };
      withHost = mkExposeCluster {
        inherit app;
        ingress = true;
        appConfig.ingress.host = "app.other.test";
      };
      derived = mkExposeCluster { ingress = true; };
      rNoHost = recordOf { cluster = noHost; };
      rWithHost = recordOf { cluster = withHost; };
      ingressHosts =
        cluster: map (i: (builtins.head i.spec.rules).host) (ofKind "Ingress" (manifests cluster));
    in
    (
      rNoHost.via == null
      && rNoHost.host == null
      && rNoHost.urlOrNull == null
      && fails rNoHost.url
      && noHost.instances.appns.web.raw.route == null
      && ofKind "Ingress" (manifests noHost) == [ ]
      && publicUrlEnv noHost == null
      && (recordOf { cluster = noHostGateway; }).via == null
      && ofKind "HTTPRoute" (manifests noHostGateway) == [ ]
      && rWithHost.via == "ingress"
      && rWithHost.url == "http://app.other.test"
      && ingressHosts withHost == [ "app.other.test" ]
      && (recordOf { cluster = derived; }).url == "http://web.example.test"
      && ingressHosts derived == [ "web.example.test" ]
    )
    || throw "deriveHost = false: ${builtins.toJSON (removeAttrs rNoHost [ "url" ])} / ${
      builtins.toJSON (removeAttrs rWithHost [ "url" ])
    }";

  # Default part names are `route` and `exposure`; both arguments rename them.
  lib-expose-domain-version-part-names =
    let
      defaults = mkExposeCluster { ingress = true; };
      renamed = mkExposeCluster {
        ingress = true;
        app = mkWebPackage {
          exposeArgs = {
            partName = "web";
            exposurePart = "webExposure";
          };
          exposurePart = "webExposure";
        };
      };
      rawDefault = defaults.instances.appns.web.raw;
      rawRenamed = renamed.instances.appns.web.raw;
    in
    (
      rawDefault ? route
      && rawDefault ? exposure
      && !(rawDefault ? ingress)
      && rawRenamed ? web
      && rawRenamed ? webExposure
      && !(rawRenamed ? route)
      && (ofKind "Ingress" (manifests renamed)) != [ ]
      && publicUrlEnv renamed == "http://web.example.test"
    )
    || throw "part names: ${builtins.toJSON (builtins.attrNames rawDefault)} / ${builtins.toJSON (builtins.attrNames rawRenamed)}";

  # A second kix.expose with default names collides on `route` and
  # `exposure`.
  lib-expose-domain-version-two-exposes-collide = evalFails (mkExposeCluster {
    ingress = true;
    app = mkWebPackage { extraEntries = [ (kixlib.expose { service = "service"; }) ]; };
  });

  # Gateway listener matching.
  lib-expose-domain-version-listener-http =
    let
      url = urlFor { gatewayConfig.listeners = [ httpAll ]; };
    in
    url == "http://web.example.test" || throw "HTTP All: ${toString url}";

  lib-expose-domain-version-listener-prefers-https =
    let
      url = urlFor {
        gatewayConfig.listeners = [
          httpAll
          httpsAll
        ];
      };
    in
    url == "https://web.example.test" || throw "HTTP and HTTPS: ${toString url}";

  lib-expose-domain-version-listener-port =
    let
      url = urlFor { gatewayConfig.listeners = [ (httpAll // { port = 8080; }) ]; };
    in
    url == "http://web.example.test:8080" || throw "HTTP on 8080: ${toString url}";

  lib-expose-domain-version-listener-wildcard-hostname =
    let
      wildcard = [ (httpAll // { hostname = "*.example.com"; }) ];
      url = urlFor {
        gatewayConfig.listeners = wildcard;
        appConfig.ingress.host = "a.example.com";
      };
    in
    (
      url == "http://a.example.com"
      && failsWith {
        gatewayConfig.listeners = wildcard;
        appConfig.ingress.host = "example.com";
      }
    )
    || throw "wildcard hostname: ${toString url}";

  # allowedRoutes unset means Same: a route from another namespace does
  # not attach, a route from the Gateway's namespace does.
  lib-expose-domain-version-listener-same-namespace =
    let
      unset = [ (removeAttrs httpAll [ "allowedRoutes" ]) ];
      url = urlFor {
        gatewayConfig.listeners = unset;
        appNs = "gwns";
      };
    in
    (url == "http://web.example.test" && failsWith { gatewayConfig.listeners = unset; })
    || throw "allowedRoutes unset: ${toString url}";

  # Selector is not evaluated: the listener is chosen with a warning, and a
  # verified listener wins over it even when it is HTTPS.
  lib-expose-domain-version-listener-selector =
    let
      selector = {
        namespaces = {
          from = "Selector";
          selector.matchLabels.team = "web";
        };
      };
      selectorOnly = urlFor {
        gatewayConfig.listeners = [ (httpsAll // { allowedRoutes = selector; }) ];
      };
      mixed = urlFor {
        gatewayConfig.listeners = [
          (httpsAll // { allowedRoutes = selector; })
          httpAll
        ];
      };
    in
    (selectorOnly == "https://web.example.test" && mixed == "http://web.example.test")
    || throw "Selector: ${toString selectorOnly} / ${toString mixed}";

  lib-expose-domain-version-listener-imported-gateway =
    let
      r = recordOf {
        cluster = mkExposeCluster {
          app = mkWebPackage { urlField = "urlOrNull"; };
          gatewayConfig = { };
          gatewayPackage = importedGateway;
        };
      };
    in
    (
      r.via == "gateway"
      && r.host == "web.example.test"
      && r.scheme == null
      && r.urlOrNull == null
      && fails r.url
      && evalFails (mkExposeCluster {
        app = mkWebPackage { };
        gatewayConfig = { };
        gatewayPackage = importedGateway;
      })
    )
    || throw "imported gateway: ${builtins.toJSON (removeAttrs r [ "url" ])}";

  # envoy-gateway's listeners are typed: a misspelt field or a lower-case
  # protocol fails, and the defaults render the Gateway spec as before
  # (the certificate-less HTTPS placeholder is dropped).
  lib-expose-domain-version-envoy-listeners-typed =
    let
      gatewayOf =
        listeners:
        byName "gateway" (
          ofKind "Gateway" (
            manifests (mkCluster [
              {
                instances.gwns.gateway = {
                  package = envoyGatewayPackage;
                  config = lib.optionalAttrs (listeners != null) { inherit listeners; };
                };
              }
            ])
          )
        );
      defaultSpec = (normalize.normalizeManifest (gatewayOf null)).spec.listeners;
      fails = listeners: !(builtins.tryEval (builtins.deepSeq (gatewayOf listeners) true)).success;
    in
    (
      defaultSpec == [ httpAll ]
      && fails [ (httpAll // { hostName = "a.example.com"; }) ]
      && fails [ (httpAll // { protocol = "http"; }) ]
    )
    || throw "envoy-gateway listeners: ${builtins.toJSON defaultSpec}";

  # Two build entries that define the same part fail; partsOverlays may
  # still replace one.
  lib-expose-domain-version-build-entries-collide =
    let
      entry =
        { scope, ... }:
        {
          x = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "x";
          };
        };
      package = {
        meta.version = "test";
        build = [
          entry
          entry
          (
            { self, ... }:
            {
              root = self.x;
            }
          )
        ];
      };
    in
    evalFails (mkCluster [ { instances.app.dup.package = package; } ]);

  # pickRoot: one Service wins; no Service and one workload wins; anything
  # else throws.
  lib-expose-domain-version-pick-root =
    let
      svcA = mkWorkload "Service" "a";
      svcB = mkWorkload "Service" "b";
      deploy = mkWorkload "Deployment" "d";
      sts = mkWorkload "StatefulSet" "s";
      cm = mkWorkload "ConfigMap" "c";
    in
    (
      helmDag.pickRoot "rel" [
        cm
        svcA
        deploy
      ] == svcA
      &&
        helmDag.pickRoot "rel" [
          cm
          deploy
        ] == deploy
      && pickFails [
        svcA
        svcB
      ]
      && pickFails [
        deploy
        sts
      ]
      && pickFails [ cm ]
    )
    || throw "pickRoot";

  # A Service built through scope.forNamespace gets the cluster's domain.
  lib-expose-domain-version-subscope-domain =
    let
      package = {
        meta.version = "test";
        build =
          { self, scope, ... }:
          {
            cm = scope.mkResource {
              apiVersion = "v1";
              kind = "ConfigMap";
              name = "planter";
            };
            planted = (scope.forNamespace "other").mkResource {
              apiVersion = "v1";
              kind = "Service";
              name = "planted";
              spec.ports = [ { port = 80; } ];
            };
            root = {
              resource = self.cm;
              requires = [ self.planted ];
            };
          };
      };
      cluster = mkCluster [
        {
          clusterDomain = "corp.test";
          namespaces.other = { };
          instances.app.planter.package = package;
        }
      ];
      fqdn = builtins.unsafeDiscardStringContext cluster.instances.app.planter.raw.planted.out.fqdn;
    in
    lib.hasSuffix ".svc.corp.test" fqdn || throw "subscope fqdn: ${fqdn}";

  # Version grammar and ordering.
  lib-expose-domain-version-versions =
    let
      c = versions.compare;
    in
    (
      c "v1.2.3" "1.2.3" == 0
      && c "1.31" "1.31.0" == 0
      && c "1.2.3-rc.1" "1.2.3" == -1
      && c "1.2.3-alpha" "1.2.3-alpha.1" == -1
      && c "1.2.3-alpha.1" "1.2.3-beta" == -1
      && c "1.0.0-rc2" "1.0.0-rc10" == -1
      && c "1.31.2+rke2r1" "1.31.2" == 0
      && c "1.31.2-gke.1209000" "1.31.2" == 0
      && c "v1.31.2-eks-7f9249a" "1.31.2" == 0
      && c "2.10.0-cf" "2.10.0" == 0
      && c "v1.32.0-rc.1" "1.31.9" == 1
      && c "v1.32.0-rc.1" "1.32.0" == -1
      && !(versions.isVersion "external")
      && !(builtins.tryEval (versions.parse "external")).success
    )
    || throw "version ordering";

  # Constraints compare at their own precision; a less precise version is
  # unknown (null).
  lib-expose-domain-version-precision =
    (
      versions.atMost "1.30.4" "1.30" == true
      && versions.atMost "1.31.0" "1.30" == false
      && versions.atLeast "1.30.0" "1.30" == true
      && versions.atLeast "1.30.0-rc.1" "1.30" == true
      && versions.atLeast "1.31" "1.31.2" == null
      && versions.atLeast "1.31.2-rc.1" "1.31.2" == false
    )
    || throw "constraint precision";

  # meta.k8s and meta.compatibleWith: unknown warns, false fails, an
  # unparseable constraint fails, and k8sVersion is typed.
  lib-expose-domain-version-meta-checks =
    let
      k8sImprecise = diagnosticsOf {
        metaExtra.k8s.minVersion = "1.31.2";
        k8sVersion = "1.31";
      };
      k8sTooOld = diagnosticsFail {
        metaExtra.k8s.minVersion = "1.31";
        k8sVersion = "v1.30.9-gke.1";
      };
      depWord = diagnosticsOf {
        metaExtra.compatibleWith.dep.minVersion = "1.0";
        depVersion = "external";
      };
      depOk = diagnosticsOf {
        metaExtra.compatibleWith.dep.minVersion = "1.0";
        depVersion = "v1.18.4";
      };
      badConstraint = staticAssertions {
        packageMeta.compatibleWith.dep.minVersion = "abc";
        depVersion = "1.0.0";
      };
      badK8s = diagnosticsFail {
        metaExtra.k8s.minVersion = "1.30";
        k8sVersion = "latest";
      };
    in
    (
      hasWarning "less precise than minVersion" k8sImprecise
      && k8sTooOld
      && hasWarning "which is not a version number" depWord
      && depOk.failedAssertions == [ ]
      && !(builtins.any (lib.hasInfix "cannot check") depOk.warnings)
      && builtins.any (
        a: !a.assertion && lib.hasInfix "minVersion \"abc\" is not a version" a.message
      ) badConstraint
      && badK8s
    )
    || throw "meta checks: ${
      builtins.toJSON {
        inherit k8sImprecise depWord badConstraint;
      }
    }";

  # The rule finds cluster.local on a cluster with another domain, as whole
  # labels only (also at either end of the string), outside CRDs, and stays
  # silent on the default domain. The message quotes the first whole-label
  # hit with its surroundings.
  lib-expose-domain-version-domain-rule =
    let
      crd = configMapWith "a.b.svc.cluster.local" // {
        kind = "CustomResourceDefinition";
      };
      messageFor = v: (builtins.head (domainRule "corp.test" [ (configMapWith v) ])).message;
      quoted = v: lib.hasInfix "contains \"${v}\"" (messageFor v);
    in
    (
      builtins.length (domainRule "corp.test" [ (configMapWith "a.b.svc.cluster.local") ]) == 1
      && builtins.length (domainRule "corp.test" [ (configMapWith "cluster.local") ]) == 1
      && builtins.length (domainRule "corp.test" [ (configMapWith "cluster.local:53") ]) == 1
      && quoted "x.svc.corp.test mycluster.local a.svc.cluster.local:53"
      && quoted "cluster.local"
      && lib.hasInfix "contains \"line\\na.svc.cluster.local\\n\"" (
        messageFor "line\na.svc.cluster.local\n"
      )
      && domainRule "corp.test" [ (configMapWith "mycluster.local") ] == [ ]
      && domainRule "corp.test" [ (configMapWith "cluster.localhost") ] == [ ]
      && domainRule "corp.test" [ crd ] == [ ]
      && domainRule "east.cluster.local" [ (configMapWith "a.svc.east.cluster.local") ] == [ ]
      && domainRule "cluster.local" [ (configMapWith "a.b.svc.cluster.local") ] == [ ]
    )
    || throw "clusterDomainLiteral";
}

# Tests for the two Helm routes in helm.nix and for importing a chart from
# a render. Nix cannot build a placeholder, so these read the spec a
# placeholder carries, and import charts through a stub `readRender` that
# returns a fixed resource list instead of a Helm render. The nix route gets
# a stub nixpkgs whose derivations are never built.
# Loaded by ../default.nix with the other files in this directory.

{
  lib,
  mkCluster,
  baseInstances,
  manifests,
  byName,
  hasName,
  ...
}:

let
  releases = lib.mapAttrs (_: r: r.version) (lib.importJSON ../../helm-versions.json);
  newest = toString (lib.foldl' lib.max 0 (map lib.toInt (builtins.attrNames releases)));

  helm = import ../../helm.nix { inherit lib; };

  chart = "/nix/store/00000000000000000000000000000000-chart";

  specOf = drv: builtins.fromJSON drv.kixHelmSpec;

  render = helm.helmTemplateDerivation {
    inherit chart;
    releaseName = "web";
    namespace = "apps";
    values.replicas = 2;
  };

  # A value with string context, as a dependency's `out` attribute has.
  contextValue = "${builtins.toFile "dep" "dep"}";

  # A render as `kix` writes it: one element per YAML document, so it holds
  # an empty document and may hold a List.
  stubResources = [
    null
    {
      apiVersion = "v1";
      kind = "List";
      items = [
        {
          apiVersion = "v1";
          kind = "ConfigMap";
          metadata.name = "stub-config";
          data.key = "value";
        }
      ];
    }
    {
      apiVersion = "v1";
      kind = "Pod";
      metadata = {
        name = "stub-test";
        annotations."helm.sh/hook" = "test";
      };
      spec.containers = [
        {
          name = "t";
          image = "busybox";
        }
      ];
    }
    {
      apiVersion = "apiextensions.k8s.io/v1";
      kind = "CustomResourceDefinition";
      metadata.name = "widgets.example.com";
      spec = {
        group = "example.com";
        names = {
          kind = "Widget";
          plural = "widgets";
        };
        scope = "Namespaced";
        versions = [
          {
            name = "v1";
            served = true;
            storage = true;
            schema.openAPIV3Schema.type = "object";
          }
        ];
      };
    }
  ];

  # Enough of nixpkgs for the nix route to create its derivations. Each is a
  # plain `derivation`, so it has a real store path, and `passthru` shows
  # through as with nixpkgs' own `runCommand`.
  stubPkgs = {
    stdenv.hostPlatform.system = "x86_64-linux";
    cacert = "cacert";
    yq-go = "yq-go";
    fetchurl =
      { url, sha256 }:
      derivation {
        name = baseNameOf url;
        system = "x86_64-linux";
        builder = "/bin/sh";
        outputHashAlgo = "sha256";
        outputHash = sha256;
        outputHashMode = "flat";
      };
    runCommand =
      name: env: script:
      derivation (
        builtins.removeAttrs env [ "passthru" ]
        // {
          inherit name;
          system = "x86_64-linux";
          builder = "/bin/sh";
          args = [
            "-c"
            script
          ];
        }
      )
      // (env.passthru or { });
  };

  nixHelm = import ../../helm.nix {
    inherit lib;
    pkgs = stubPkgs;
    helmRoute = "nix";
  };

  fetchArgs = {
    repo = "https://charts.example.com";
    name = "web";
    version = "1.2.3";
    hash = "sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=";
  };

  stubHelm = import ../../helm.nix {
    inherit lib;
    readRender = _: stubResources;
  };

  chartPackage = {
    meta.version = "test";
    build =
      { scope, ... }:
      let
        resources = stubHelm.importChart {
          inherit chart scope;
          releaseName = "stub";
        };
      in
      resources.mkParts {
        root = resources.get "ConfigMap" "stub-config";
      };
  };

  crdPackage = {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        crd = builtins.head (stubHelm.importChartCrds { inherit chart scope; });
        root = self.crd;
      };
  };

  importedWith =
    package:
    manifests (mkCluster [
      baseInstances
      { instances.infra.chart.package = package; }
    ]);

  imported = importedWith chartPackage;
in
{
  helm-render-is-a-placeholder = render.system == "kix-helm" || throw "system: ${render.system}";

  helm-render-spec-names-the-newest-helm =
    specOf render == {
      specVersion = 1;
      helm = releases.${newest};
      inherit chart;
      releaseName = "web";
      namespace = "apps";
      includeCrds = true;
      includeHooks = true;
      kubeVersion = null;
      extraFlags = [ ];
      values = ''{"replicas":2}'';
    }
    || throw "spec: ${render.kixHelmSpec}";

  helm-render-spec-names-the-chosen-major =
    let
      spec = specOf (
        helm.helmTemplateDerivation {
          inherit chart;
          helmVersion = "3";
        }
      );
    in
    spec.helm == releases."3" || throw "helm: ${spec.helm}";

  helm-render-refuses-an-unknown-major =
    !(builtins.tryEval
      (helm.helmTemplateDerivation {
        inherit chart;
        helmVersion = "2";
      }).kixHelmSpec
    ).success;

  # A dependency's output changing must not re-render the chart.
  helm-render-values-carry-no-context =
    let
      drv = helm.helmTemplateDerivation {
        inherit chart;
        values.endpoint = contextValue;
      };
    in
    (builtins.getContext drv.kixHelmSpec == { })
    || throw "context: ${builtins.toJSON (builtins.getContext drv.kixHelmSpec)}";

  helm-fetch-is-a-fixed-output-placeholder =
    let
      drv = helm.fetchHelmChart {
        repo = "https://charts.example.com";
        name = "web";
        version = "1.2.3";
        hash = "sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=";
      };
    in
    (
      drv.system == "kix-helm"
      && drv.name == "helm-chart-web-1.2.3"
      && drv.outputHashMode == "flat"
      &&
        builtins.fromJSON drv.kixHelmFetch == {
          specVersion = 1;
          helm = releases.${newest};
          repo = "https://charts.example.com";
          name = "web";
          version = "1.2.3";
        }
    )
    || throw "fetch: ${drv.kixHelmFetch}";

  # The nix route passes the flags the spec holds, each extra flag as one
  # argument however many spaces it has.
  helm-render-nix-route-passes-the-spec =
    let
      drv = nixHelm.helmTemplateDerivation {
        inherit chart;
        releaseName = "web";
        namespace = null;
        includeHooks = false;
        kubeVersion = "1.31.0";
        extraFlags = [
          "--set"
          "greeting=hello world"
        ];
        values.replicas = 2;
      };
      expected = [
        "template"
        "web"
        chart
        "--values"
        "values.json"
        "--include-crds"
        "--no-hooks"
        "--kube-version"
        "1.31.0"
        "--set"
        "greeting=hello world"
      ];
    in
    (
      drv.helmArgs == expected
      && lib.hasInfix "helm ${lib.escapeShellArgs expected}" (builtins.elemAt drv.args 1)
      && lib.hasInfix "'greeting=hello world'" (builtins.elemAt drv.args 1)
      && drv.values == ''{"replicas":2}''
      && drv.name == render.name
    )
    || throw "args: ${builtins.toJSON drv.helmArgs}";

  # The nix route writes the namespace flag when the spec has one, and
  # leaves out --no-hooks and --kube-version when the spec asks for neither.
  helm-render-nix-route-defaults =
    let
      drv = nixHelm.helmTemplateDerivation {
        inherit chart;
        releaseName = "web";
        namespace = "apps";
      };
    in
    drv.helmArgs == [
      "template"
      "web"
      chart
      "--values"
      "values.json"
      "--namespace"
      "apps"
      "--include-crds"
    ]
    || throw "args: ${builtins.toJSON drv.helmArgs}";

  # A chart has one store path whichever route fetches it.
  helm-fetch-has-one-path-under-both-routes =
    let
      placeholder = helm.fetchHelmChart fetchArgs;
      real = nixHelm.fetchHelmChart fetchArgs;
    in
    (placeholder.outPath == real.outPath && real.outputHashMode == "flat")
    || throw "placeholder ${placeholder.outPath}, nix ${real.outPath}";

  helm-fetch-nix-route-pulls-like-the-cli =
    let
      oci = nixHelm.fetchHelmChart (fetchArgs // { repo = "oci://registry.example.com/charts/"; });
    in
    (
      (nixHelm.fetchHelmChart fetchArgs).helmArgs == [
        "pull"
        "web"
        "--repo"
        "https://charts.example.com"
        "--version"
        "1.2.3"
        "--destination"
        "pull"
      ]
      && builtins.head (builtins.tail oci.helmArgs) == "oci://registry.example.com/charts/web"
    )
    || throw "args: ${builtins.toJSON oci.helmArgs}";

  helm-nix-route-needs-pkgs =
    let
      noPkgs = import ../../helm.nix {
        inherit lib;
        helmRoute = "nix";
      };
    in
    !(builtins.tryEval (noPkgs.helmTemplateDerivation { inherit chart; }).drvPath).success
    && !(builtins.tryEval (noPkgs.fetchHelmChart fetchArgs).drvPath).success;

  helm-import-crds-keeps-only-crds =
    let
      ms = importedWith crdPackage;
    in
    (hasName "widgets.example.com" ms && !(hasName "stub-config" ms))
    || throw "imported: ${builtins.toJSON (map (m: m.metadata.name or null) ms)}";

  # Lists expand, and empty documents and test hooks drop out.
  helm-import-reads-the-render =
    let
      config = byName "stub-config" imported;
      crd = byName "widgets.example.com" imported;
    in
    (
      config != null
      && config.data.key == "value"
      && !(hasName "stub-test" imported)
      && crd != null
      && !(crd.metadata ? namespace)
    )
    || throw "imported: ${builtins.toJSON (map (m: m.metadata.name or null) imported)}";
}

# Shared constants, CRD metadata, and helpers for the external-secrets package.

{
  lib,
  kix,
  scope,
}:

rec {
  # The upstream release: meta.version, the default image.tag, and the CRD
  # tag in crds/sources.txt (kix-lib test external-secrets-sources-match-release).
  release = "v2.11.0";

  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "external-secrets ${ns}/${name}";

  ports = {
    metrics = 8080;
    webhookHealth = 8081;
    controllerHealth = 8082;
    webhook = 10250;
  };

  # The Service the webhook entries call, and the name its serving
  # certificate is issued for. The cert-controller args and the entries do
  # not read the Service's `out.name`: the Service selects the webhook pods,
  # which wait for the certificate the cert-controller writes, so the
  # reference would order the cert-controller after those pods.
  webhookServiceName = "${name}-webhook";
  certDir = "/tmp/certs";

  # The controller-runtime leader election IDs, the controller's from its
  # `--leader-election-id` default and the cert-controller's compiled in
  # (cmd/controller/certcontroller.go).
  controllerLeaseName = "external-secrets-controller";
  certControllerLeaseName = "crd-certs-controller";

  webhookConfigNames = [
    "${name}-secretstore-validate"
    "${name}-externalsecret-validate"
  ];

  labelsFor = component: scope.selectorLabels // { "app.kubernetes.io/component" = component; };

  controllerLabels = labelsFor "controller";
  webhookLabels = labelsFor "webhook";
  certControllerLabels = labelsFor "cert-controller";

  podSecurityContext = {
    runAsNonRoot = true;
    seccompProfile.type = "RuntimeDefault";
  };

  containerSecurityContext = {
    allowPrivilegeEscalation = false;
    capabilities.drop = [ "ALL" ];
    readOnlyRootFilesystem = true;
  };

  subjectsFor = sa: [
    {
      kind = "ServiceAccount";
      name = sa.out.name;
      namespace = ns;
    }
  ];

  serviceAccount =
    saName:
    scope.mkResource {
      apiVersion = "v1";
      kind = "ServiceAccount";
      name = saName;
    };

  metricsServiceFor =
    hasMetrics: workload: labels:
    if hasMetrics then
      workload
      |> kix.service.fromWorkload {
        name = "${workload.out.name}-metrics";
        inherit labels;
        ports = [
          {
            name = "metrics";
            port = ports.metrics;
            targetPort = "metrics";
            protocol = "TCP";
          }
        ];
      }
      |> scope.mkResource
    else
      null;

  crdFiles = builtins.attrNames (
    lib.filterAttrs (f: type: type == "regular" && lib.hasSuffix ".json" f) (builtins.readDir ./crds)
  );
  crdDocs = map (f: builtins.fromJSON (builtins.readFile ./crds/${f})) crdFiles;
  crdSpecs = map (doc: doc.spec) crdDocs;
  kindOf = spec: spec.names.kind;
  pluralOf = spec: spec.names.plural;
  isGenerator = spec: spec.group == "generators.external-secrets.io";

  # The kinds whose provider the controller dials.
  storeKinds = [
    "ClusterSecretStore"
    "SecretStore"
  ];

  # Every kind with status conditions sets Ready to True on success
  # (apis/externalsecrets/v1/*_types.go, apis/externalsecrets/v1alpha1/pushsecret_types.go,
  # apis/generators/v1alpha1/generator_state_types.go). ClusterPushSecret
  # reports PushSecret's condition type.
  readyKinds = [
    "ClusterExternalSecret"
    "ClusterPushSecret"
    "ClusterSecretStore"
    "ExternalSecret"
    "GeneratorState"
    "PushSecret"
    "SecretStore"
  ];

  # Kinds the builders cover, and the kind the controller writes itself.
  unexposedKinds = [
    "ClusterSecretStore"
    "ExternalSecret"
    "GeneratorState"
    "SecretStore"
  ];

  partOf = kind: pluralOf (lib.findFirst (s: kindOf s == kind) null crdSpecs);
  crdOf = self: kind: self.crds.${partOf kind};

  # "v2.11.0" -> [ "2" "11" ".0" ]; null when the tag is not a version.
  versionParts = tag: builtins.match "v?([0-9]+)\\.([0-9]+)(\\..*)?" tag;
  releaseMinor = lib.take 2 (versionParts release);
  releaseMinorText = lib.concatStringsSep "." releaseMinor;
}

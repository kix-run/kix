# Kix's Kubernetes domain and all annotation, label, and API names built on it.
#
# Keep `domain` in sync with `cli/kix-core/src/manifest/keys.rs` (enforced by the
# `no_other_file_spells_a_kix_domain` Rust test). Packages access these keys
# through `kix.keys`.
rec {
  # DNS domain prefix for Kix annotations and labels, and the API group for
  # Kix CRDs.
  domain = "kix.run";

  group = domain;

  apiVersion = "${group}/v1alpha1";

  # Return a domain-prefixed annotation or label key.
  key = name: "${domain}/${name}";

  # Retired Kix domains kept reserved by the scorecard so legacy annotations
  # are not flagged as unowned. Keep in sync with `DOMAINS` in
  # `cli/kix/src/legacy_domain/`.
  legacyDomains = [ "kix.dev" ];

  keys = {
    # Stamped by the CLI at load time, not here. Listed so the checkers and
    # the tests that read them have a name to use.
    identityHash = key "identity-hash";
    package = key "package";
    packageNamespace = key "package-namespace";
    lifecycle = key "lifecycle";
    builtVia = key "built-via";

    # Written to live objects after apply, by the CLI.
    activations = key "activations";
    appliedHash = key "applied-hash";

    # Records: Activation and PackageInstance.
    root = key "root";
    inverseDeps = key "inverse-deps";
    packageRequires = key "package-requires";
    postHooks = key "post-hooks";
    previous = key "previous";
    deployedAt = key "deployed-at";
    # A label, not an annotation, so records list per cluster.
    clusterLabel = key "cluster";
    # Label on the Activation record of a build whose definition sets
    # `cluster.kubernetes.uid`: the UID of the target cluster's kube-system
    # Namespace. A label so deploys can list the records that carry one.
    kubernetesUidLabel = key "kubernetes-uid";
    # Label on each namespace rendered by a consumer cluster so platform
    # ingress rules can select the consumer's namespaces.
    consumerLabel = key "consumer";
    mode = key "mode";

    # Import markers.
    importKind = key "import-kind";
    importApiVersion = key "import-apiversion";
    importName = key "import-name";
    importFqdn = key "import-fqdn";
    importSecretKeys = key "import-secret-keys";
    # Stamped on CRD ref markers (`scope.mkCRDRef` and `mkImport` `crds`) to
    # record the kind, default version, comma-separated served versions, and
    # scope (`Namespaced` or `Cluster`) for check 21 and the deploy engine.
    crdKind = key "crd-kind";
    crdVersion = key "crd-version";
    crdServedVersions = key "crd-served-versions";
    crdScope = key "crd-scope";
    serviceSelector = key "service-selector";
    servicePorts = key "service-ports";
    serviceLabels = key "service-labels";

    # "true" or "false": whether the object holds data that removing it can
    # lose. `mkResource` writes it from the kind's `holdsData` declaration on
    # `scope.mkCRD` or `scope.mkCRDRef`, or from the shape of a built-in kind
    # (`holdsDataOf`). Migration pair detection reads it.
    holdsData = key "holds-data";

    # Graph and deploy behaviour.
    dependsOn = key "depends-on";
    readiness = key "readiness";
    rerun = key "rerun";
    # The resource's `out.contentHash`. `mkResource` writes it on every
    # resource that carries `rerun`, and the deploy engine compares it to
    # decide whether a Job runs again.
    rerunHash = key "rerun-hash";
    # Field paths a resource cedes to another manager after creation.
    cedeFields = key "cede-fields";
    # Comma-separated `apiVersion|Kind|name` entries for external objects that
    # deploy waits for before applying this resource.
    expects = key "expects";

    # Secrets.
    sopsSource = key "sops-source";
    # The SHA-256 of the encrypted SOPS file, in hex. The deploy checks the
    # file against it before decrypting.
    sopsDigest = key "sops-digest";
    secretKeys = key "secret-keys";
    # Comma-separated `key=source` pairs (`*=controller` when a controller
    # populates the whole Secret) read by the `security.secretSource` rule.
    secretSources = key "secret-sources";
    secretType = key "secret-type";
    classification = key "classification";
    rotationPolicy = key "rotation-policy";

    # Derived policy and package claims.
    derived = key "derived";
    policyType = key "policy-type";
    operandOf = key "operand-of";
    monitorsExternalService = key "monitors-external-service";
    role = key "role";
    dbCluster = key "db-cluster";
    autoInstantiated = key "auto-instantiated";
    optionalActivated = key "optional-activated";
  };

  # Kix annotations that stand for data Kix writes into the object at deploy
  # time. `out.contentHash` leaves out every other `kix.run/*` key, so these
  # are the only ones that change it.
  contentKeys = [ keys.sopsDigest ];

  # Values Kix gives its own keys, where more than one module compares them.
  values = {
    # Instructs the deploy engine to delete and recreate a Job instead of
    # patching it when the manifest changes or the previous run failed.
    # Stamped by `kix.healthCheck` and validated by check 16.
    rerunOnChange = "on-change";

    # A PackageInstance in this mode is a marker for a resource Kix
    # references but does not own.
    importMode = "import";
  };
}

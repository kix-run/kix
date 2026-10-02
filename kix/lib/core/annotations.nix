# The Kubernetes domain Kix owns, and every annotation, label and API name
# built on it.
#
# ## One literal
#
# The domain is spelled exactly once, in `domain` below. Every key is built
# from it, so a rename is a one-line change here. The Rust half is
# `cli/kix/src/manifest/keys.rs`, which holds the same one literal and whose
# `no_other_file_spells_a_kix_domain` test fails if any other Nix or Rust file
# in `kix/` or `cli/` spells a Kix domain.
#
# ## Using it
#
# Inside `kix/lib`, `import ../core/annotations.nix` (adjust the path).
# Inside a package, the keys arrive as `kix.keys`:
#
#     annotations.${kix.keys.derived} = "true";
#
# Centralizing keys keeps helpers and checkers aligned.
rec {
  # The DNS domain that prefixes every key Kix stamps, and the group of the
  # CRDs Kix owns. The one literal.
  domain = "kix.run";

  # The API group of the Activation and PackageInstance CRDs. The same string
  # as `domain`; named separately because the two roles are separate.
  group = domain;

  # `group/version` of Kix's own records.
  apiVersion = "${group}/v1alpha1";

  # Build a key: `key "identity-hash"`.
  key = name: "${domain}/${name}";

  # Domains Kix has stamped and retired. The scorecard keeps reserving them,
  # so an object a previous Kix stamped, or a helm chart that copied one of
  # its keys, is not reported as writing under a domain nobody owns. The Rust
  # half is `DOMAINS` in `cli/kix/src/legacy_domain/`. Both go together; the
  # checklist is in `v2_discussions/archive/137_kix_run_domain_migration.md`.
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
    mode = key "mode";

    # Import markers.
    importKind = key "import-kind";
    importApiVersion = key "import-apiversion";
    importName = key "import-name";
    importFqdn = key "import-fqdn";
    importSecretKeys = key "import-secret-keys";
    # On CRD ref markers only (scope.mkCRDRef, mkImport crds): the kind, the
    # default API version (the declaration's `version`) and the scope
    # (`Namespaced` or `Cluster`) of the referenced CRD. `crd-served-versions`
    # (comma separated) is stamped only when the declaration's
    # `servedVersions` lists more than `version`; without it the served list
    # is `crd-version` alone. Check 21 and the deploy read both.
    crdKind = key "crd-kind";
    crdVersion = key "crd-version";
    crdServedVersions = key "crd-served-versions";
    crdScope = key "crd-scope";
    serviceSelector = key "service-selector";
    servicePorts = key "service-ports";
    serviceLabels = key "service-labels";

    # Graph and deploy behaviour.
    dependsOn = key "depends-on";
    readiness = key "readiness";
    rerun = key "rerun";
    # Field paths a resource cedes to another manager after creation.
    cedeFields = key "cede-fields";
    # Objects this resource expects something else to have created
    # (`apiVersion|Kind|name`, comma separated); deploy waits for them.
    expects = key "expects";

    # Secrets.
    sopsSource = key "sops-source";
    contentHash = key "content-hash";
    secretKeys = key "secret-keys";
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

  # Values Kix gives its own keys, where more than one module compares them.
  values = {
    # A Job carrying `rerun = "on-change"` is never patched by the deploy
    # engine: a changed one is deleted and created again, and under
    # `kix deploy` and `kix rollback` so is an unchanged one whose last run
    # failed. Stamped by `kix.healthCheck`; check 16 refuses the key on any
    # other kind and any other value. The engine's side is `keys::RERUN` in
    # `cli/kix/src/manifest/keys.rs`.
    rerunOnChange = "on-change";

    # A PackageInstance in this mode is a marker for a resource Kix
    # references but does not own.
    importMode = "import";
  };
}

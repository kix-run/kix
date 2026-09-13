# Captures manifest — declares the commands the docs pipeline runs to
# generate sidecar JSON for `<Command>`. One manifest, two execution
# modes:
#
#   - offline steps run in a Nix sandbox against a workspace derived
#     from `kix-examples` (+ optional overlay + setup mutations).
#   - live steps run as a shell script (`nix run ./docs#regen-captures`)
#     against the dedicated `kind-kix-docs` kind cluster.
#
# Per-group fields:
#
#   group     — identifier; sidecar paths go to docs/src/command-output/<group>/<name>.json
#   page      — docs URL the sidecars belong to (carried in the JSON for tooling)
#   cwd       — working directory shown in the `<Command>` chrome
#   resetCluster — live only. Delete and recreate the kind cluster before
#               this group runs. Use it when a group needs a whole-cluster
#               view that only its own kix cluster contributes to.
#   overlay   — optional directory `cp -r`'d onto the workspace (e.g. adds
#               a tutorial's finished cluster file). Layout mirrors
#               kix-examples/. See docs/overlays/README.md.
#   setup     — list of `mutate` steps applied once after the workspace
#               is prepared (e.g. patch flake.nix to register an overlay
#               cluster). Runs for BOTH offline and live pipelines.
#   offline   — list of steps the offline driver executes.
#   live      — list of steps the live driver executes.
#
# Step shapes:
#
#   { capture = "name"; run = [ "kix" "list" "clusters" ]; sortLines = false;
#     allowFailure = false; skipDriftCheck = false; stdoutJq = null;
#     stdoutGrep = null; }
#       runs the command in the workspace, sanitises stdout/stderr,
#       writes docs/src/command-output/<group>/name.json. By default a
#       non-zero exit fails the whole pipeline so regressions surface;
#       set `allowFailure = true` to record the failure as a sidecar
#       (used for tutorials that demonstrate an intentional error).
#       `skipDriftCheck = true` exempts the capture from the --check
#       drift comparison entirely. Useful when the output is dominated
#       by environment-specific noise the drift transforms can't
#       reasonably redact (Nix-version-specific eval-error stack
#       traces, etc.). --apply still rewrites the sidecar; --check
#       just doesn't gate on its content.
#       `stdoutJq` optionally filters JSON stdout before it is stored. It is
#       capture plumbing, not part of the reader-facing command. The sidecar
#       marks the rendered result as an output excerpt.
#       `stdoutGrep` does the same for text output, retaining matching lines
#       and removing their leading display padding. Regeneration fails if no
#       line matches, so a changed or missing diagnostic cannot pass unnoticed.
#       `timeout` bounds the step's wall clock (default 600s). A step that
#       exceeds it fails the run by name instead of stalling the pipeline.
#       Raise it for a step that is legitimately slow; do not raise it to
#       paper over a command that stopped terminating.
#
#   { capture = "name"; shell = "kix build demo | head -20"; }
#       runs one reader-facing command line through bash instead of
#       exec'ing an argv. Use it when the command the reader types
#       contains a pipe, a redirect, or a second tool: `find`, `grep`,
#       `jq`, `sort`. `kix` (and `kubectl`, live) are on PATH already
#       carrying --flake/--context, so write the command exactly as the
#       docs show it. The same allowFailure / stdoutJq / stdoutGrep /
#       sortLines fields apply. Prefer a plain `run` step when the
#       command is a single binary with arguments.
#
#   { mutate = { file = "tutorial-04/cluster.nix";
#                oldString = "Hello"; newString = "Preview"; }; }
#       literal substitution against workspace/<file>. Preflight checks:
#       file must exist, oldString must match exactly once. Fails the
#       whole capture run on any preflight miss (no partial sidecars).
#
#   { prepare = [ "kix" "deploy" "example" "-y" ]; }
#   { prepare = "kix build demo > manifests.yaml"; }
#       runs a prerequisite command without writing a sidecar. The command
#       must succeed. Use this for live state a later captured command needs,
#       such as deploying before `status` or `diff`. The string form runs
#       through bash like a `shell` capture, which is also how a documented
#       command whose output teaches nothing still gets executed on every
#       regen: if the CLI stops accepting it, the pipeline fails.
#
# Sequencing:
#   - Offline: each group gets its own fresh workspace. Steps run in
#     declaration order. No shared cluster.
#   - Live: each group gets its own fresh workspace, but the kind
#     cluster is shared across groups so deploys accumulate (matching
#     a reader walking the tutorial path).

[
  {
    group = "tutorials/02-hello-world";
    page = "/docs/tutorials/02-local-setup-and-first-run/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "list-clusters";
        run = [
          "kix"
          "list"
          "clusters"
        ];
      }
      {
        capture = "list-packages";
        run = [
          "kix"
          "list"
          "packages"
          "--cluster"
          "02-hello-world"
        ];
      }
    ];
    live = [
      {
        capture = "kubectl-cluster-info";
        run = [
          "kubectl"
          "cluster-info"
        ];
      }
      {
        capture = "kubectl-get-nodes";
        run = [
          "kubectl"
          "get"
          "nodes"
        ];
      }
      {
        capture = "deploy";
        run = [
          "kix"
          "deploy"
          "02-hello-world"
          "-y"
        ];
      }
      {
        capture = "status";
        run = [
          "kix"
          "status"
          "02-hello-world"
        ];
      }
      {
        capture = "kubectl-get-pods";
        run = [
          "kubectl"
          "get"
          "pods"
          "-n"
          "tutorial-02"
        ];
      }
      {
        capture = "kubectl-get-svc";
        run = [
          "kubectl"
          "get"
          "svc"
          "-n"
          "tutorial-02"
        ];
      }
      {
        # Tutorial 02's "Make One Edit" section — change the message in
        # the checked-in cluster file, then re-deploy.
        mutate = {
          file = "tutorials/02-hello-world/cluster.nix";
          oldString = ''message = "Hello from Kix!";'';
          newString = ''message = "Hello from my laptop!";'';
        };
      }
      {
        capture = "deploy-after-edit";
        run = [
          "kix"
          "deploy"
          "02-hello-world"
          "-y"
        ];
      }
    ];
  }

  {
    # Tutorial 04 / 05 operate on 04-from-scratch, which the reader
    # builds themselves under tutorial-04/. The overlay adds the
    # finished cluster file; the setup patches kix-examples/flake.nix
    # to register it. From here both pipelines treat 04-from-scratch
    # as a first-class cluster.
    group = "tutorials/04-from-scratch";
    page = "/docs/tutorials/04-first-cluster-from-scratch/";
    cwd = "kix-examples/";
    overlay = ../overlays/04-from-scratch;
    setup = [
      {
        # NOTE: the leading whitespace on the second line must match
        # the indentation of the `clusters = { ... };` block in
        # kix-examples/flake.nix. If that file gets reformatted, the
        # mutate's no-match preflight will fail and this string needs
        # updating.
        mutate = {
          file = "flake.nix";
          oldString = ''"19-scorecards" = ./tutorials/19-scorecards/cluster.nix;'';
          newString = ''
            "19-scorecards" = ./tutorials/19-scorecards/cluster.nix;
                    "04-from-scratch" = ./tutorial-04/cluster.nix;'';
        };
      }
    ];
    offline = [
      {
        capture = "list-clusters";
        run = [
          "kix"
          "list"
          "clusters"
        ];
      }
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "04-from-scratch"
        ];
      }
      {
        capture = "build";
        run = [
          "kix"
          "build"
          "04-from-scratch"
        ];
      }
      {
        capture = "graph-tree";
        run = [
          "kix"
          "graph"
          "04-from-scratch"
          "--format"
          "tree"
        ];
      }
    ];
    live = [
      {
        capture = "deploy";
        run = [
          "kix"
          "deploy"
          "04-from-scratch"
          "-y"
        ];
      }
      {
        capture = "diff-clean";
        run = [
          "kix"
          "diff"
          "04-from-scratch"
        ];
        # kix diff exits non-zero when drift exists, which is the
        # whole point of capturing it here.
        allowFailure = true;
      }
      {
        # Tutorial 05's "make a visible edit" — change the message in
        # the cluster file the reader just built.
        mutate = {
          file = "tutorial-04/cluster.nix";
          oldString = ''message = "Hello from my first Kix cluster!";'';
          newString = ''message = "Preview this before deploy.";'';
        };
      }
      {
        capture = "diff-after-edit";
        run = [
          "kix"
          "diff"
          "04-from-scratch"
        ];
        allowFailure = true;
      }
      {
        capture = "deploy-after-edit";
        run = [
          "kix"
          "deploy"
          "04-from-scratch"
          "-y"
        ];
      }
      {
        capture = "status";
        run = [
          "kix"
          "status"
          "04-from-scratch"
        ];
      }
      {
        capture = "kubectl-get-pods";
        run = [
          "kubectl"
          "get"
          "pods"
          "-n"
          "tutorial-04"
        ];
      }
      {
        capture = "kubectl-get-svc";
        run = [
          "kubectl"
          "get"
          "svc"
          "-n"
          "tutorial-04"
        ];
      }
    ];
  }

  {
    group = "tutorials/06-service-dep";
    page = "/docs/tutorials/06-first-local-package-and-service-to-service-dependency/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "06-service-dep"
        ];
      }
      {
        capture = "build";
        run = [
          "kix"
          "build"
          "06-service-dep"
        ];
      }
      {
        capture = "graph-tree";
        run = [
          "kix"
          "graph"
          "06-service-dep"
          "--format"
          "tree"
        ];
      }
      {
        # Tutorial 06's "Try Breaking The Name Match" section —
        # rename `backend` to `api` so the gateway package's
        # `backend` dep no longer resolves. `kix check` should fail
        # with an unresolved-dep error; we capture that failure as
        # the sidecar, then revert the rename so later steps see a
        # clean cluster.
        mutate = {
          file = "tutorials/06-service-dep/cluster.nix";
          oldString = "backend = {";
          newString = "api = {";
        };
      }
      {
        capture = "check-broken-name";
        run = [
          "kix"
          "check"
          "06-service-dep"
        ];
        allowFailure = true;
        # The captured output is a Nix eval-error stack trace, and
        # different Nix versions render it differently (line numbers,
        # `derivationStrict` vs `drvFunc`, flake-ref display).
        # That noise is too varied to redact, so just don't gate
        # CI on this sidecar's content.
        skipDriftCheck = true;
      }
      {
        mutate = {
          file = "tutorials/06-service-dep/cluster.nix";
          oldString = "api = {";
          newString = "backend = {";
        };
      }
    ];
    live = [
      {
        capture = "deploy";
        run = [
          "kix"
          "deploy"
          "06-service-dep"
          "-y"
        ];
      }
    ];
  }

  {
    group = "tutorials/19-scorecards";
    page = "/docs/tutorials/19-scorecards-and-compile-time-policy/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "19-scorecards"
        ];
      }
      {
        capture = "build";
        run = [
          "kix"
          "build"
          "19-scorecards"
        ];
      }
    ];
  }

  {
    group = "how-to/dependency-cross-namespace";
    page = "/docs/how-to/debug-dependency-wiring/wire-cross-namespace-dependencies-explicitly/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "08-namespace-deps"
        ];
      }
    ];
  }

  {
    group = "how-to/dependency-missing";
    page = "/docs/how-to/debug-dependency-wiring/debug-a-missing-dependency/";
    cwd = "kix-examples/";
    setup = [
      {
        mutate = {
          file = "tutorials/06-service-dep/cluster.nix";
          oldString = "backend = {";
          newString = "renamed-backend = {";
        };
      }
    ];
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "06-service-dep"
        ];
        allowFailure = true;
        stdoutGrep = "error: no 'backend' found in cluster";
      }
    ];
  }

  {
    # Same cluster as `how-to/dependency-missing`, without the mutation:
    # this is what the reader sees once the wiring is corrected.
    group = "how-to/dependency-fixed";
    page = "/docs/how-to/debug-dependency-wiring/debug-a-missing-dependency/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "06-service-dep"
        ];
      }
    ];
  }

  {
    group = "how-to/dependency-graph";
    page = "/docs/how-to/debug-dependency-wiring/visualize-the-dependency-graph-with-kix-graph/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "graph-tree";
        run = [
          "kix"
          "graph"
          "08-namespace-deps"
          "--format"
          "tree"
        ];
      }
      {
        capture = "graph-dot";
        run = [
          "kix"
          "graph"
          "08-namespace-deps"
          "--format"
          "dot"
        ];
      }
      {
        # The DOT and JSON forms are what the reader redirects into a
        # file. Run the redirect itself so the docs cannot outlive it.
        prepare = "kix graph 08-namespace-deps --format dot > kix-graph.dot";
      }
      {
        capture = "graph-json";
        run = [
          "kix"
          "graph"
          "08-namespace-deps"
          "--format"
          "json"
        ];
        stdoutJq = "{ nodes: (.nodes | length), edges: (.edges | length), sample: .nodes[0] }";
      }
    ];
  }

  {
    group = "how-to/dependency-auto-instantiation";
    page = "/docs/how-to/debug-dependency-wiring/use-auto-instantiation-with-availablepackages-optional-and-autonamespace/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-auto-instantiation"
        ];
      }
      {
        capture = "graph";
        run = [
          "kix"
          "graph"
          "how-to-auto-instantiation"
          "--format"
          "tree"
        ];
      }
    ];
  }

  {
    group = "how-to/scorecard-rules";
    page = "/docs/how-to/policy-ci-and-compliance/add-scorecard-rules/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "19-scorecards"
        ];
      }
    ];
  }

  {
    group = "how-to/policy-sarif";
    page = "/docs/how-to/policy-ci-and-compliance/run-kix-check-sarif-in-ci/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "19-scorecards"
          "--sarif"
        ];
        stdoutJq = ''
          {
                    version,
                    runs: [.runs[] | {
                      tool: .tool.driver.name,
                      rules: (.tool.driver.rules | length),
                      results: [.results[] | {
                        ruleId,
                        level,
                        message: .message.text,
                        location: .locations[0].physicalLocation.artifactLocation.uri
                      }]
                    }]
                  }'';
      }
      {
        prepare = "kix check 19-scorecards --sarif > kix-results.sarif";
      }
      {
        prepare = ''jq -e '.version == "2.1.0" and (.runs | length) > 0' kix-results.sarif > /dev/null'';
      }
    ];
  }

  {
    group = "how-to/policy-sbom";
    page = "/docs/how-to/policy-ci-and-compliance/generate-a-cyclonedx-sbom/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "sbom";
        run = [
          "kix"
          "compliance"
          "sbom"
          "19-scorecards"
        ];
        stdoutJq = ''
          {
                    bomFormat,
                    specVersion,
                    metadata: { component: .metadata.component },
                    componentTypes: ([.components[].type] | group_by(.) | map({
                      type: .[0],
                      count: length
                    })),
                    dependencyCount: (.dependencies | length)
                  }'';
      }
      # The page tells the reader to redirect the SBOM to a file and
      # then assert its format. Both run here, so a change to the
      # CycloneDX version fails the regen instead of the reader.
      {
        prepare = "kix compliance sbom 19-scorecards > sbom.json";
      }
      {
        prepare = ''jq -e '.bomFormat == "CycloneDX" and .specVersion == "1.6"' sbom.json > /dev/null'';
      }
      {
        prepare = "kix --output yaml compliance sbom 19-scorecards > sbom.yaml";
      }
    ];
  }

  {
    group = "how-to/policy-provenance";
    page = "/docs/how-to/policy-ci-and-compliance/generate-slsa-provenance/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "attest";
        run = [
          "kix"
          "compliance"
          "attest"
          "19-scorecards"
          "--builder-id"
          "https://ci.example/runs/1842"
          "--invocation-id"
          "1842"
        ];
        stdoutJq = ''
          {
                    _type,
                    predicateType,
                    subject,
                    buildDefinition: {
                      buildType: .predicate.buildDefinition.buildType,
                      externalParameters: .predicate.buildDefinition.externalParameters,
                      resolvedDependencyCount: (.predicate.buildDefinition.resolvedDependencies | length)
                    },
                    runDetails: .predicate.runDetails
                  }'';
      }
      {
        prepare = ''kix compliance attest 19-scorecards --builder-id "$BUILD_URL" --invocation-id "$BUILD_ID" > provenance.json'';
      }
      {
        prepare = ''jq -e '._type == "https://in-toto.io/Statement/v1" and .predicateType == "https://slsa.dev/provenance/v1"' provenance.json > /dev/null'';
      }
    ];
  }

  {
    group = "how-to/policy-receipt-attestation";
    page = "/docs/how-to/policy-ci-and-compliance/attest-a-deployment-from-its-cluster-receipt/";
    cwd = "kix-examples/";
    # First live group after the tutorials. Reset here so every how-to
    # group below sees a Kubernetes cluster whose only kix cluster is
    # how-to-application; `kix diff` and `kix gc --hard` both read the
    # whole cluster, so the tutorial deployments would otherwise show
    # up as this cluster's removals.
    resetCluster = true;
    live = [
      {
        prepare = [
          "kix"
          "deploy"
          "how-to-application"
          "-y"
        ];
      }
      {
        capture = "attest";
        run = [
          "kix"
          "compliance"
          "attest"
          "how-to-application"
          "--from-cluster"
          "--builder-id"
          "https://ci.example/runs/1842"
          "--invocation-id"
          "1842"
        ];
        stdoutJq = ''
          {
                    _type,
                    predicateType,
                    subject,
                    buildDefinition: {
                      buildType: .predicate.buildDefinition.buildType,
                      externalParameters: .predicate.buildDefinition.externalParameters,
                      resolvedDependencyCount: (.predicate.buildDefinition.resolvedDependencies | length)
                    },
                    runDetails: .predicate.runDetails
                  }'';
      }
      {
        prepare = ''kix compliance attest how-to-application --from-cluster --builder-id "$CI_RUN_URL" --invocation-id "$CI_RUN_ID" > provenance.json'';
      }
      {
        prepare = ''jq -e '.predicate.buildDefinition.externalParameters.cluster == "how-to-application" and (.subject[0].digest.nixStoreHash | length) > 0' provenance.json > /dev/null'';
      }
    ];
  }

  {
    group = "how-to/policy-audit";
    page = "/docs/how-to/policy-ci-and-compliance/generate-an-audit-bundle/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "audit";
        run = [
          "kix"
          "compliance"
          "audit"
          "19-scorecards"
          "--out"
          "./compliance"
          "--builder-id"
          "https://ci.example/runs/1842"
        ];
      }
      {
        # The page used to list the bundle's files by hand. Capture them
        # instead, so a new or renamed evidence file shows up in review.
        capture = "files";
        shell = "find compliance -type f | sort";
      }
      {
        prepare = "kix compliance audit 19-scorecards --out ./compliance-iso27001 --framework iso27001";
      }
      {
        prepare = "kix compliance audit 19-scorecards --out ./compliance --force";
      }
    ];
  }

  {
    group = "how-to/image-pins";
    page = "/docs/how-to/promote-images/create-a-committed-image-pin-file/";
    cwd = "kix-project/";
    overlay = ../overlays/how-to-image-pins;
    offline = [
      {
        capture = "list";
        run = [
          "kix"
          "pin"
          "list"
          "--pins-file"
          "pins.json"
        ];
      }
      {
        capture = "check-offline";
        run = [
          "kix"
          "pin"
          "check"
          "--pins-file"
          "pins.json"
          "--offline"
        ];
      }
    ];
  }

  {
    # Shared basics for the pages that introduce a command against the
    # application scenario. One workspace, one eval, several pages.
    group = "how-to/application-basics";
    page = "/docs/how-to/start-and-inspect/render-manifests/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-application"
        ];
      }
      {
        capture = "build";
        run = [
          "kix"
          "build"
          "how-to-application"
        ];
      }
      {
        capture = "inspect";
        run = [
          "kix"
          "inspect"
          "how-to-application"
        ];
      }
      {
        capture = "list-packages";
        run = [
          "kix"
          "list"
          "packages"
          "--cluster"
          "how-to-application"
        ];
      }
      {
        # The env/mount guide only cares about one container's wiring,
        # and the full render buries it under 480 lines.
        capture = "deployment-env";
        run = [
          "kix"
          "build"
          "how-to-application"
          "--output"
          "json"
        ];
        stdoutJq = ''
          .[]
                  | select(.kind == "Deployment" and .metadata.name == "production")
                  | {
                      containers: [.spec.template.spec.containers[] | {
                        name,
                        env,
                        volumeMounts
                      }],
                      volumes: .spec.template.spec.volumes
                    }'';
      }
      # The next three teach a flag or a redirect rather than an output
      # shape, so they write no sidecar. They still run on every regen:
      # if the flag surface changes, the pipeline fails and the pages
      # showing them get fixed.
      {
        prepare = "kix build how-to-application > manifests.yaml";
      }
      {
        prepare = "kix build how-to-application --output yaml > /dev/null";
      }
      {
        prepare = "kix build how-to-application --output json > /dev/null";
      }
    ];
  }

  {
    group = "how-to/application-install";
    page = "/docs/how-to/start-and-inspect/install-and-run-the-kix-cli/";
    cwd = "";
    offline = [
      {
        capture = "version";
        run = [
          "kix"
          "--version"
        ];
      }
      {
        # The guide uses help only as a smoke test. Run it so the command
        # stays valid, but do not make the reader scan the full help text.
        prepare = [
          "kix"
          "--help"
        ];
      }
    ];
  }

  {
    group = "how-to/application-cluster-settings";
    page = "/docs/how-to/author-packages-and-clusters/configure-namespace-policy-and-global-cluster-settings/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-composition"
        ];
      }
      {
        capture = "namespace-resources";
        run = [
          "kix"
          "build"
          "how-to-composition"
          "--output"
          "json"
        ];
        stdoutJq = ''
          [.[]
                  | select(
                      (.kind == "Namespace" and .metadata.name == "apps")
                      or (.kind == "ResourceQuota" and .metadata.name == "apps-quota")
                    )
                  | {
                      kind,
                      name: .metadata.name,
                      labels: .metadata.labels,
                      annotations: .metadata.annotations,
                      hard: .spec.hard
                    }]'';
      }
    ];
  }

  {
    group = "how-to/application-package-metadata";
    page = "/docs/how-to/author-packages-and-clusters/declare-package-roles-and-metadata/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-composition"
        ];
      }
    ];
  }

  {
    group = "how-to/application-custom-resource-readiness";
    page = "/docs/how-to/author-packages-and-clusters/declare-readiness-for-custom-resources/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "widget";
        run = [
          "kix"
          "build"
          "how-to-composition"
          "--output"
          "json"
        ];
        stdoutJq = ''
          .[]
                  | select(.kind == "Widget" and .metadata.name == "example")
                  | {
                      apiVersion,
                      kind,
                      metadata: {
                        name: .metadata.name,
                        readiness: .metadata.annotations."kix.run/readiness"
                      },
                      spec
                    }'';
      }
      {
        prepare = [
          "kix"
          "check"
          "how-to-composition"
        ];
      }
    ];
  }

  {
    group = "how-to/composition-fragments";
    page = "/docs/how-to/author-packages-and-clusters/compose-multi-team-clusters-with-mergefragments/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-fragments"
        ];
      }
      {
        capture = "namespace";
        run = [
          "kix"
          "build"
          "how-to-fragments"
          "--output"
          "json"
        ];
        stdoutJq = ''.[] | select(.kind == "Namespace" and .metadata.name == "apps") | {kind, metadata: {name: .metadata.name, labels: .metadata.labels, annotations: .metadata.annotations}}'';
      }
    ];
  }

  {
    group = "how-to/composition-multi-env";
    page = "/docs/how-to/author-packages-and-clusters/stamp-multi-environment-clusters-with-mkenv/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-multi-env"
        ];
      }
      {
        capture = "environment-resources";
        run = [
          "kix"
          "build"
          "how-to-multi-env"
          "--output"
          "json"
        ];
        stdoutJq = ''
          map(select(.kind == "Deployment" and .metadata.name == "web"))
          | map({kind, namespace: .metadata.namespace, replicas: .spec.replicas})'';
      }
    ];
  }

  {
    group = "how-to/platform-managed-secrets";
    page = "/docs/how-to/platform-capabilities/use-kix-managed-secrets/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-platform-secrets"
        ];
      }
    ];
  }

  {
    group = "how-to/platform-external-secrets";
    page = "/docs/how-to/platform-capabilities/use-externally-managed-secrets/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-platform-secrets"
        ];
      }
      {
        capture = "graph";
        run = [
          "kix"
          "graph"
          "how-to-platform-secrets"
          "--format"
          "tree"
        ];
      }
    ];
  }

  {
    group = "how-to/platform-sops-secrets";
    page = "/docs/how-to/platform-capabilities/use-sops-backed-secrets-if-production-ready/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "rendered-secret";
        run = [
          "kix"
          "build"
          "how-to-platform-sops"
          "--output"
          "json"
        ];
        stdoutJq = ''
          map(select(.kind == "Secret" and .metadata.name == "app-credentials"))
          | map({
              kind,
              namespace: .metadata.namespace,
              name: .metadata.name,
              declaredKeys: (.metadata.annotations["kix.run/secret-keys"] | split(",")),
              plaintextIncluded: has("stringData") or has("data")
            })'';
      }
    ];
    live = [
      {
        prepare = ''SOPS_AGE_KEY_FILE=how-to/platform/test-only-age-key.txt kix deploy how-to-platform-sops -y'';
      }
      {
        capture = "secret";
        run = [
          "kubectl"
          "get"
          "secret"
          "app-credentials"
          "-n"
          "sops-example"
        ];
      }
    ];
  }

  {
    group = "how-to/platform-cloudflare-tunnel";
    page = "/docs/how-to/platform-capabilities/expose-a-service-through-cloudflare-tunnel/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "resources";
        run = [
          "kix"
          "build"
          "how-to-platform-cloudflare-tunnel"
          "--output"
          "json"
        ];
        stdoutJq = ''
          map(select(
            (.kind == "Service" and .metadata.name == "web")
            or (.kind == "Deployment" and .metadata.name == "cloudflared")
            or (.kind == "Secret" and .metadata.name == "cloudflared-token")
          ))
          | map(
              if .kind == "Service" then {
                kind,
                namespace: .metadata.namespace,
                name: .metadata.name,
                ports: .spec.ports
              }
              elif .kind == "Deployment" then {
                kind,
                namespace: .metadata.namespace,
                name: .metadata.name,
                replicas: .spec.replicas,
                image: .spec.template.spec.containers[0].image,
                args: .spec.template.spec.containers[0].args
              }
              else {
                kind,
                namespace: .metadata.namespace,
                name: .metadata.name,
                declaredKeys: (.metadata.annotations["kix.run/secret-keys"] | split(",")),
                plaintextIncluded: has("stringData") or has("data")
              }
              end
            )'';
      }
    ];
  }

  {
    group = "how-to/platform-ingress";
    page = "/docs/how-to/platform-capabilities/expose-a-service-with-ingress/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-platform-ingress"
        ];
      }
      {
        capture = "ingress";
        run = [
          "kix"
          "build"
          "how-to-platform-ingress"
          "--output"
          "json"
        ];
        stdoutJq = ''
          .[]
          | select(.kind == "Ingress" and .metadata.namespace == "ingress-example")
          | {apiVersion, kind, metadata: {name: .metadata.name, namespace: .metadata.namespace}, spec}'';
      }
    ];
  }

  {
    group = "how-to/install-ingress-nginx";
    page = "/docs/how-to/package-task-guides/install-ingress-nginx/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "controller-resources";
        run = [
          "kix"
          "build"
          "how-to-platform-ingress"
          "--output"
          "json"
        ];
        stdoutJq = ''
          [
            .[]
            | select(
                (.kind == "Deployment" and .metadata.namespace == "ingress-system")
                or (.kind == "Service" and .metadata.namespace == "ingress-system" and .metadata.name == "ingressNginx")
                or (.kind == "IngressClass" and .metadata.name == "ingressNginx")
              )
            | if .kind == "Deployment" then
                {apiVersion, kind, metadata: {name: .metadata.name, namespace: .metadata.namespace}, replicas: .spec.replicas}
              else if .kind == "Service" then
                {apiVersion, kind, metadata: {name: .metadata.name, namespace: .metadata.namespace}, type: .spec.type, ports: .spec.ports}
              else
                {apiVersion, kind, metadata: {name: .metadata.name}, spec}
              end end
          ]'';
      }
    ];
  }

  {
    group = "how-to/package-cert-manager";
    page = "/docs/how-to/package-task-guides/configure-cert-manager-issuers/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-package-cert-manager"
        ];
      }
      {
        capture = "issuer";
        run = [
          "kix"
          "build"
          "how-to-package-cert-manager"
          "--output"
          "json"
        ];
        stdoutJq = ''
          .[]
          | select(.kind == "ClusterIssuer" and .metadata.name == "local-self-signed")
          | {apiVersion, kind, metadata: {name: .metadata.name}, spec}'';
      }
    ];
  }

  {
    group = "how-to/helm-bridge";
    page = "/docs/how-to/adopt-existing-resources/use-helm-charts-through-the-kix-helm-bridge/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-helm-bridge"
        ];
      }
      {
        capture = "deployment";
        run = [
          "kix"
          "build"
          "how-to-helm-bridge"
          "--output"
          "json"
        ];
        stdoutJq = ''
          .[]
          | select(.kind == "Deployment" and .metadata.namespace == "reflector-system")
          | {
              apiVersion,
              kind,
              metadata: {name: .metadata.name, namespace: .metadata.namespace, labels: .metadata.labels},
              spec: {
                replicas: .spec.replicas,
                serviceAccountName: .spec.template.spec.serviceAccountName,
                containers: .spec.template.spec.containers | map({name, image})
              }
            }'';
      }
    ];
  }

  {
    group = "how-to/package-cilium";
    page = "/docs/how-to/package-task-guides/install-cilium-network-policy-support/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-package-cilium"
        ];
      }
      {
        capture = "components";
        run = [
          "kix"
          "build"
          "how-to-package-cilium"
          "--output"
          "json"
        ];
        stdoutJq = ''
          [
            .[]
            | select(
                (.kind == "DaemonSet" and .metadata.namespace == "kube-system" and .metadata.name == "cilium")
                or (.kind == "Deployment" and .metadata.namespace == "kube-system" and .metadata.name == "cilium-operator")
                or (.kind == "CiliumNetworkPolicy" and .metadata.name == "kube-system-default-deny")
              )
            | if .kind == "DaemonSet" or .kind == "Deployment" then
                {
                  apiVersion,
                  kind,
                  metadata: {name: .metadata.name, namespace: .metadata.namespace},
                  containers: .spec.template.spec.containers | map({name, image})
                }
              else
                {apiVersion, kind, metadata: {name: .metadata.name, namespace: .metadata.namespace}, spec}
              end
          ]'';
      }
    ];
  }

  {
    group = "how-to/package-python";
    page = "/docs/how-to/package-task-guides/deploy-a-python-app/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-package-python"
        ];
      }
      {
        capture = "workload";
        run = [
          "kix"
          "build"
          "how-to-package-python"
          "--output"
          "json"
        ];
        stdoutJq = ''
          [
            .[]
            | select(
                (.kind == "Deployment" and .metadata.namespace == "python-example")
                or (.kind == "Service" and .metadata.namespace == "python-example")
                or (.kind == "ConfigMap" and .metadata.namespace == "python-example")
              )
            | if .kind == "Deployment" then
                {
                  apiVersion,
                  kind,
                  metadata: {name: .metadata.name, namespace: .metadata.namespace},
                  spec: {
                    replicas: .spec.replicas,
                    containers: .spec.template.spec.containers
                      | map({name, image, command, args, ports, livenessProbe, readinessProbe})
                  }
                }
              else if .kind == "Service" then
                {apiVersion, kind, metadata: {name: .metadata.name, namespace: .metadata.namespace}, spec: {ports: .spec.ports}}
              else
                {apiVersion, kind, metadata: {name: .metadata.name, namespace: .metadata.namespace}, data}
              end end
          ]'';
      }
    ];
  }

  {
    group = "how-to/package-stackgres";
    page = "/docs/how-to/package-task-guides/deploy-stackgres/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-package-stackgres"
        ];
      }
      {
        capture = "database-resources";
        run = [
          "kix"
          "build"
          "how-to-package-stackgres"
          "--output"
          "json"
        ];
        stdoutJq = ''
          [
            .[]
            | select(
                .metadata.namespace == "database"
                and (.kind == "SGCluster" or .kind == "SGInstanceProfile")
              )
            | if .kind == "SGCluster" then
                {
                  apiVersion,
                  kind,
                  metadata: {name: .metadata.name, namespace: .metadata.namespace},
                  spec: {
                    instances: .spec.instances,
                    postgres: .spec.postgres,
                    sgInstanceProfile: .spec.sgInstanceProfile,
                    configurations: .spec.configurations,
                    persistentVolume: .spec.pods.persistentVolume
                  }
                }
              else
                {apiVersion, kind, metadata: {name: .metadata.name, namespace: .metadata.namespace}, spec}
              end
          ]'';
      }
    ];
  }

  {
    group = "how-to/package-monitoring";
    page = "/docs/how-to/package-task-guides/install-the-monitoring-stack/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-package-monitoring"
        ];
      }
      {
        capture = "packages";
        run = [
          "kix"
          "list"
          "packages"
          "--cluster"
          "how-to-package-monitoring"
        ];
      }
    ];
  }

  {
    group = "how-to/package-victoria-metrics";
    page = "/docs/how-to/package-task-guides/install-the-victoriametrics-ha-monitoring-stack/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-package-victoria-metrics"
        ];
      }
      {
        capture = "packages";
        run = [
          "kix"
          "list"
          "packages"
          "--cluster"
          "how-to-package-victoria-metrics"
        ];
      }
      {
        capture = "resources";
        run = [
          "kix"
          "build"
          "how-to-package-victoria-metrics"
          "--output"
          "json"
        ];
        stdoutJq = ''
          [
            .[]
            | select(
                .metadata.namespace == "monitoring-system"
                and (.kind == "VMCluster" or .kind == "VMAgent" or .kind == "VMAlert" or .kind == "VMAlertmanager")
              )
            | if .kind == "VMCluster" then
                {
                  apiVersion,
                  kind,
                  metadata: {name: .metadata.name, namespace: .metadata.namespace},
                  spec: {
                    retentionPeriod: .spec.retentionPeriod,
                    replicationFactor: .spec.replicationFactor,
                    vmstorage: {
                      replicaCount: .spec.vmstorage.replicaCount,
                      storage: .spec.vmstorage.storage,
                      podDisruptionBudget: .spec.vmstorage.podDisruptionBudget
                    },
                    vmselect: {
                      replicaCount: .spec.vmselect.replicaCount,
                      podDisruptionBudget: .spec.vmselect.podDisruptionBudget
                    },
                    vminsert: {
                      replicaCount: .spec.vminsert.replicaCount,
                      podDisruptionBudget: .spec.vminsert.podDisruptionBudget
                    }
                  }
                }
              elif .kind == "VMAgent" then
                {
                  apiVersion,
                  kind,
                  metadata: {name: .metadata.name, namespace: .metadata.namespace},
                  spec: {
                    replicaCount: .spec.replicaCount,
                    scrapeInterval: .spec.scrapeInterval,
                    remoteWrite: .spec.remoteWrite,
                    externalLabels: .spec.externalLabels
                  }
                }
              elif .kind == "VMAlert" then
                {
                  apiVersion,
                  kind,
                  metadata: {name: .metadata.name, namespace: .metadata.namespace},
                  spec: {
                    replicaCount: .spec.replicaCount,
                    datasource: .spec.datasource,
                    remoteRead: .spec.remoteRead,
                    remoteWrite: .spec.remoteWrite
                  }
                }
              else
                {
                  apiVersion,
                  kind,
                  metadata: {name: .metadata.name, namespace: .metadata.namespace},
                  spec: {replicaCount: .spec.replicaCount, retention: .spec.retention}
                }
              end
          ]'';
      }
    ];
  }

  {
    group = "how-to/package-velero";
    page = "/docs/how-to/package-task-guides/deploy-velero/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-package-velero"
        ];
      }
      {
        capture = "backup-configuration";
        run = [
          "kix"
          "build"
          "how-to-package-velero"
          "--output"
          "json"
        ];
        stdoutJq = ''
          [
            .[]
            | select(.kind == "BackupStorageLocation" or .kind == "Schedule")
            | {
                apiVersion,
                kind,
                metadata: {
                  name: .metadata.name,
                  namespace: .metadata.namespace
                },
                spec
              }
          ]'';
      }
    ];
  }

  {
    group = "how-to/package-valkey";
    page = "/docs/how-to/package-task-guides/deploy-valkey-redis/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-package-valkey"
        ];
      }
      {
        capture = "resources";
        run = [
          "kix"
          "build"
          "how-to-package-valkey"
          "--output"
          "json"
        ];
        stdoutJq = ''
          [
            .[]
            | select(
                (.kind == "StatefulSet" and .metadata.namespace == "cache")
                or (.kind == "Service" and .metadata.namespace == "cache" and .metadata.name == "valkey")
              )
            | if .kind == "StatefulSet" then
                {
                  apiVersion,
                  kind,
                  metadata: {name: .metadata.name, namespace: .metadata.namespace},
                  spec: {
                    replicas: .spec.replicas,
                    serviceName: .spec.serviceName,
                    containers: .spec.template.spec.containers | map({name, image, ports}),
                    volumeClaimTemplates: .spec.volumeClaimTemplates
                      | map({metadata: {name: .metadata.name}, spec})
                  }
                }
              else
                {apiVersion, kind, metadata: {name: .metadata.name, namespace: .metadata.namespace}, spec: {ports: .spec.ports}}
              end
          ]'';
      }
    ];
  }

  {
    group = "how-to/platform-gateway";
    page = "/docs/how-to/platform-capabilities/expose-a-service-with-gateway-api/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-platform-gateway"
        ];
      }
      {
        capture = "http-route";
        run = [
          "kix"
          "build"
          "how-to-platform-gateway"
          "--output"
          "json"
        ];
        stdoutJq = ''
          .[]
          | select(.kind == "HTTPRoute" and .metadata.namespace == "gateway-example")
          | {apiVersion, kind, metadata: {name: .metadata.name, namespace: .metadata.namespace}, spec}'';
      }
    ];
  }

  {
    group = "how-to/package-envoy-gateway";
    page = "/docs/how-to/package-task-guides/install-envoy-gateway/";
    cwd = "kix-examples/";
    resetCluster = true;
    live = [
      {
        prepare = [
          "helm"
          "install"
          "eg"
          "oci://docker.io/envoyproxy/gateway-helm"
          "--version"
          "v1.9.1"
          "--namespace"
          "envoy-gateway-system"
          "--create-namespace"
        ];
        timeout = "900s";
      }
      {
        capture = "controller-ready";
        run = [
          "kubectl"
          "wait"
          "--timeout=5m"
          "--namespace"
          "envoy-gateway-system"
          "deployment/envoy-gateway"
          "--for=condition=Available"
        ];
      }
      {
        prepare = [
          "kix"
          "deploy"
          "how-to-platform-gateway"
          "-y"
        ];
        timeout = "900s";
      }
      {
        capture = "gateway-resources";
        run = [
          "kubectl"
          "get"
          "gatewayclass,gateway"
          "--all-namespaces"
        ];
        skipDriftCheck = true;
      }
    ];
  }

  {
    group = "how-to/platform-monitoring";
    page = "/docs/how-to/platform-capabilities/auto-monitor-a-service/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-platform-monitoring"
        ];
      }
      {
        capture = "service-monitor";
        run = [
          "kix"
          "build"
          "how-to-platform-monitoring"
          "--output"
          "json"
        ];
        stdoutJq = ''
          .[]
          | select(.kind == "ServiceMonitor" and .metadata.namespace == "monitor-example")
          | {apiVersion, kind, metadata: {name: .metadata.name, namespace: .metadata.namespace}, spec}'';
      }
    ];
  }

  {
    group = "how-to/platform-network-policy";
    page = "/docs/how-to/platform-capabilities/enable-generated-network-policy/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-platform-network-policy"
        ];
      }
      {
        capture = "policies";
        run = [
          "kix"
          "build"
          "how-to-platform-network-policy"
          "--output"
          "json"
        ];
        stdoutJq = ''
          [
            .[]
            | select(
                .kind == "CiliumNetworkPolicy"
                and (
                  .metadata.name == "apps-default-deny"
                  or .metadata.name == "services-default-deny"
                  or .metadata.name == "client-deployment-client-egress"
                  or .metadata.name == "client-deployment-client-to-backend-ingress"
                )
              )
            | {apiVersion, kind, metadata: {name: .metadata.name, namespace: .metadata.namespace}, spec}
          ]'';
      }
    ];
  }

  {
    group = "how-to/platform-intents";
    page = "/docs/how-to/platform-capabilities/declare-platform-intents-for-non-kix-managed-pods/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-platform-network-policy"
        ];
      }
      {
        capture = "intent";
        run = [
          "kix"
          "build"
          "how-to-platform-network-policy"
          "--output"
          "json"
        ];
        stdoutJq = ''
          .[]
          | select(.kind == "CiliumClusterwideNetworkPolicy" and .metadata.name == "metrics-agent")
          | {apiVersion, kind, metadata: {name: .metadata.name}, spec}'';
      }
    ];
  }

  {
    group = "how-to/platform-hostpath";
    page = "/docs/how-to/platform-capabilities/mount-node-local-storage-with-hostpath/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-platform-hostpath"
        ];
      }
      {
        capture = "deployment";
        run = [
          "kix"
          "build"
          "how-to-platform-hostpath"
          "--output"
          "json"
        ];
        stdoutJq = ''
          .[]
          | select(.kind == "Deployment" and .metadata.namespace == "hostpath-example")
          | {
              apiVersion,
              kind,
              metadata: {name: .metadata.name, namespace: .metadata.namespace},
              podSpec: {
                containers: [.spec.template.spec.containers[] | {name, volumeMounts}],
                volumes: .spec.template.spec.volumes
              }
            }'';
      }
    ];
  }

  {
    group = "how-to/package-storage";
    page = "/docs/how-to/package-task-guides/provision-persistent-storage/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-package-storage"
        ];
      }
      {
        capture = "storage-resources";
        run = [
          "kix"
          "build"
          "how-to-package-storage"
          "--output"
          "json"
        ];
        stdoutJq = ''
          [
            .[]
            | select(
                .metadata.namespace == "storage-example"
                and (.kind == "PersistentVolumeClaim" or .kind == "Deployment")
              )
            | if .kind == "PersistentVolumeClaim" then
                {apiVersion, kind, metadata: {name: .metadata.name, namespace: .metadata.namespace}, spec}
              else
                {
                  apiVersion,
                  kind,
                  metadata: {name: .metadata.name, namespace: .metadata.namespace},
                  podSpec: {
                    containers: [.spec.template.spec.containers[] | {name, volumeMounts}],
                    volumes: .spec.template.spec.volumes
                  }
                }
              end
          ]'';
      }
    ];
  }

  {
    group = "how-to/adoption-parts-overlay";
    page = "/docs/how-to/adopt-existing-resources/patch-package-output-with-overlays/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-adoption"
        ];
      }
      {
        capture = "patched-config";
        run = [
          "kix"
          "build"
          "how-to-adoption"
          "--output"
          "json"
        ];
        stdoutJq = ''
          .[]
          | select(.kind == "ConfigMap" and .metadata.name == "legacy-api-client")
          | {
              apiVersion,
              kind,
              metadata: {
                name: .metadata.name,
                namespace: .metadata.namespace,
                annotations: {
                  "example.com/adopted-from": .metadata.annotations["example.com/adopted-from"]
                }
              },
              data
            }
        '';
      }
    ];
  }

  {
    group = "how-to/adoption-helm-labels";
    page = "/docs/how-to/adopt-existing-resources/preserve-helm-compatible-labels/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-adoption"
        ];
      }
      {
        capture = "workload-labels";
        run = [
          "kix"
          "build"
          "how-to-adoption"
          "--output"
          "json"
        ];
        stdoutJq = ''
          [
            .[]
            | select(
                .metadata.namespace == "apps"
                and .metadata.name == "helm-web"
                and (.kind == "Deployment" or .kind == "Service")
              )
            | if .kind == "Deployment" then
                {
                  apiVersion,
                  kind,
                  metadata: {name: .metadata.name, namespace: .metadata.namespace, labels: .metadata.labels},
                  selector: .spec.selector,
                  podLabels: .spec.template.metadata.labels
                }
              else
                {
                  apiVersion,
                  kind,
                  metadata: {name: .metadata.name, namespace: .metadata.namespace, labels: .metadata.labels},
                  selector: .spec.selector
                }
              end
          ]
        '';
      }
    ];
  }

  {
    group = "how-to/adoption-preserve-selectors";
    page = "/docs/how-to/adopt-existing-resources/preserve-existing-selectors/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-adoption"
        ];
      }
      {
        capture = "deployment";
        run = [
          "kix"
          "build"
          "how-to-adoption"
          "--output"
          "json"
        ];
        stdoutJq = ''
          .[]
          | select(.kind == "Deployment" and .metadata.name == "legacy-web")
          | {
              apiVersion,
              kind,
              metadata: {name: .metadata.name, namespace: .metadata.namespace},
              selector: .spec.selector,
              podLabels: .spec.template.metadata.labels
            }
        '';
      }
    ];
  }

  {
    group = "how-to/adoption-import-service";
    page = "/docs/how-to/adopt-existing-resources/import-an-existing-service-with-kix-mkimport/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-adoption"
        ];
      }
      {
        capture = "list-packages";
        run = [
          "kix"
          "list"
          "packages"
          "--cluster"
          "how-to-adoption"
        ];
      }
      {
        capture = "client-config";
        run = [
          "kix"
          "build"
          "how-to-adoption"
          "--output"
          "json"
        ];
        stdoutJq = ''
          .[]
          | select(.kind == "ConfigMap" and .metadata.name == "legacy-api-client")
          | {apiVersion, kind, metadata: {name: .metadata.name, namespace: .metadata.namespace}, data}
        '';
      }
    ];
  }

  {
    group = "how-to/adoption-kubectl-takeover";
    page = "/docs/how-to/adopt-existing-resources/take-ownership-of-kubectl-managed-resources/";
    cwd = "kix-examples/";
    resetCluster = true;
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-adoption-takeover"
        ];
      }
      {
        capture = "desired-deployment";
        run = [
          "kix"
          "build"
          "how-to-adoption-takeover"
          "--output"
          "json"
        ];
        stdoutJq = ''
          .[]
          | select(.kind == "Deployment" and .metadata.name == "legacy-web")
          | {
              apiVersion,
              kind,
              metadata: {name: .metadata.name, namespace: .metadata.namespace},
              spec: {
                replicas: .spec.replicas,
                selector: .spec.selector,
                podLabels: .spec.template.metadata.labels,
                containers: .spec.template.spec.containers | map({name, image})
              }
            }'';
      }
    ];
    live = [
      {
        prepare = [
          "kubectl"
          "create"
          "namespace"
          "takeover"
        ];
      }
      {
        prepare = [
          "kubectl"
          "apply"
          "--server-side"
          "--field-manager=kubectl"
          "-f"
          "how-to/adoption/kubectl-deployment.yaml"
        ];
      }
      {
        capture = "conflict";
        run = [
          "kix"
          "deploy"
          "how-to-adoption-takeover"
          "--dry-run"
          "-y"
        ];
        allowFailure = true;
        stdoutGrep = "field-ownership conflict|Dry run complete";
      }
      {
        capture = "take-ownership";
        run = [
          "kix"
          "deploy"
          "how-to-adoption-takeover"
          "--force-conflicts"
          "-y"
        ];
        stdoutGrep = "Deployment/legacy-web|activation .*Active|Deploy complete";
      }
    ];
  }

  {
    group = "how-to/adoption-ssa-conflicts";
    page = "/docs/how-to/adopt-existing-resources/handle-server-side-apply-conflicts-safely/";
    cwd = "kix-examples/";
    resetCluster = true;
    live = [
      {
        prepare = [
          "kix"
          "deploy"
          "how-to-adoption-takeover"
          "-y"
        ];
      }
      {
        prepare = [
          "kubectl"
          "apply"
          "--server-side"
          "--field-manager=autoscaler"
          "--force-conflicts"
          "-f"
          "how-to/adoption/autoscaler-replicas.yaml"
        ];
      }
      {
        capture = "conflict";
        run = [
          "kix"
          "deploy"
          "how-to-adoption-takeover"
          "--reconcile"
          "--dry-run"
          "-y"
        ];
        allowFailure = true;
        stdoutGrep = "field-ownership conflict|Dry run complete";
      }
      {
        capture = "force-preview";
        run = [
          "kix"
          "deploy"
          "how-to-adoption-takeover"
          "--reconcile"
          "--dry-run"
          "--force-conflicts"
          "-y"
        ];
        stdoutGrep = "Deployment/legacy-web|Dry run complete";
      }
      {
        capture = "resolve";
        run = [
          "kix"
          "deploy"
          "how-to-adoption-takeover"
          "--reconcile"
          "--force-conflicts"
          "-y"
        ];
        stdoutGrep = "Deployment/legacy-web|activation .*Active|Deploy complete";
      }
    ];
  }

  {
    group = "how-to/adoption-helm-takeover";
    page = "/docs/how-to/adopt-existing-resources/take-ownership-of-helm-managed-resources/";
    cwd = "kix-examples/";
    resetCluster = true;
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-helm-bridge"
        ];
      }
      {
        capture = "desired-deployment";
        run = [
          "kix"
          "build"
          "how-to-helm-bridge"
          "--output"
          "json"
        ];
        stdoutJq = ''
          .[]
          | select(.kind == "Deployment" and .metadata.namespace == "reflector-system")
          | {
              apiVersion,
              kind,
              metadata: {name: .metadata.name, namespace: .metadata.namespace},
              spec: {
                replicas: .spec.replicas,
                selector: .spec.selector,
                serviceAccountName: .spec.template.spec.serviceAccountName,
                containers: .spec.template.spec.containers | map({name, image})
              }
            }'';
      }
    ];
    live = [
      {
        prepare = [
          "helm"
          "upgrade"
          "--install"
          "reflector"
          "reflector"
          "--repo"
          "https://emberstack.github.io/helm-charts"
          "--version"
          "10.0.60"
          "--namespace"
          "reflector-system"
          "--create-namespace"
        ];
      }
      {
        capture = "conflict";
        run = [
          "kix"
          "deploy"
          "how-to-helm-bridge"
          "--dry-run"
          "-y"
        ];
        allowFailure = true;
        stdoutGrep = "field-ownership conflict|Dry run complete";
      }
      {
        capture = "take-ownership";
        run = [
          "kix"
          "deploy"
          "how-to-helm-bridge"
          "--force-conflicts"
          "-y"
        ];
        stdoutGrep = "Deployment/reflector|activation .*Active|Deploy complete";
      }
      {
        capture = "remove-release-record";
        run = [
          "kubectl"
          "delete"
          "secret"
          "--namespace"
          "reflector-system"
          "--selector"
          "owner=helm,name=reflector"
        ];
      }
    ];
  }

  {
    group = "how-to/adoption-extra-deps";
    page = "/docs/how-to/adopt-existing-resources/add-explicit-ordering-with-extradeps/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-adoption"
        ];
      }
      {
        capture = "graph";
        run = [
          "kix"
          "graph"
          "how-to-adoption"
          "--format"
          "tree"
        ];
        stdoutGrep = "legacy-api-contract|PackageInstance/legacy-api@legacy";
      }
    ];
  }

  {
    group = "how-to/adoption-stateful-migration";
    page = "/docs/how-to/adopt-existing-resources/handle-stateful-migration-prompts-safely/";
    cwd = "kix-examples/";
    resetCluster = true;
    offline = [
      {
        capture = "export-before";
        run = [
          "kix"
          "export"
          "how-to-stateful-migration"
          "--for"
          "audit"
          "--out"
          "stateful-before"
        ];
      }
      {
        mutate = {
          file = "flake.nix";
          oldString = ''"how-to-stateful-migration" = ./how-to/adoption/stateful-before-cluster.nix;'';
          newString = ''"how-to-stateful-migration" = ./how-to/adoption/stateful-after-cluster.nix;'';
        };
      }
      {
        capture = "diff";
        run = [
          "kix"
          "diff"
          "how-to-stateful-migration"
          "--from"
          "stateful-before"
        ];
        allowFailure = true;
        stdoutGrep = "PersistentVolumeClaim/media-v[12]|Stateful migrations detected|data/volume:|source:|target:|data migration is NOT yet automated";
      }
    ];
    live = [
      {
        prepare = [
          "kix"
          "deploy"
          "how-to-stateful-migration"
          "-y"
        ];
      }
      {
        mutate = {
          file = "flake.nix";
          oldString = ''"how-to-stateful-migration" = ./how-to/adoption/stateful-before-cluster.nix;'';
          newString = ''"how-to-stateful-migration" = ./how-to/adoption/stateful-after-cluster.nix;'';
        };
      }
      {
        capture = "refusal";
        run = [
          "kix"
          "deploy"
          "how-to-stateful-migration"
          "-y"
        ];
        allowFailure = true;
      }
      {
        capture = "accepted-dry-run";
        run = [
          "kix"
          "deploy"
          "how-to-stateful-migration"
          "--accept-migrations"
          "--dry-run"
          "-y"
        ];
      }
    ];
  }

  {
    group = "how-to/application-typed-options";
    page = "/docs/how-to/author-packages-and-clusters/add-typed-package-options/";
    cwd = "kix-examples/";
    setup = [
      {
        mutate = {
          file = "how-to/application/cluster.nix";
          oldString = ''environment = "preview";'';
          newString = ''environment = "staging";'';
        };
      }
    ];
    offline = [
      {
        capture = "check-invalid-environment";
        run = [
          "kix"
          "check"
          "how-to-application"
        ];
        allowFailure = true;
      }
    ];
  }

  {
    group = "how-to/application-reuse";
    page = "/docs/how-to/author-packages-and-clusters/reuse-one-package-for-multiple-instances/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "list-packages";
        run = [
          "kix"
          "list"
          "packages"
          "--cluster"
          "how-to-application"
        ];
      }
    ];
  }

  {
    group = "how-to/application-list";
    page = "/docs/how-to/start-and-inspect/list-clusters-and-packages/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "list-clusters";
        run = [
          "kix"
          "list"
          "clusters"
        ];
      }
      {
        capture = "list-packages";
        run = [
          "kix"
          "list"
          "packages"
          "--cluster"
          "how-to-application"
        ];
      }
    ];
  }

  {
    group = "how-to/application-render";
    page = "/docs/how-to/start-and-inspect/render-manifests/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "build-production-deployment";
        run = [
          "kix"
          "build"
          "how-to-application"
          "-o"
          "json"
        ];
        stdoutJq = ''.[] | select(.kind == "Deployment" and .metadata.name == "production")'';
      }
    ];
  }

  {
    group = "how-to/application-status";
    page = "/docs/how-to/operate-a-cluster/check-resource-status/";
    cwd = "kix-examples/";
    live = [
      {
        prepare = [
          "kix"
          "deploy"
          "how-to-application"
          "-y"
        ];
      }
      {
        capture = "status";
        run = [
          "kix"
          "status"
          "how-to-application"
        ];
      }
      {
        # The page sends the reader to kubectl when a resource is not
        # ready. Capture both hand-offs so the names stay right.
        capture = "describe-deployment";
        run = [
          "kubectl"
          "describe"
          "deployment"
          "production"
          "-n"
          "how-to-app"
        ];
        skipDriftCheck = true;
      }
      {
        capture = "job-logs";
        run = [
          "kubectl"
          "logs"
          "job/production-health"
          "-n"
          "how-to-app"
        ];
        skipDriftCheck = true;
      }
    ];
  }

  {
    group = "how-to/application-health";
    page = "/docs/how-to/operate-a-cluster/check-cluster-health/";
    cwd = "kix-examples/";
    live = [
      {
        prepare = [
          "kix"
          "deploy"
          "how-to-application"
          "-y"
        ];
      }
      {
        capture = "health";
        run = [
          "kix"
          "health"
          "how-to-application"
        ];
      }
      {
        capture = "health-verbose";
        run = [
          "kix"
          "health"
          "how-to-application"
          "-vv"
        ];
      }
    ];
  }

  {
    group = "how-to/application-logs";
    page = "/docs/how-to/operate-a-cluster/use-kix-logs/";
    cwd = "kix-examples/";
    live = [
      {
        prepare = [
          "kix"
          "deploy"
          "how-to-application"
          "-y"
        ];
      }
      {
        capture = "production-tail";
        run = [
          "kix"
          "logs"
          "how-to-application"
          "production"
          "--tail"
          "3"
        ];
        skipDriftCheck = true;
      }
    ];
  }

  {
    group = "how-to/application-deploy-controls";
    page = "/docs/how-to/operate-a-cluster/deploy-with-dry-run-timeouts-pruning-and-log-tui-output-modes/";
    cwd = "kix-examples/";
    live = [
      {
        prepare = [
          "kix"
          "deploy"
          "how-to-application"
          "-y"
        ];
      }
      {
        mutate = {
          file = "how-to/application/cluster.nix";
          oldString = ''message = "Hello from preview";'';
          newString = ''message = "Preview deploy controls";'';
        };
      }
      {
        capture = "dry-run";
        run = [
          "kix"
          "deploy"
          "how-to-application"
          "--dry-run"
          "--timeout"
          "5m"
          "--prune"
          "--log-format"
          "line"
        ];
      }
      {
        prepare = "kix deploy how-to-application --dry-run --log-format json > deploy.ndjson";
      }
      {
        prepare = [
          "kix"
          "deploy"
          "how-to-application"
          "--dry-run"
          "--tui"
          "--group-by-ns"
          "--fold-height"
          "20"
        ];
      }
      {
        prepare = "KIX_STALL_TIMEOUT=900 kix deploy how-to-application --dry-run";
      }
    ];
  }

  {
    # The diff guide's flagship: an in-sync cluster, then the same
    # command after one line changes. Both sides come from the live
    # cluster, which is the comparison the page is about.
    group = "how-to/application-diff";
    page = "/docs/how-to/operate-a-cluster/preview-changes-with-kix-diff/";
    cwd = "kix-examples/";
    live = [
      {
        prepare = [
          "kix"
          "deploy"
          "how-to-application"
          "-y"
        ];
      }
      {
        capture = "diff-clean";
        run = [
          "kix"
          "diff"
          "how-to-application"
        ];
      }
      {
        mutate = {
          file = "how-to/application/cluster.nix";
          oldString = ''message = "Hello from production";'';
          newString = ''message = "Updated production message";'';
        };
      }
      {
        capture = "diff-message-change";
        run = [
          "kix"
          "diff"
          "how-to-application"
        ];
        allowFailure = true;
      }
      {
        capture = "diff-markdown";
        run = [
          "kix"
          "diff"
          "how-to-application"
          "--output"
          "markdown"
        ];
        allowFailure = true;
      }
      {
        # The two redirects the page and the CI guide show. No sidecar,
        # but they run, so the flags cannot rot. `kix diff` exits 2 when
        # it finds differences, and by this point in the group it does,
        # so the redirect has to tolerate that exit the way the CI
        # snippet on the page does.
        prepare = "kix diff how-to-application --output markdown > kix-diff.md || [ $? -eq 2 ]";
        timeout = "900s";
      }
      {
        prepare = "kix diff how-to-application --output json > kix-diff.json || [ $? -eq 2 ]";
        timeout = "900s";
      }
    ];
  }

  {
    # Save the cluster, then diff a build against the saved directory.
    # The snapshot guides claim this matches the live comparison, so
    # capture both and let the sidecars show it.
    group = "how-to/application-snapshot";
    page = "/docs/how-to/operate-a-cluster/use-snapshots-for-offline-or-ci-diffs/";
    cwd = "kix-examples/";
    live = [
      {
        prepare = [
          "kix"
          "deploy"
          "how-to-application"
          "-y"
        ];
      }
      {
        capture = "save";
        run = [
          "kix"
          "snapshot"
          "save"
          "./snapshots/how-to-application"
        ];
      }
      {
        capture = "diff-clean";
        run = [
          "kix"
          "diff"
          "how-to-application"
          "--from"
          "./snapshots/how-to-application"
        ];
      }
      {
        mutate = {
          file = "how-to/application/cluster.nix";
          oldString = ''message = "Hello from production";'';
          newString = ''message = "Updated production message";'';
        };
      }
      {
        capture = "diff-from-snapshot";
        run = [
          "kix"
          "diff"
          "how-to-application"
          "--from"
          "./snapshots/how-to-application"
        ];
        allowFailure = true;
      }
    ];
  }

  {
    group = "how-to/application-drift";
    page = "/docs/how-to/operate-a-cluster/check-live-resources-for-drift/";
    cwd = "kix-examples/";
    live = [
      {
        prepare = [
          "kix"
          "deploy"
          "how-to-application"
          "-y"
        ];
      }
      {
        prepare = [
          "kubectl"
          "scale"
          "deployment"
          "production"
          "--replicas=1"
          "-n"
          "how-to-app"
        ];
      }
      {
        capture = "scaled-deployment";
        run = [
          "kix"
          "drift"
        ];
        allowFailure = true;
      }
      {
        # Drift exits non-zero when it finds drift, so the redirect the
        # page shows has to tolerate that too.
        prepare = "kix drift --output json > drift.json || [ $? -eq 1 ]";
      }
    ];
  }

  {
    group = "how-to/application-reconcile";
    page = "/docs/how-to/operate-a-cluster/reconcile-drift/";
    cwd = "kix-examples/";
    live = [
      {
        prepare = [
          "kix"
          "deploy"
          "how-to-application"
          "-y"
        ];
      }
      {
        prepare = [
          "kubectl"
          "scale"
          "deployment"
          "production"
          "--replicas=1"
          "-n"
          "how-to-app"
        ];
      }
      {
        capture = "reconcile";
        run = [
          "kix"
          "deploy"
          "how-to-application"
          "--reconcile"
          "--force-conflicts"
          "-y"
        ];
      }
      {
        capture = "drift-clean";
        run = [
          "kix"
          "drift"
        ];
      }
    ];
  }

  {
    # Deploy-to-kind sends the reader to kubectl to confirm the result.
    group = "how-to/application-kubectl";
    page = "/docs/how-to/start-and-inspect/deploy-to-kind/";
    cwd = "kix-examples/";
    live = [
      {
        prepare = [
          "kix"
          "deploy"
          "how-to-application"
          "-y"
        ];
      }
      {
        capture = "get-namespaces";
        run = [
          "kubectl"
          "get"
          "namespaces"
        ];
        skipDriftCheck = true;
      }
      {
        capture = "get-workloads";
        run = [
          "kubectl"
          "get"
          "deployments,services,jobs"
          "-n"
          "how-to-app"
        ];
        skipDriftCheck = true;
      }
    ];
  }

  {
    # Rollback history needs a second deploy to have something
    # superseded, so the mutate below is what creates the history the
    # page describes.
    group = "how-to/application-rollback";
    page = "/docs/how-to/operate-a-cluster/roll-back-an-activation/";
    cwd = "kix-examples/";
    live = [
      {
        prepare = [
          "kix"
          "deploy"
          "how-to-application"
          "-y"
        ];
      }
      {
        mutate = {
          file = "how-to/application/cluster.nix";
          oldString = ''message = "Hello from production";'';
          newString = ''message = "Second deploy";'';
        };
      }
      {
        prepare = [
          "kix"
          "deploy"
          "how-to-application"
          "-y"
        ];
      }
      {
        capture = "list";
        run = [
          "kix"
          "rollback"
          "how-to-application"
          "--list"
        ];
      }
      {
        capture = "list-json";
        run = [
          "kix"
          "rollback"
          "how-to-application"
          "--list"
          "--output"
          "json"
        ];
      }
    ];
  }

  {
    group = "how-to/application-images";
    page = "/docs/how-to/operate-a-cluster/list-images-for-airgap-preloading/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "list";
        run = [
          "kix"
          "images"
          "how-to-application"
        ];
      }
      {
        capture = "list-with-sources";
        run = [
          "kix"
          "images"
          "how-to-application"
          "--sources"
        ];
      }
      {
        capture = "list-json";
        run = [
          "kix"
          "images"
          "how-to-application"
          "--output"
          "json"
        ];
      }
      {
        prepare = "kix images how-to-application --output json > images.json";
      }
    ];
  }

  {
    group = "how-to/application-export-exit";
    page = "/docs/how-to/operate-a-cluster/export-plain-yaml/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "export";
        run = [
          "kix"
          "export"
          "how-to-application"
          "--out"
          "./handoff"
        ];
      }
      {
        capture = "files";
        shell = "find handoff -type f | sort";
      }
      {
        # The point of the exit export is that nothing kix-specific
        # survives it, so the grep is expected to find nothing and exit 1.
        capture = "no-annotations";
        shell = "grep -r 'kix.run/' ./handoff/";
        allowFailure = true;
      }
      {
        prepare = "kix export how-to-application --out ./handoff --force";
      }
    ];
  }

  {
    group = "how-to/application-export-audit";
    page = "/docs/how-to/operate-a-cluster/export-audit-preserving-yaml/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "export";
        run = [
          "kix"
          "export"
          "how-to-application"
          "--for"
          "audit"
          "--out"
          "./audit-export"
        ];
      }
      {
        capture = "annotations";
        shell = "grep -rn 'kix.run/\\(identity-hash\\|depends-on\\|package\\)' ./audit-export/ | head -8";
      }
      {
        capture = "internal-crs";
        shell = "find ./audit-export -name 'Activation-*.yaml' -o -name 'PackageInstance-*.yaml'";
      }
      {
        # The same page contrasts the audit bundle with the default
        # export mode. Run it so the contrast stays true.
        prepare = "kix export how-to-application --out ./handoff";
      }
    ];
  }

  {
    group = "how-to/application-receipt";
    page = "/docs/how-to/operate-a-cluster/inspect-a-deploy-receipt/";
    cwd = "kix-examples/";
    live = [
      {
        prepare = [
          "kix"
          "deploy"
          "how-to-application"
          "-y"
        ];
      }
      {
        capture = "active-receipt";
        run = [
          "kubectl"
          "get"
          "activations"
          "-l"
          "kix.run/cluster=how-to-application"
          "-o"
          "json"
        ];
        stdoutJq = ''.items[] | select(.status.phase == "Active") | .status.receipt'';
      }
    ];
  }

  # Ordering note: the two groups below run last on purpose. Each one
  # deliberately leaves the shared kind cluster in a state a later group
  # would trip over. The gc group deletes the resources of a renamed
  # instance, and the health-check group deploys a probe that fails,
  # which leaves a Degraded activation behind. A plain `kix deploy`
  # after a Degraded activation is a no-op, so any group preparing a
  # deploy after these would get the broken cluster, not a fresh one.

  {
    # Drop one instance from the cluster, then let gc find the resources
    # the previous activation left behind. The next group's deploy
    # restores them.
    group = "how-to/application-gc";
    page = "/docs/how-to/operate-a-cluster/garbage-collect-stale-resources/";
    cwd = "kix-examples/";
    live = [
      {
        prepare = [
          "kix"
          "deploy"
          "how-to-application"
          "-y"
        ];
      }
      # The retention page shows these flag combinations. They run here,
      # before the rename below, so they exercise the retention policy
      # on a cluster that has nothing to collect.
      {
        prepare = "kix gc how-to-application --keep 20 --keep-max 100 --keep-for 90d --yes";
      }
      {
        prepare = "kix gc how-to-application --keep 10 --keep-max 50 --keep-for off --yes";
      }
      {
        # Renaming the instance orphans everything the deployed
        # activation created under the old name, which is the situation
        # the page is about.
        mutate = {
          file = "how-to/application/cluster.nix";
          oldString = "preview = {";
          newString = "preview-renamed = {";
        };
      }
      {
        capture = "plan";
        run = [
          "kix"
          "gc"
          "how-to-application"
          "-y"
        ];
      }
      # No `--hard` capture on purpose. Hard mode sweeps every
      # kix-managed resource in the Kubernetes cluster and judges it
      # against this one cluster's build, so it would delete the
      # tutorial deployments the other live groups put here.
    ];
  }

  {
    group = "how-to/application-health-check";
    page = "/docs/how-to/author-packages-and-clusters/add-a-post-deploy-health-check/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "how-to-application"
        ];
      }
      {
        capture = "build";
        run = [
          "kix"
          "build"
          "how-to-application"
          "-o"
          "json"
        ];
        stdoutJq = ''.[] | select(.kind == "Job" and .metadata.name == "production-health")'';
      }
    ];
    live = [
      {
        capture = "deploy";
        run = [
          "kix"
          "deploy"
          "how-to-application"
          "-y"
        ];
      }
      {
        mutate = {
          file = "how-to/application/health-check.sh";
          oldString = "exit 0";
          newString = ''
            echo "the application returned an unexpected response"
            exit 1'';
        };
      }
      {
        capture = "deploy-failing-probe";
        run = [
          "kix"
          "deploy"
          "how-to-application"
          "-y"
        ];
        allowFailure = true;
      }
    ];
  }
]

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
#
#   { mutate = { file = "tutorial-04/cluster.nix";
#                oldString = "Hello"; newString = "Preview"; }; }
#       literal substitution against workspace/<file>. Preflight checks:
#       file must exist, oldString must match exactly once. Fails the
#       whole capture run on any preflight miss (no partial sidecars).
#
#   { prepare = [ "kix" "deploy" "example" "-y" ]; }
#       runs a prerequisite command without writing a sidecar. The command
#       must succeed. Use this for live state a later captured command needs,
#       such as deploying before `status` or `diff`.
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
    ];
  }

  {
    group = "how-to/policy-receipt-attestation";
    page = "/docs/how-to/policy-ci-and-compliance/attest-a-deployment-from-its-cluster-receipt/";
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

]

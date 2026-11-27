//! Integration test against a real kind cluster.
//!
//! Requires: `kind` and `kubectl` on PATH, and `nix`.
//! Creates a temporary kind cluster, deploys the `kind` cluster definition
//! (echo-server in its own namespace, with no conflicts with kind's built-ins),
//! and verifies deploy, local DAG diff, soft GC, and hard GC.
//!
//! Run with: cargo test --test kind_integration_test -- --ignored
//! (ignored by default because it requires kind and is slow)

use kix::manifest::keys;
use std::path::Path;
use std::process::Command;

fn repo_root() -> &'static Path {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .parent()
        .unwrap()
}

fn kix(kind_cluster: &str) -> assert_cmd::Command {
    let mut cmd = assert_cmd::Command::cargo_bin("kix").unwrap();
    cmd.env("NO_COLOR", "true");
    cmd.args(["--context", &format!("kind-{kind_cluster}")]);
    cmd.current_dir(repo_root());
    cmd
}

fn has_kind() -> bool {
    Command::new("kind").arg("version").output().is_ok()
}

fn has_kubectl() -> bool {
    Command::new("kubectl")
        .arg("version")
        .arg("--client")
        .output()
        .is_ok()
}

fn kind_create(name: &str) -> bool {
    Command::new("kind")
        .args(["create", "cluster", "--name", name])
        .output()
        .is_ok_and(|o| o.status.success())
}

fn kind_delete(name: &str) {
    let _ = Command::new("kind")
        .args(["delete", "cluster", "--name", name])
        .output();
}

fn kubectl(context: &str, args: &[&str]) -> std::process::Output {
    Command::new("kubectl")
        .arg("--context")
        .arg(context)
        .args(args)
        .output()
        .expect("kubectl should work")
}

fn kubectl_stdout(context: &str, args: &[&str]) -> String {
    let output = kubectl(context, args);
    String::from_utf8_lossy(&output.stdout).to_string()
}

/// Clear the activation cache for a Kix cluster name so the next deploy
/// sees no previous state, and release the Nix gc root Kix keeps on that
/// build. The cache persists across kind cluster recreations.
fn clear_activation_cache(kix_cluster: &str) {
    let dir = kix::eval::store::default_cache_dir().join("activations");
    let _ = std::fs::remove_file(dir.join(format!("{kix_cluster}.path")));
    let _ = std::fs::remove_file(dir.join(format!("{kix_cluster}.root")));
}

const KIND_CLUSTER: &str = "kix-integration";

/// Read and verify the plan in the plan file at `path`, returning it as JSON.
fn saved_plan(path: &Path) -> serde_json::Value {
    let file = std::fs::File::open(path).expect("the plan file");
    let (file, _) = kix::plan::file::PlanFile::verify(file).expect("a valid plan file");
    serde_json::to_value(&file.header().plan).unwrap()
}

/// Return `"<package> <bucket> <resource>"` for every object a plan document's
/// `packages` section lists as added, removed, or modified.
fn package_objects(doc: &serde_json::Value) -> std::collections::BTreeSet<String> {
    let mut out = std::collections::BTreeSet::new();
    let packages = &doc["packages"];
    let changed = packages["changed"].as_array().into_iter().flatten().chain(
        packages["cluster_level"]
            .as_object()
            .map(|_| &packages["cluster_level"]),
    );
    for c in changed {
        let key = c["key"].as_str().unwrap_or_default();
        for bucket in ["added_resources", "removed_resources"] {
            for r in c[bucket].as_array().into_iter().flatten() {
                out.insert(format!("{key} {bucket} {}", r.as_str().unwrap_or_default()));
            }
        }
        for m in c["modified_resources"].as_array().into_iter().flatten() {
            out.insert(format!(
                "{key} modified {}",
                m["resource"].as_str().unwrap_or_default()
            ));
        }
    }
    out
}
const KUBE_CTX: &str = "kind-kix-integration";
/// The Kix cluster name (from clusters/test-kind.nix, registered as "kind" in flake.nix)
const KIX_CLUSTER: &str = "kind";

#[test]
#[ignore] // Run explicitly: cargo test --test kind_integration_test -- --ignored
fn deploy_and_gc() {
    if !has_kind() || !has_kubectl() {
        eprintln!("skipping: kind or kubectl not available");
        return;
    }

    // Ensure clean state
    kind_delete(KIND_CLUSTER);
    clear_activation_cache(KIX_CLUSTER);

    if !kind_create(KIND_CLUSTER) {
        panic!("failed to create kind cluster");
    }

    // Always clean up the kind cluster
    struct CleanupGuard;
    impl Drop for CleanupGuard {
        fn drop(&mut self) {
            kind_delete(KIND_CLUSTER);
        }
    }
    let _guard = CleanupGuard;

    // Phase 0: Plan before the first deploy. Nothing exists yet, so the
    // objects in the namespace the deploy creates cannot be dry-run; the
    // plan says so and writes nothing.
    eprintln!("\n=== Phase 0: Plan a first deploy ===");

    let plan0_file =
        std::env::temp_dir().join(format!("kix-first-plan-{}.kixplan", std::process::id()));
    let plan0 = kix(KIND_CLUSTER)
        .args(["plan", KIX_CLUSTER, "--out", plan0_file.to_str().unwrap()])
        .output()
        .expect("plan should run");
    assert_eq!(
        plan0.status.code(),
        Some(2),
        "a first deploy changes something"
    );
    let doc0 = saved_plan(&plan0_file);
    let _ = std::fs::remove_file(&plan0_file);
    assert_eq!(doc0["made_by"], "dry_run");
    assert_eq!(doc0["admission"]["items"], serde_json::json!([]));
    assert!(
        doc0["not_checked"]
            .as_array()
            .unwrap()
            .iter()
            .any(|o| o["reason"] == "namespace_created_by_this_deploy"),
        "objects in the new namespace are not checked: {}",
        doc0["not_checked"]
    );
    let records = kubectl_stdout(KUBE_CTX, &["get", keys::ACTIVATIONS_CRD, "-o", "name"]);
    assert!(
        records.trim().is_empty(),
        "a plan writes no record: {records}"
    );

    // Phase 1: First deploy: everything created
    eprintln!("\n=== Phase 1: First deploy ===");

    let first = kix(KIND_CLUSTER)
        .args(["deploy", KIX_CLUSTER, "--yes"])
        .output()
        .expect("deploy command should run");

    let stdout1 = String::from_utf8_lossy(&first.stdout);
    eprintln!("{stdout1}");

    assert!(first.status.success(), "first deploy should succeed");
    assert!(stdout1.contains("created"), "should create resources");
    assert!(
        stdout1.contains("No previous deployment record on the cluster"),
        "should detect no previous activation"
    );

    // Verify resources on cluster
    let managed = kubectl_stdout(
        KUBE_CTX,
        &[
            "get",
            "all,configmap",
            "-n",
            "echo",
            "-l",
            "app.kubernetes.io/managed-by=kix",
            "-o",
            "name",
        ],
    );
    eprintln!("Managed resources:\n{managed}");
    assert!(!managed.trim().is_empty(), "should have managed resources");

    // Phase 2: Second deploy: local DAG diff, everything unchanged
    eprintln!("\n=== Phase 2: Second deploy (DAG diff) ===");

    let second = kix(KIND_CLUSTER)
        .args(["deploy", KIX_CLUSTER, "--yes"])
        .output()
        .expect("second deploy should run");

    let stdout2 = String::from_utf8_lossy(&second.stdout);
    eprintln!("{stdout2}");

    assert!(second.status.success(), "second deploy should succeed");
    assert!(
        stdout2.contains("Nothing to apply"),
        "should detect everything unchanged via local DAG diff"
    );
    assert!(
        stdout2.contains("Current deployment:"),
        "should plan against the cluster's Active record"
    );

    // Phase 2b: Plan and diff of a changed build list the same objects, and
    // the plan applies nothing.
    eprintln!("\n=== Phase 2b: kix plan and kix plan --read-only agree ===");

    let dir = std::env::temp_dir().join(format!("kix-saved-plan-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let unforced = dir.join("unforced.kixplan");
    let forced = dir.join("forced.kixplan");
    let diffed = dir.join("diff.kixplan");
    let plan = kix(KIND_CLUSTER)
        .args(["plan", "kind-v2", "--out", unforced.to_str().unwrap()])
        .output()
        .expect("plan should run");
    let diff = kix(KIND_CLUSTER)
        .args([
            "plan",
            "kind-v2",
            "--read-only",
            "--out",
            diffed.to_str().unwrap(),
        ])
        .output()
        .expect("diff should run");
    assert_eq!(
        plan.status.code(),
        Some(2),
        "{}",
        String::from_utf8_lossy(&plan.stderr)
    );
    assert_eq!(
        diff.status.code(),
        Some(2),
        "{}",
        String::from_utf8_lossy(&diff.stderr)
    );
    let plan_doc = saved_plan(&unforced);
    let diff_doc = saved_plan(&diffed);
    assert_eq!(plan_doc["made_by"], "dry_run");
    assert_eq!(diff_doc["made_by"], "live_read");
    assert_eq!(diff_doc["conflicts"]["status"], "not_checked");
    assert_eq!(
        package_objects(&plan_doc),
        package_objects(&diff_doc),
        "plan and diff list different objects"
    );
    let unchanged = kix(KIND_CLUSTER)
        .args(["plan", KIX_CLUSTER])
        .output()
        .expect("plan should run");
    assert!(
        unchanged.status.success(),
        "the plan of the deployed build is empty after planning kind-v2: {}",
        String::from_utf8_lossy(&unchanged.stdout)
    );

    // Phase 2c: A saved plan gates the deploy. A plan goes stale when a
    // direct edit makes a new conflict; the deploy of a plan made with
    // --force-conflicts takes the plan's flags, so it succeeds without the
    // flag on the command line; and the plan is stale once the cluster runs
    // that build.
    eprintln!("\n=== Phase 2c: kix deploy --plan ===");

    let check = |saved: &Path, extra: &[&str]| {
        let mut args = vec![
            "deploy",
            "kind-v2",
            "--plan",
            saved.to_str().unwrap(),
            "--dry-run",
        ];
        args.extend_from_slice(extra);
        kix(KIND_CLUSTER)
            .args(&args)
            .output()
            .expect("deploy --plan should run")
    };
    let mismatched_rules = |out: &std::process::Output| -> Vec<String> {
        let c: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
        c["mismatches"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|m| m["rule"].as_str().map(str::to_string))
            .collect()
    };

    let current = check(&unforced, &["-o", "json"]);
    assert_eq!(
        current.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&current.stderr)
    );

    // A saved diff lists no objects a deploy writes, so it is refused.
    let from_diff = check(&diffed, &[]);
    assert_eq!(
        from_diff.status.code(),
        Some(1),
        "{}",
        String::from_utf8_lossy(&from_diff.stderr)
    );
    let refusal = String::from_utf8_lossy(&from_diff.stderr).into_owned();
    assert!(
        refusal.contains("which only `kix plan` records"),
        "{refusal}"
    );

    let contradicted = check(&unforced, &["--prune"]);
    assert_eq!(contradicted.status.code(), Some(1));
    assert!(
        String::from_utf8_lossy(&contradicted.stderr).contains("--prune"),
        "{}",
        String::from_utf8_lossy(&contradicted.stderr)
    );

    // Direct edit of a field the deploy sets: kubectl now owns replicas.
    let deployment = kubectl_stdout(KUBE_CTX, &["get", "deploy", "-n", "echo", "-o", "name"]);
    let deployment = deployment.lines().next().expect("a Deployment").to_string();
    let scaled = kubectl(
        KUBE_CTX,
        &["scale", &deployment, "-n", "echo", "--replicas=3"],
    );
    assert!(scaled.status.success());
    let stale = check(&unforced, &["-o", "json"]);
    assert_eq!(
        stale.status.code(),
        Some(4),
        "{}",
        String::from_utf8_lossy(&stale.stderr)
    );
    assert_eq!(mismatched_rules(&stale), vec!["new_refusal"]);

    // The deploy itself refuses the stale plan and applies nothing.
    let refused = kix(KIND_CLUSTER)
        .args([
            "deploy",
            "kind-v2",
            "--plan",
            unforced.to_str().unwrap(),
            "--yes",
        ])
        .output()
        .expect("deploy --plan should run");
    assert_eq!(refused.status.code(), Some(4));
    let replicas = kubectl_stdout(
        KUBE_CTX,
        &[
            "get",
            &deployment,
            "-n",
            "echo",
            "-o",
            "jsonpath={.spec.replicas}",
        ],
    );
    assert_eq!(replicas.trim(), "3", "a refused deploy applies nothing");

    let forced_plan = kix(KIND_CLUSTER)
        .args([
            "plan",
            "kind-v2",
            "--force-conflicts",
            "--out",
            forced.to_str().unwrap(),
        ])
        .output()
        .expect("plan should run");
    assert_eq!(forced_plan.status.code(), Some(2));
    let deployed = kix(KIND_CLUSTER)
        .args([
            "deploy",
            "kind-v2",
            "--plan",
            forced.to_str().unwrap(),
            "--yes",
        ])
        .output()
        .expect("deploy --plan should run");
    assert!(
        deployed.status.success(),
        "the apply takes --force-conflicts from the plan: {}{}",
        String::from_utf8_lossy(&deployed.stdout),
        String::from_utf8_lossy(&deployed.stderr)
    );
    assert!(String::from_utf8_lossy(&deployed.stderr).contains("The reviewed plan matches"));
    let replicas = kubectl_stdout(
        KUBE_CTX,
        &[
            "get",
            &deployment,
            "-n",
            "echo",
            "-o",
            "jsonpath={.spec.replicas}",
        ],
    );
    assert_eq!(replicas.trim(), "2", "the build's replicas, not kubectl's");

    // The cluster now runs that build, so a deploy of it writes other
    // objects against another deployed build, and the deploy moved the
    // cluster's deploy lock to a later generation.
    let stale = check(&forced, &["-o", "json"]);
    assert_eq!(stale.status.code(), Some(4));
    assert_eq!(
        mismatched_rules(&stale),
        vec!["objects", "deployed_build", "generation"]
    );
    let _ = std::fs::remove_dir_all(&dir);

    // Put the first build back for the phases below.
    let back = kix(KIND_CLUSTER)
        .args(["deploy", KIX_CLUSTER, "--yes", "--prune"])
        .output()
        .expect("deploy should run");
    assert!(
        back.status.success(),
        "{}",
        String::from_utf8_lossy(&back.stderr)
    );

    // Phase 3: Soft GC: no garbage (same activation)
    eprintln!("\n=== Phase 3: Soft GC (no garbage expected) ===");

    let gc_soft = kix(KIND_CLUSTER)
        .args(["gc", KIX_CLUSTER, "--yes"])
        .output()
        .expect("soft gc should run");

    let gc_soft_out = String::from_utf8_lossy(&gc_soft.stdout);
    eprintln!("{gc_soft_out}");

    assert!(gc_soft.status.success(), "soft gc should succeed");
    assert!(
        gc_soft_out.contains("Nothing to delete"),
        "soft gc should find no garbage when nothing changed, got:\n{gc_soft_out}"
    );

    // Phase 4: Hard GC: no garbage (all resources match expected set)
    eprintln!("\n=== Phase 4: Hard GC (no garbage expected) ===");

    let gc_hard = kix(KIND_CLUSTER)
        .args(["gc", KIX_CLUSTER, "--full-scan", "--yes"])
        .output()
        .expect("hard gc should run");

    let gc_hard_out = String::from_utf8_lossy(&gc_hard.stdout);
    eprintln!("{gc_hard_out}");

    assert!(gc_hard.status.success(), "hard gc should succeed");
    assert!(
        gc_hard_out.contains("Nothing to delete"),
        "hard gc should find no garbage when cluster matches expected state, got:\n{gc_hard_out}"
    );

    // Phase 5: Hard GC: detect an orphaned resource created outside Kix
    eprintln!("\n=== Phase 5: Hard GC (detect orphan) ===");

    // Create a ConfigMap stamped like a Kix object, with an identity hash no
    // build has. It is written under Kix's field manager because a stamped
    // object with no `managedFields` entry for `kix` counts as a copy another
    // program made, which a full-scan gc keeps unless `--include copies` is passed.
    let orphan_dir = tempfile::tempdir().unwrap();
    let orphan_file = orphan_dir.path().join("orphan.yaml");
    std::fs::write(
        &orphan_file,
        format!(
            "apiVersion: v1\n\
             kind: ConfigMap\n\
             metadata:\n\
             \x20 name: orphan-test\n\
             \x20 namespace: echo\n\
             \x20 labels:\n\
             \x20   app.kubernetes.io/managed-by: kix\n\
             \x20 annotations:\n\
             \x20   {}: fake00000000orphan000000000000\n\
             data:\n\
             \x20 key: value\n",
            keys::IDENTITY_HASH
        ),
    )
    .unwrap();
    let create_result = kubectl(
        KUBE_CTX,
        &[
            "apply",
            "--server-side",
            "--field-manager=kix",
            "-f",
            orphan_file.to_str().unwrap(),
        ],
    );
    assert!(
        create_result.status.success(),
        "should create test configmap: {}",
        String::from_utf8_lossy(&create_result.stderr)
    );

    // Hard GC should now detect this as garbage
    let gc_orphan = kix(KIND_CLUSTER)
        .args(["gc", KIX_CLUSTER, "--full-scan", "--yes"])
        .output()
        .expect("hard gc with orphan should run");

    let gc_orphan_out = String::from_utf8_lossy(&gc_orphan.stdout);
    eprintln!("{gc_orphan_out}");

    assert!(
        gc_orphan_out.contains("orphan-test"),
        "hard gc should detect the orphan-test configmap as garbage, got:\n{gc_orphan_out}"
    );
    assert!(
        gc_orphan_out.contains("deleted"),
        "hard gc should delete the orphan, got:\n{gc_orphan_out}"
    );

    // Verify orphan is gone
    let check_orphan = kubectl_stdout(
        KUBE_CTX,
        &[
            "get",
            "configmap",
            "orphan-test",
            "-n",
            "echo",
            "--ignore-not-found",
            "-o",
            "name",
        ],
    );
    assert!(
        check_orphan.trim().is_empty(),
        "orphan-test should be deleted from cluster"
    );

    // Phase 6: An unchanged object that something in the deploy depends on
    // is checked before the dependent runs. The `kind-port` build changes
    // the Service, which depends on the Deployment, and leaves the
    // Deployment unchanged. Broken with kubectl first, the Deployment fails
    // the deploy on itself; repaired, the same deploy goes through. The
    // deploy starts before the new pod reports ImagePullBackOff. The check
    // waits for it, because the old pod that still runs does not make the
    // Deployment ready.
    eprintln!("\n=== Phase 6: Unchanged dependency checked before its dependent ===");

    let broken = kubectl(
        KUBE_CTX,
        &[
            "set",
            "image",
            "deployment/echo-server",
            "-n",
            "echo",
            "nginx=docker.io/nginxinc/nginx-unprivileged:no-such-tag",
        ],
    );
    assert!(broken.status.success(), "should set a bad image");

    let over_broken = kix(KIND_CLUSTER)
        .args(["deploy", "kind-port", "--yes", "--timeout", "60s"])
        .output()
        .expect("deploy should run");
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&over_broken.stdout),
        String::from_utf8_lossy(&over_broken.stderr)
    );
    eprintln!("{text}");
    assert!(
        !over_broken.status.success(),
        "a deploy over a broken unchanged Deployment fails"
    );
    assert!(
        text.contains("Deployment/echo-server@echo")
            && text.contains("ImagePullBackOff")
            && text.contains("This deploy did not change it"),
        "the failure names the unchanged Deployment with its own status, got:\n{text}"
    );
    assert!(
        text.contains("objects that depend on it") || text.contains("object that depends on it"),
        "the failure says what was not deployed, got:\n{text}"
    );
    let port = kubectl_stdout(
        KUBE_CTX,
        &[
            "get",
            "service/echo-server",
            "-n",
            "echo",
            "-o",
            "jsonpath={.spec.ports[0].port}",
        ],
    );
    assert_eq!(
        port.trim(),
        "80",
        "the Service that depends on it is not applied"
    );

    let undone = kubectl(
        KUBE_CTX,
        &["rollout", "undo", "deployment/echo-server", "-n", "echo"],
    );
    assert!(undone.status.success(), "should undo the bad image");
    let rolled = kubectl(
        KUBE_CTX,
        &[
            "rollout",
            "status",
            "deployment/echo-server",
            "-n",
            "echo",
            "--timeout=120s",
        ],
    );
    assert!(rolled.status.success(), "the Deployment should recover");

    let over_repaired = kix(KIND_CLUSTER)
        .args(["deploy", "kind-port", "--yes"])
        .output()
        .expect("deploy should run");
    assert!(
        over_repaired.status.success(),
        "the same deploy succeeds once the Deployment is healthy: {}{}",
        String::from_utf8_lossy(&over_repaired.stdout),
        String::from_utf8_lossy(&over_repaired.stderr)
    );
    let port = kubectl_stdout(
        KUBE_CTX,
        &[
            "get",
            "service/echo-server",
            "-n",
            "echo",
            "-o",
            "jsonpath={.spec.ports[0].port}",
        ],
    );
    assert_eq!(port.trim(), "8081", "the Service is applied");

    eprintln!("\n=== All phases passed ===");
}

/// A flake with Kix clusters `sweep-a` and `sweep-b`, echo servers in
/// namespaces of their own, both deploying the `shared-role` package into
/// the namespace `shared`: a ClusterRole and a ConfigMap.
struct TwoClusters {
    dir: tempfile::TempDir,
}

const SHARED_ROLE_NIX: &str = r#"{ scope, ... }:
{
  meta = {
    version = "1";
    description = "Objects both test clusters deploy";
    owner = "test";
  };
  build =
    { self, ... }:
    {
      role = scope.mkClusterResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "sweep-test-reader";
        extra.rules = [
          {
            apiGroups = [ "" ];
            resources = [ "configmaps" ];
            verbs = [ "get" ];
          }
        ];
      };
      note = scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "sweep-test-shared";
        extra.data.owner = "both";
      };
      root = self.role;
    };
}
"#;

impl TwoClusters {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let lock: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(repo_root().join("flake.lock")).unwrap())
                .unwrap();
        let rev = lock["nodes"]["nixpkgs"]["locked"]["rev"].as_str().unwrap();
        let flake = format!(
            r#"{{
  inputs = {{
    nixpkgs.url = "github:NixOS/nixpkgs/{rev}";
    kix.url = "git+file://{}?dir=kix";
  }};
  outputs =
    inputs:
    inputs.kix.lib.mkFlake {{
      inherit inputs;
      systems = [ "x86_64-linux" ];
      clusters = {{
        sweep-a = ./a.nix;
        sweep-b = ./b.nix;
      }};
    }};
}}
"#,
            repo_root().display()
        );
        let t = TwoClusters { dir };
        t.write("flake.nix", &flake);
        t.write("shared-role.nix", SHARED_ROLE_NIX);
        t.write_cluster("a", "hello from sweep-a", true);
        t.write_cluster("b", "hello from sweep-b", true);
        git(t.path(), &["init", "-q"]);
        git(t.path(), &["add", "-A"]);
        // Kix reads the project's Kix library from flake.lock before it
        // runs a command. The library is a local repository with no ref,
        // so Kix uses it as a development library.
        let nix = kix::runtime::program_path(kix::runtime::Tool::Nix, kix::runtime::Want::Shipped)
            .unwrap();
        let out = std::process::Command::new(nix)
            .args([
                "--extra-experimental-features",
                "nix-command flakes",
                "flake",
                "lock",
            ])
            .current_dir(t.path())
            .output()
            .unwrap();
        assert!(out.status.success(), "nix flake lock: {out:?}");
        git(t.path(), &["add", "-A"]);
        t
    }

    fn path(&self) -> &Path {
        self.dir.path()
    }

    fn write(&self, name: &str, text: &str) {
        std::fs::write(self.path().join(name), text).unwrap();
        if self.path().join(".git").exists() {
            git(self.path(), &["add", "-A"]);
        }
    }

    fn write_cluster(&self, id: &str, message: &str, shared: bool) {
        self.write_cluster_bound(id, message, shared, None);
    }

    /// Write the definition of `sweep-<id>`, bound to the Kubernetes cluster
    /// `kubernetes_uid` when given.
    fn write_cluster_bound(
        &self,
        id: &str,
        message: &str,
        shared: bool,
        kubernetes_uid: Option<&str>,
    ) {
        let package = shared.then_some("shared-role.nix");
        self.write_cluster_with(id, message, package, kubernetes_uid);
    }

    /// Write the definition of `sweep-<id>`, deploying the shared package
    /// from the file `package` when given, bound to the Kubernetes cluster
    /// `kubernetes_uid` when given.
    fn write_cluster_with(
        &self,
        id: &str,
        message: &str,
        package: Option<&str>,
        kubernetes_uid: Option<&str>,
    ) {
        let shared = match package {
            Some(file) => format!(
                "namespaces.shared = {{ }};\n      instances.shared.shared-role.package = import ./{file};"
            ),
            None => String::new(),
        };
        let bound = match kubernetes_uid {
            Some(uid) => format!("cluster.kubernetes.uid = \"{uid}\";"),
            None => String::new(),
        };
        let text = format!(
            r#"{{ kix, packages }}:
kix.buildCluster {{
  name = "sweep-{id}";
  modules = [
    kix.flavors.kind
    {{
      namespaces.echo-{id} = {{ }};
      {bound}
      {shared}
      instances.echo-{id}.echo-server = {{
        package = packages.echo-server;
        config.message = "{message}";
      }};
    }}
  ];
}}
"#
        );
        self.write(&format!("{id}.nix"), &text);
    }

    fn kix(&self, kube_ctx: &str, args: &[&str]) -> (bool, String) {
        let out = assert_cmd::Command::cargo_bin("kix")
            .unwrap()
            .env("NO_COLOR", "true")
            .arg("--flake")
            .arg(self.path())
            .args(["--context", kube_ctx])
            .args(args)
            .output()
            .expect("kix should run");
        let text = format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        eprintln!("$ kix {}\n{text}", args.join(" "));
        (out.status.success(), text)
    }
}

fn git(dir: &Path, args: &[&str]) {
    let ok = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .is_ok_and(|o| o.status.success());
    assert!(ok, "git {args:?} failed");
}

/// Verify that every object of Kix cluster `sweep-b` survives `sweep-a`'s
/// commands.
fn assert_b_intact(kube_ctx: &str) {
    for (kind, ns, name) in [
        ("deployment", "echo-b", "echo-server"),
        ("service", "echo-b", "echo-server"),
        ("configmap", "echo-b", "echo-server"),
        ("clusterrole", "", "sweep-test-reader"),
        ("configmap", "shared", "sweep-test-shared"),
    ] {
        let mut args = vec!["get", kind, name, "-o", "name"];
        if !ns.is_empty() {
            args.extend(["-n", ns]);
        }
        let out = kubectl(kube_ctx, &args);
        assert!(
            out.status.success(),
            "{kind}/{name} of sweep-b is gone: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
}

/// Verify that two Kix clusters can deploy into one kind cluster while sharing
/// a ClusterRole and a ConfigMap. Every command run for `sweep-a` leaves
/// `sweep-b`'s objects alone, and a prune by `sweep-a` keeps what `sweep-b`
/// still deploys.
///
/// The kind cluster is `$KIX_KIND_CLUSTER` (default `kix-sweep-scope`); the
/// test creates and deletes it.
#[test]
#[ignore] // Run explicitly: cargo test --test kind_integration_test -- --ignored
fn two_kix_clusters_share_one_kind_cluster() {
    if !has_kind() || !has_kubectl() {
        eprintln!("skipping: kind or kubectl not available");
        return;
    }
    let kind_cluster =
        std::env::var("KIX_KIND_CLUSTER").unwrap_or_else(|_| "kix-sweep-scope".into());
    let ctx = format!("kind-{kind_cluster}");
    kind_delete(&kind_cluster);
    clear_activation_cache("sweep-a");
    clear_activation_cache("sweep-b");
    assert!(kind_create(&kind_cluster), "failed to create kind cluster");
    struct Cleanup(String);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            kind_delete(&self.0);
        }
    }
    let _cleanup = Cleanup(kind_cluster.clone());

    let flake = TwoClusters::new();
    assert!(flake.kix(&ctx, &["deploy", "sweep-a", "--yes"]).0);
    assert!(flake.kix(&ctx, &["deploy", "sweep-b", "--yes"]).0);
    assert_b_intact(&ctx);
    // Each Kix cluster applies under its own field manager, so the shared
    // ConfigMap shows both.
    assert_eq!(
        apply_managers(&ctx, "configmap", "shared", "sweep-test-shared"),
        ["kix/sweep-a", "kix/sweep-b"]
    );

    // 1. `kix plan sweep-a --read-only` reports no change: sweep-b's objects are not
    //    removals.
    let (ok, out) = flake.kix(&ctx, &["plan", "sweep-a", "--read-only"]);
    assert!(ok, "diff sweep-a should report no change:\n{out}");
    assert!(out.contains("belong to Kix cluster 'sweep-b'"), "{out}");

    // 2. `kix status sweep-a` and `kix snapshot sweep-a` contain none
    //    of sweep-b's objects.
    let (ok, out) = flake.kix(&ctx, &["status", "sweep-a"]);
    assert!(ok && !out.contains("echo-b"), "{out}");
    let snap = tempfile::tempdir().unwrap();
    let snap_dir = snap.path().join("a");
    let (ok, _) = flake.kix(
        &ctx,
        &["snapshot", "sweep-a", "--out", snap_dir.to_str().unwrap()],
    );
    assert!(ok);
    assert!(!snap_dir.join("echo-b").exists());
    assert!(snap_dir.join("echo-a").exists());

    // 3. The rebuild-from-live path: the Active record's build is not in
    //    the store, so deploy reads the previous state from live objects.
    //    Kix finds a record's build in the local store by its hash whatever
    //    the record's `built-via` says, so the build itself is deleted,
    //    after releasing the gc root Kix keeps on it.
    let records = format!("activations.{}", keys::DOMAIN);
    let selector = format!("{}=sweep-a", keys::CLUSTER_LABEL);
    let listed: serde_json::Value = serde_json::from_str(&kubectl_stdout(
        &ctx,
        &["get", &records, "-l", &selector, "-o", "json"],
    ))
    .unwrap();
    let built_via = listed["items"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|r| r["status"]["phase"] == "Active")
        .and_then(|r| r["metadata"]["annotations"][keys::BUILT_VIA].as_str())
        .expect("the Active record names its build")
        .to_string();
    assert!(
        kix::eval::store::exists(Path::new(&built_via)),
        "the Active record's build {built_via} should be in Kix's local store"
    );
    clear_activation_cache("sweep-a");
    let deleted = kix::runtime::tool(kix::runtime::Tool::Nix, kix::runtime::Want::Shipped)
        .expect("the Kix runtime has nix")
        .args(["store", "delete", &built_via])
        .output()
        .expect("nix should run");
    assert!(
        deleted.status.success(),
        "nix store delete {built_via}: {}",
        String::from_utf8_lossy(&deleted.stderr)
    );
    flake.write_cluster("a", "hello again from sweep-a", true);
    let (ok, out) = flake.kix(&ctx, &["deploy", "sweep-a", "--prune", "--yes"]);
    assert!(ok, "{out}");
    assert!(
        out.contains("Reading live objects from the cluster"),
        "{out}"
    );
    assert_b_intact(&ctx);

    // 4. `kix gc sweep-a --full-scan --yes` deletes nothing of sweep-b's.
    let (ok, out) = flake.kix(&ctx, &["gc", "sweep-a", "--full-scan", "--yes"]);
    assert!(ok, "{out}");
    assert_b_intact(&ctx);

    // 5. sweep-a drops the shared package; its prune keeps what sweep-b
    //    still deploys, and leaves sweep-b's field manager on it.
    flake.write_cluster("a", "hello again from sweep-a", false);
    let (ok, out) = flake.kix(&ctx, &["deploy", "sweep-a", "--prune", "--yes"]);
    assert!(ok, "{out}");
    assert!(
        out.contains("kept ClusterRole.rbac.authorization.k8s.io/sweep-test-reader")
            && out.contains("still deployed by Kix cluster sweep-b"),
        "{out}"
    );
    assert_b_intact(&ctx);
    assert!(
        apply_managers(&ctx, "configmap", "shared", "sweep-test-shared")
            .contains(&"kix/sweep-b".to_string())
    );
    // sweep-b deploys again with nothing to change, and still has the
    // shared objects.
    let (ok, out) = flake.kix(&ctx, &["deploy", "sweep-b", "--prune", "--yes"]);
    assert!(ok, "{out}");
    assert_b_intact(&ctx);
    let (ok, out) = flake.kix(&ctx, &["gc", "sweep-a", "--full-scan", "--yes"]);
    assert!(ok, "{out}");
    assert_b_intact(&ctx);

    // `--include unattributed` needs `--full-scan`.
    let (ok, out) = flake.kix(&ctx, &["gc", "sweep-a", "--include", "unattributed"]);
    assert!(!ok && out.contains("--full-scan"), "{out}");

    // 6. Binding. `kix status -v` shows the kind cluster's ID, and sweep-a
    //    bound to it deploys and labels its record. From then on the
    //    unbound sweep-b is refused, a sweep-b bound to another ID is
    //    refused before the plan, and a sweep-b bound to this ID deploys.
    //    `kix plan --read-only` stays read-only and is not checked.
    let uid = kubectl_stdout(
        &ctx,
        &[
            "get",
            "namespace",
            "kube-system",
            "-o",
            "jsonpath={.metadata.uid}",
        ],
    );
    let uid = uid.trim().to_string();
    let (ok, out) = flake.kix(&ctx, &["status", "sweep-a", "-v"]);
    assert!(
        ok && out.contains(&format!("Kubernetes cluster ID: {uid}")),
        "{out}"
    );
    flake.write_cluster_bound("a", "hello from bound sweep-a", false, Some(&uid));
    let (ok, out) = flake.kix(&ctx, &["deploy", "sweep-a", "--yes"]);
    assert!(ok, "{out}");
    let labelled = kubectl_stdout(
        &ctx,
        &[
            "get",
            &records,
            "-l",
            &format!("{}={uid}", keys::KUBERNETES_UID),
            "-o",
            "jsonpath={.items[*].metadata.labels.kix\\.run/cluster}",
        ],
    );
    assert!(labelled.contains("sweep-a"), "{labelled}");

    let (ok, out) = flake.kix(&ctx, &["deploy", "sweep-b", "--yes"]);
    let out = unwrapped(&out);
    assert!(
        !ok && out.contains("sweep-b's definition does not set cluster.kubernetes.uid"),
        "{out}"
    );
    assert!(
        out.contains(&format!(
            "sweep-a was deployed here with cluster.kubernetes.uid = \"{uid}\""
        )),
        "{out}"
    );
    let (ok, out) = flake.kix(&ctx, &["plan", "sweep-b", "--read-only"]);
    assert!(ok, "diff is read-only and not checked:\n{out}");
    assert_b_intact(&ctx);

    let elsewhere = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d";
    flake.write_cluster_bound("b", "hello from sweep-b", true, Some(elsewhere));
    let (ok, out) = flake.kix(&ctx, &["plan", "sweep-b"]);
    let out = unwrapped(&out);
    assert!(
        !ok && out.contains(&format!(
            "sweep-b's definition sets cluster.kubernetes.uid = \"{elsewhere}\""
        )),
        "{out}"
    );
    assert!(
        out.contains(&format!(
            "This cluster's kube-system namespace has UID \"{uid}\"."
        )),
        "{out}"
    );

    flake.write_cluster_bound("b", "hello from bound sweep-b", true, Some(&uid));
    let (ok, out) = flake.kix(&ctx, &["deploy", "sweep-b", "--yes"]);
    assert!(ok, "{out}");
    assert_b_intact(&ctx);
}

/// Return the field managers with an `Apply` entry on the object `name` of
/// `kind` in `namespace`, sorted.
fn apply_managers(kube_ctx: &str, kind: &str, namespace: &str, name: &str) -> Vec<String> {
    let text = kubectl_stdout(
        kube_ctx,
        &[
            "get",
            kind,
            name,
            "-n",
            namespace,
            "--show-managed-fields",
            "-o",
            "json",
        ],
    );
    let obj: serde_json::Value = serde_json::from_str(&text).unwrap();
    let mut managers: Vec<String> = obj["metadata"]["managedFields"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|e| e["operation"] == "Apply" && e["subresource"].is_null())
        .filter_map(|e| e["manager"].as_str().map(str::to_string))
        .collect();
    managers.sort();
    managers.dedup();
    managers
}

/// Verify that two Kix clusters that render a shared object differently
/// are refused, and that the message names the other Kix cluster and the
/// field. Taking the field with `--force-conflicts` moves the refusal to the
/// other Kix cluster's next deploy.
///
/// The kind cluster is `$KIX_KIND_CLUSTER` (default `kix-shared-conflict`);
/// the test creates and deletes it.
#[test]
#[ignore] // Run explicitly: cargo test --test kind_integration_test -- --ignored
fn two_kix_clusters_that_render_a_shared_object_differently_are_refused() {
    if !has_kind() || !has_kubectl() {
        eprintln!("skipping: kind or kubectl not available");
        return;
    }
    let kind_cluster =
        std::env::var("KIX_KIND_CLUSTER").unwrap_or_else(|_| "kix-shared-conflict".into());
    let ctx = format!("kind-{kind_cluster}");
    kind_delete(&kind_cluster);
    clear_activation_cache("sweep-a");
    clear_activation_cache("sweep-b");
    assert!(kind_create(&kind_cluster), "failed to create kind cluster");
    struct Cleanup(String);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            kind_delete(&self.0);
        }
    }
    let _cleanup = Cleanup(kind_cluster.clone());

    let flake = TwoClusters::new();
    flake.write(
        "shared-role-b.nix",
        &SHARED_ROLE_NIX.replace(r#"owner = "both";"#, r#"owner = "only-b";"#),
    );
    flake.write_cluster_with("b", "hello from sweep-b", Some("shared-role-b.nix"), None);
    assert!(flake.kix(&ctx, &["deploy", "sweep-a", "--yes"]).0);

    let (ok, out) = flake.kix(&ctx, &["deploy", "sweep-b", "--yes"]);
    let out = unwrapped(&out);
    assert!(!ok, "{out}");
    for part in [
        "ConfigMap/sweep-test-shared@shared was not updated.",
        "Kix cluster `sweep-a` also deploys it",
        ".data.owner",
        "`--force-conflicts`",
    ] {
        assert!(out.contains(part), "{part}:\n{out}");
    }
    let owner = kubectl_stdout(
        &ctx,
        &[
            "get",
            "configmap",
            "sweep-test-shared",
            "-n",
            "shared",
            "-o",
            "jsonpath={.data.owner}",
        ],
    );
    assert_eq!(owner.trim(), "both", "sweep-a's value stays");

    let (ok, out) = flake.kix(&ctx, &["deploy", "sweep-b", "--force-conflicts", "--yes"]);
    assert!(ok, "{out}");
    let (ok, out) = flake.kix(&ctx, &["deploy", "sweep-a", "--yes"]);
    let out = unwrapped(&out);
    assert!(
        !ok && out.contains("Kix cluster `sweep-b` also deploys it"),
        "{out}"
    );
}

/// Return `out` with the line wrapping of the error printer undone: the
/// `│` gutter is removed and wrapped lines are joined, without a space
/// after a line that ends in a hyphen, so a message reads as one line.
fn unwrapped(out: &str) -> String {
    let mut text = String::new();
    for line in out.lines() {
        let line = line.trim_start().trim_start_matches(['│', '×']).trim();
        if line.is_empty() {
            continue;
        }
        if !text.is_empty() && !text.ends_with('-') {
            text.push(' ');
        }
        text.push_str(line);
    }
    text
}

/// A package of two ConfigMaps: `hold-test-config` names
/// `hold-test-base`, so it depends on it.
const HOLD_NIX: &str = r#"{ scope, ... }:
{
  meta = {
    version = "1";
    description = "A ConfigMap that depends on another";
    owner = "test";
  };
  build =
    { self, ... }:
    {
      base = scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "hold-test-base";
        extra.data.role = "needed";
      };
      config = scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "hold-test-config";
        extra.data.base = self.base.out.name;
      };
      root = self.config;
    };
}
"#;

/// Write the flake of the Kix cluster `hold` into `dir`, with the `hold`
/// package when `with_package` is set.
fn write_hold_cluster(dir: &Path, with_package: bool) {
    let instance = if with_package {
        "instances.hold-test.hold.package = import ./hold.nix;"
    } else {
        ""
    };
    let text = format!(
        r#"{{ kix, packages }}:
kix.buildCluster {{
  name = "hold";
  modules = [
    kix.flavors.kind
    {{
      namespaces.hold-test = {{ }};
      {instance}
    }}
  ];
}}
"#
    );
    std::fs::write(dir.join("hold-cluster.nix"), text).unwrap();
    git(dir, &["add", "-A"]);
}

/// Verify that a prune waits for each deleted object to be gone. A
/// ConfigMap that keeps a finalizer fails the deploy with exit code 1 and
/// a message that names the finalizer, and the ConfigMap it depends on
/// stays. Once the finalizer is removed, the next prune deletes both.
///
/// The kind cluster is `$KIX_KIND_CLUSTER` (default `kix-delete-wait`); the
/// test creates and deletes it.
#[test]
#[ignore] // Run explicitly: cargo test --test kind_integration_test -- --ignored
fn a_prune_waits_for_finalizers() {
    if !has_kind() || !has_kubectl() {
        eprintln!("skipping: kind or kubectl not available");
        return;
    }
    let kind_cluster =
        std::env::var("KIX_KIND_CLUSTER").unwrap_or_else(|_| "kix-delete-wait".into());
    let ctx = format!("kind-{kind_cluster}");
    kind_delete(&kind_cluster);
    clear_activation_cache("hold");
    assert!(kind_create(&kind_cluster), "failed to create kind cluster");
    struct Cleanup(String);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            kind_delete(&self.0);
        }
    }
    let _cleanup = Cleanup(kind_cluster.clone());

    // The flake of TwoClusters, with one more cluster.
    let flake = TwoClusters::new();
    let flake_nix = std::fs::read_to_string(flake.path().join("flake.nix"))
        .unwrap()
        .replace(
            "sweep-b = ./b.nix;",
            "sweep-b = ./b.nix;\n        hold = ./hold-cluster.nix;",
        );
    flake.write("flake.nix", &flake_nix);
    flake.write("hold.nix", HOLD_NIX);
    write_hold_cluster(flake.path(), true);

    let (ok, out) = flake.kix(&ctx, &["deploy", "hold", "--yes"]);
    assert!(ok, "{out}");
    let patch = kubectl(
        &ctx,
        &[
            "-n",
            "hold-test",
            "patch",
            "configmap",
            "hold-test-config",
            "--type=merge",
            "-p",
            r#"{"metadata":{"finalizers":["example.com/hold"]}}"#,
        ],
    );
    assert!(patch.status.success(), "{patch:?}");

    write_hold_cluster(flake.path(), false);
    let out = assert_cmd::Command::cargo_bin("kix")
        .unwrap()
        .env("NO_COLOR", "true")
        .arg("--flake")
        .arg(flake.path())
        .args(["--context", &ctx])
        .args(["deploy", "hold", "--prune", "--yes", "--timeout", "10s"])
        .output()
        .expect("kix should run");
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    eprintln!("$ kix deploy hold --prune --yes --timeout 10s\n{text}");
    assert_eq!(out.status.code(), Some(1), "{text}");
    assert!(text.contains("[K2794]"), "{text}");
    assert!(text.contains("example.com/hold"), "{text}");
    assert!(
        text.contains("kubectl -n hold-test patch configmap hold-test-config"),
        "{text}"
    );
    let base = kubectl(
        &ctx,
        &["-n", "hold-test", "get", "configmap", "hold-test-base"],
    );
    assert!(
        base.status.success(),
        "the ConfigMap the stuck one needs was deleted"
    );

    let unpatch = kubectl(
        &ctx,
        &[
            "-n",
            "hold-test",
            "patch",
            "configmap",
            "hold-test-config",
            "--type=merge",
            "-p",
            r#"{"metadata":{"finalizers":null}}"#,
        ],
    );
    assert!(unpatch.status.success(), "{unpatch:?}");
    let (ok, out) = flake.kix(&ctx, &["deploy", "hold", "--prune", "--yes"]);
    assert!(ok, "{out}");
    for name in ["hold-test-config", "hold-test-base"] {
        let gone = kubectl(&ctx, &["-n", "hold-test", "get", "configmap", name]);
        assert!(!gone.status.success(), "{name} is still on the cluster");
    }
}

/// Verify that a deploy waits for an object of the build that is being
/// deleted, then creates it again. A ConfigMap held by a finalizer is
/// deleted. `kix plan --reconcile` lists it as being deleted, in its text
/// and in the plan file. `kix deploy --reconcile` waits until the finalizer is removed and
/// then creates the ConfigMap, which then has no `deletionTimestamp`.
///
/// The kind cluster is `$KIX_KIND_CLUSTER` (default `kix-apply-wait`); the
/// test creates and deletes it.
#[test]
#[ignore] // Run explicitly: cargo test --test kind_integration_test -- --ignored
fn a_deploy_waits_for_an_object_being_deleted_then_creates_it() {
    if !has_kind() || !has_kubectl() {
        eprintln!("skipping: kind or kubectl not available");
        return;
    }
    let kind_cluster =
        std::env::var("KIX_KIND_CLUSTER").unwrap_or_else(|_| "kix-apply-wait".into());
    let ctx = format!("kind-{kind_cluster}");
    kind_delete(&kind_cluster);
    clear_activation_cache("hold");
    assert!(kind_create(&kind_cluster), "failed to create kind cluster");
    struct Cleanup(String);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            kind_delete(&self.0);
        }
    }
    let _cleanup = Cleanup(kind_cluster.clone());

    let flake = TwoClusters::new();
    let flake_nix = std::fs::read_to_string(flake.path().join("flake.nix"))
        .unwrap()
        .replace(
            "sweep-b = ./b.nix;",
            "sweep-b = ./b.nix;\n        hold = ./hold-cluster.nix;",
        );
    flake.write("flake.nix", &flake_nix);
    flake.write("hold.nix", HOLD_NIX);
    write_hold_cluster(flake.path(), true);

    let (ok, out) = flake.kix(&ctx, &["deploy", "hold", "--yes"]);
    assert!(ok, "{out}");
    let cm = ["-n", "hold-test", "configmap", "hold-test-config"];
    let patch = kubectl(
        &ctx,
        &[
            "patch",
            cm[0],
            cm[1],
            cm[2],
            cm[3],
            "--type=merge",
            "-p",
            r#"{"metadata":{"finalizers":["example.com/hold"]}}"#,
        ],
    );
    assert!(patch.status.success(), "{patch:?}");
    let delete = kubectl(
        &ctx,
        &["delete", cm[0], cm[1], cm[2], cm[3], "--wait=false"],
    );
    assert!(delete.status.success(), "{delete:?}");
    let old_uid = kubectl_stdout(
        &ctx,
        &[
            "get",
            cm[0],
            cm[1],
            cm[2],
            cm[3],
            "-o",
            "jsonpath={.metadata.uid}",
        ],
    );
    assert!(!old_uid.is_empty());

    let (_, text) = flake.kix(&ctx, &["plan", "hold", "--reconcile"]);
    assert!(
        text.contains("being deleted on the cluster"),
        "the plan does not list the ConfigMap being deleted:\n{text}"
    );
    assert!(text.contains("waiting for example.com/hold"), "{text}");
    let plan_file = flake.path().join("hold.kixplan");
    let (_, text) = flake.kix(
        &ctx,
        &[
            "plan",
            "hold",
            "--reconcile",
            "--out",
            plan_file.to_str().unwrap(),
        ],
    );
    assert!(plan_file.exists(), "{text}");
    let doc = saved_plan(&plan_file);
    let listed = &doc["being_deleted"];
    assert_eq!(
        listed[0]["resource"], "ConfigMap/hold-test-config@hold-test",
        "{listed}"
    );
    assert_eq!(listed[0]["finalizers"][0], "example.com/hold", "{listed}");
    assert_eq!(listed[0]["holds_data"], false, "{listed}");

    let mut deploy = std::process::Command::new(assert_cmd::cargo::cargo_bin("kix"))
        .env("NO_COLOR", "true")
        .arg("--flake")
        .arg(flake.path())
        .args(["--context", &ctx])
        .args(["deploy", "hold", "--reconcile", "--yes", "--timeout", "2m"])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .expect("kix should run");
    std::thread::sleep(std::time::Duration::from_secs(15));
    assert!(
        deploy.try_wait().unwrap().is_none(),
        "the deploy finished while the ConfigMap was still being deleted"
    );
    let unpatch = kubectl(
        &ctx,
        &[
            "patch",
            cm[0],
            cm[1],
            cm[2],
            cm[3],
            "--type=merge",
            "-p",
            r#"{"metadata":{"finalizers":null}}"#,
        ],
    );
    assert!(unpatch.status.success(), "{unpatch:?}");
    let out = deploy.wait_with_output().unwrap();
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    eprintln!("$ kix deploy hold --reconcile --yes --timeout 2m\n{text}");
    assert!(out.status.success(), "{text}");
    let new_uid = kubectl_stdout(
        &ctx,
        &[
            "get",
            cm[0],
            cm[1],
            cm[2],
            cm[3],
            "-o",
            "jsonpath={.metadata.uid}",
        ],
    );
    assert!(!new_uid.is_empty(), "the ConfigMap was not created again");
    assert_ne!(new_uid, old_uid, "the ConfigMap is still the old object");
    let deleting = kubectl_stdout(
        &ctx,
        &[
            "get",
            cm[0],
            cm[1],
            cm[2],
            cm[3],
            "-o",
            "jsonpath={.metadata.deletionTimestamp}",
        ],
    );
    assert!(deleting.is_empty(), "the new ConfigMap is being deleted");
}

const DRIFT_NIX: &str = r#"{ scope, ... }:
{
  meta = {
    version = "1";
    description = "Two ConfigMaps, one with a field another controller sets";
    owner = "test";
  };
  build =
    { self, ... }:
    {
      ceded = scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "drift-ceded";
        extra.data = { owned = "kix"; rotated = "initial"; };
        ownership.cede = [ "data.rotated" ];
      };
      edited = scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "drift-edited";
        extra.data.value = "kix";
      };
      root = self.edited;
    };
}
"#;

/// Verify, against a real API server, what a deploy does to drift. Another
/// field manager changes a field the package cedes and a field it does not.
/// The next plan writes only the object whose field the package does not
/// cede. The deploy takes that field back with force and leaves the ceded
/// field to its manager. The plan after that writes nothing.
///
/// The kind cluster is `$KIX_KIND_CLUSTER` (default `kix-drift`); the test
/// creates and deletes it.
#[test]
#[ignore] // Run explicitly: cargo test --test kind_integration_test -- --ignored
fn drift_is_reverted_and_ceded_fields_are_left_alone() {
    if !has_kind() || !has_kubectl() {
        eprintln!("skipping: kind or kubectl not available");
        return;
    }
    let kind_cluster = std::env::var("KIX_KIND_CLUSTER").unwrap_or_else(|_| "kix-drift".into());
    let ctx = format!("kind-{kind_cluster}");
    kind_delete(&kind_cluster);
    clear_activation_cache("hold");
    assert!(kind_create(&kind_cluster), "failed to create kind cluster");
    struct Cleanup(String);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            kind_delete(&self.0);
        }
    }
    let _cleanup = Cleanup(kind_cluster.clone());

    let flake = TwoClusters::new();
    let flake_nix = std::fs::read_to_string(flake.path().join("flake.nix"))
        .unwrap()
        .replace(
            "sweep-b = ./b.nix;",
            "sweep-b = ./b.nix;\n        hold = ./hold-cluster.nix;",
        );
    flake.write("flake.nix", &flake_nix);
    flake.write("hold.nix", DRIFT_NIX);
    write_hold_cluster(flake.path(), true);

    let (ok, out) = flake.kix(&ctx, &["deploy", "hold", "--yes"]);
    assert!(ok, "{out}");
    let plan = |flake: &TwoClusters| {
        let out = assert_cmd::Command::cargo_bin("kix")
            .unwrap()
            .env("NO_COLOR", "true")
            .arg("--flake")
            .arg(flake.path())
            .args(["--context", &ctx, "plan", "hold"])
            .output()
            .expect("kix should run");
        let text = format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        eprintln!("$ kix plan hold\n{text}");
        (out.status.code(), text)
    };
    assert_eq!(plan(&flake).0, Some(0), "the deploy left nothing to do");

    let patch = |manager: &str, name: &str, data: &str| {
        let out = kubectl(
            &ctx,
            &[
                "-n",
                "hold-test",
                "patch",
                "configmap",
                name,
                "--type=merge",
                &format!("--field-manager={manager}"),
                "-p",
                &format!(r#"{{"data":{data}}}"#),
            ],
        );
        assert!(out.status.success(), "{out:?}");
    };
    patch("rotator", "drift-ceded", r#"{"rotated":"rotated"}"#);
    let (code, text) = plan(&flake);
    assert_eq!(code, Some(0), "a ceded field is not drift: {text}");

    patch("editor", "drift-edited", r#"{"value":"edited"}"#);
    let (code, text) = plan(&flake);
    assert_eq!(code, Some(2), "{text}");
    assert!(text.contains("editor"), "{text}");
    assert!(text.contains("ownership.cede"), "{text}");
    // The library's warning about the unreferenced ConfigMap names
    // `drift-ceded` too, so look for the plan's own `Kind/name@namespace`.
    assert!(!text.contains("ConfigMap/drift-ceded@"), "{text}");

    let (ok, out) = flake.kix(&ctx, &["deploy", "hold", "--yes"]);
    assert!(ok, "{out}");
    let get = |name: &str, key: &str| {
        kubectl_stdout(
            &ctx,
            &[
                "-n",
                "hold-test",
                "get",
                "configmap",
                name,
                "-o",
                &format!("jsonpath={{.data.{key}}}"),
            ],
        )
    };
    assert_eq!(get("drift-edited", "value").trim(), "kix");
    assert_eq!(get("drift-ceded", "rotated").trim(), "rotated");
    assert_eq!(plan(&flake).0, Some(0), "the deploy left nothing to do");
}

/// Put Kix cluster `kix_cluster` on `ctx` back into the state an older Kix
/// left: every object it applied has its `Apply` entry under the legacy
/// manager `kix`, and an `Update` entry under `kix` that owns the two notes
/// naming the current record and the applied hash. The record names no
/// revisions, and the head and the revisions are gone. This binary cannot
/// deploy the way an older Kix did, so the test writes that state through
/// the API.
fn put_back_in_the_older_state(ctx: &str, kix_cluster: &str) {
    let selector = format!("{}={kix_cluster}", keys::CLUSTER_LABEL);
    let records: serde_json::Value = serde_json::from_str(&kubectl_stdout(
        ctx,
        &["get", keys::ACTIVATIONS_CRD, "-l", &selector, "-o", "json"],
    ))
    .unwrap();
    let record = records["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["status"]["phase"] == "Active")
        .expect("an Active record")
        .clone();
    let record_name = record["metadata"]["name"].as_str().unwrap().to_string();
    let record_hash = record["metadata"]["annotations"][keys::IDENTITY_HASH]
        .as_str()
        .unwrap()
        .to_string();
    let revisions: serde_json::Value = serde_json::from_str(&kubectl_stdout(
        ctx,
        &[
            "get",
            &kix::cluster::revision::crd_name(),
            "-l",
            &selector,
            "-o",
            "json",
        ],
    ))
    .unwrap();
    let mut applied = std::collections::HashMap::new();
    for revision in revisions["items"].as_array().unwrap() {
        for (hash, value) in revision["status"]["applied"]
            .as_object()
            .into_iter()
            .flatten()
        {
            applied.insert(hash.clone(), value.as_str().unwrap().to_string());
        }
    }
    let objects: serde_json::Value = serde_json::from_str(&kubectl_stdout(
        ctx,
        &[
            "get",
            "namespaces,deployments,services,configmaps,serviceaccounts",
            "-A",
            "-l",
            "app.kubernetes.io/managed-by=kix",
            "--show-managed-fields",
            "-o",
            "json",
        ],
    ))
    .unwrap();
    let own = format!("kix/{kix_cluster}");
    let mut moved = 0;
    for obj in objects["items"].as_array().unwrap() {
        let Some(hash) = obj["metadata"]["annotations"][keys::IDENTITY_HASH].as_str() else {
            continue;
        };
        let Some(index) = obj["metadata"]["managedFields"]
            .as_array()
            .unwrap()
            .iter()
            .position(|e| e["manager"] == own.as_str() && e["operation"] == "Apply")
        else {
            continue;
        };
        let kind = obj["kind"].as_str().unwrap();
        let name = obj["metadata"]["name"].as_str().unwrap();
        let mut target = vec![kind.to_string(), name.to_string()];
        if let Some(ns) = obj["metadata"]["namespace"].as_str() {
            target.extend(["-n".to_string(), ns.to_string()]);
        }
        let rename = serde_json::json!([
            { "op": "test", "path": format!("/metadata/managedFields/{index}/manager"), "value": own },
            { "op": "replace", "path": format!("/metadata/managedFields/{index}/manager"), "value": "kix" },
        ])
        .to_string();
        let mut args: Vec<&str> = vec!["patch"];
        args.extend(target.iter().map(String::as_str));
        args.extend(["--type=json", "-p", &rename]);
        let out = kubectl(ctx, &args);
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        let activations = format!("{}={record_hash}", keys::ACTIVATIONS);
        let stamp = format!(
            "{}={}",
            keys::APPLIED_HASH,
            applied.get(hash).cloned().unwrap_or_default()
        );
        let mut args: Vec<&str> = vec!["annotate", "--overwrite", "--field-manager=kix"];
        args.extend(target.iter().map(String::as_str));
        args.extend([activations.as_str(), stamp.as_str()]);
        let out = kubectl(ctx, &args);
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        moved += 1;
    }
    assert!(moved > 0, "no object to put back");
    let remove = r#"[{"op":"remove","path":"/status/revisions"}]"#;
    let out = kubectl(
        ctx,
        &[
            "patch",
            keys::ACTIVATIONS_CRD,
            &record_name,
            "--type=json",
            "--subresource=status",
            "-p",
            remove,
        ],
    );
    if !out.status.success() {
        let out = kubectl(
            ctx,
            &[
                "patch",
                keys::ACTIVATIONS_CRD,
                &record_name,
                "--type=json",
                "-p",
                remove,
            ],
        );
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    let out = kubectl(
        ctx,
        &["delete", &kix::cluster::head::crd_name(), kix_cluster],
    );
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let out = kubectl(
        ctx,
        &[
            "delete",
            &kix::cluster::revision::crd_name(),
            "-l",
            &selector,
        ],
    );
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
}

/// Verify that the first deploy by this Kix of a Kix cluster an older Kix
/// deployed moves every object to revisions: the plan says how many
/// objects it rewrites, the deploy leaves one `Apply` entry under the
/// cluster's own manager and neither note on each object, the record names
/// revisions again, and the Pods of the Deployment do not restart.
///
/// The kind cluster is `$KIX_KIND_CLUSTER` (default `kix-migration`); the
/// test creates and deletes it.
#[test]
#[ignore] // Run explicitly: cargo test --test kind_integration_test -- --ignored
fn the_first_deploy_moves_a_cluster_an_older_kix_deployed() {
    if !has_kind() || !has_kubectl() {
        eprintln!("skipping: kind or kubectl not available");
        return;
    }
    let kind_cluster = std::env::var("KIX_KIND_CLUSTER").unwrap_or_else(|_| "kix-migration".into());
    let ctx = format!("kind-{kind_cluster}");
    kind_delete(&kind_cluster);
    clear_activation_cache(KIX_CLUSTER);
    assert!(kind_create(&kind_cluster), "failed to create kind cluster");
    struct Cleanup(String);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            kind_delete(&self.0);
        }
    }
    let _cleanup = Cleanup(kind_cluster.clone());

    let first = kix(&kind_cluster)
        .args(["deploy", KIX_CLUSTER, "--yes"])
        .output()
        .unwrap();
    assert!(
        first.status.success(),
        "{}",
        String::from_utf8_lossy(&first.stderr)
    );
    put_back_in_the_older_state(&ctx, KIX_CLUSTER);
    let pods = |ctx: &str| {
        kubectl_stdout(
            ctx,
            &[
                "get",
                "pods",
                "-n",
                "echo",
                "-o",
                "jsonpath={.items[*].metadata.uid}",
            ],
        )
    };
    let before = pods(&ctx);
    assert!(!before.trim().is_empty(), "the Deployment runs Pods");
    let deployment = kubectl_stdout(&ctx, &["get", "deploy", "-n", "echo", "-o", "name"]);
    let deployment = deployment
        .lines()
        .next()
        .expect("a Deployment")
        .trim_start_matches("deployment.apps/")
        .to_string();
    assert_eq!(
        apply_managers(&ctx, "deployment", "echo", &deployment),
        ["kix"]
    );

    let plan = kix(&kind_cluster)
        .args(["plan", KIX_CLUSTER])
        .output()
        .unwrap();
    let text = unwrapped(&String::from_utf8_lossy(&plan.stdout));
    assert!(text.contains("rewrites the metadata of"), "{text}");

    let second = kix(&kind_cluster)
        .args(["deploy", KIX_CLUSTER, "--yes"])
        .output()
        .unwrap();
    assert!(
        second.status.success(),
        "{}",
        String::from_utf8_lossy(&second.stderr)
    );
    assert_eq!(
        apply_managers(&ctx, "deployment", "echo", &deployment),
        [format!("kix/{KIX_CLUSTER}")]
    );
    let annotations: serde_json::Value = serde_json::from_str(&kubectl_stdout(
        &ctx,
        &[
            "get",
            "deployment",
            &deployment,
            "-n",
            "echo",
            "-o",
            "jsonpath={.metadata.annotations}",
        ],
    ))
    .unwrap();
    assert!(
        annotations.get(keys::ACTIVATIONS).is_none(),
        "{annotations}"
    );
    assert!(
        annotations.get(keys::APPLIED_HASH).is_none(),
        "{annotations}"
    );
    let revisions = kubectl_stdout(
        &ctx,
        &[
            "get",
            &kix::cluster::revision::crd_name(),
            "-l",
            &format!("{}={KIX_CLUSTER}", keys::CLUSTER_LABEL),
            "-o",
            "name",
        ],
    );
    assert!(!revisions.trim().is_empty(), "the record names revisions");
    assert_eq!(pods(&ctx), before, "the Pods did not restart");

    let again = kix(&kind_cluster)
        .args(["plan", KIX_CLUSTER])
        .output()
        .unwrap();
    let text = unwrapped(&String::from_utf8_lossy(&again.stdout));
    assert!(!text.contains("rewrites the metadata of"), "{text}");
}

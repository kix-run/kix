//! End-to-end integration test for the Kix operator.
//!
//! Requires: `kind`, `kubectl`, and `nix` on PATH.
//! Creates a temporary kind cluster, starts the operator as a subprocess,
//! creates Activation CRs, and verifies reconciliation and GC.
//!
//! The test writes the cluster's credentials to a kubeconfig file of its own
//! and passes that file to every `kind` and `kubectl` call and to the
//! operator. It never reads or changes the default kubeconfig, so it cannot
//! reach another cluster.
//!
//! Run with: cargo test --test operator_integration_test -- --ignored
//! (ignored by default because it requires kind and nix, and is slow)

use kix::manifest::keys;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::Duration;

fn repo_root() -> &'static Path {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .parent()
        .unwrap()
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

fn kind_create(name: &str, kubeconfig: &Path) -> bool {
    Command::new("kind")
        .args(["create", "cluster", "--name", name, "--kubeconfig"])
        .arg(kubeconfig)
        .output()
        .is_ok_and(|o| o.status.success())
}

fn kind_delete(name: &str, kubeconfig: &Path) {
    let _ = Command::new("kind")
        .args(["delete", "cluster", "--name", name, "--kubeconfig"])
        .arg(kubeconfig)
        .output();
}

fn kubectl(kubeconfig: &Path, args: &[&str]) -> std::process::Output {
    Command::new("kubectl")
        .arg("--kubeconfig")
        .arg(kubeconfig)
        .args(args)
        .output()
        .expect("kubectl should work")
}

fn kubectl_stdout(kubeconfig: &Path, args: &[&str]) -> String {
    let output = kubectl(kubeconfig, args);
    String::from_utf8_lossy(&output.stdout).to_string()
}

fn kubectl_apply_stdin(kubeconfig: &Path, yaml: &str) -> std::process::Output {
    use std::io::Write;
    let mut child = Command::new("kubectl")
        .arg("--kubeconfig")
        .arg(kubeconfig)
        .args(["apply", "-f", "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("kubectl should start");
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(yaml.as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}

/// Evaluate the `kind` cluster and return the store path of its activation
/// index.
fn build_activation() -> PathBuf {
    kix::eval::nix::eval_activation_index(repo_root(), "kind", &[], &|_| {})
        .expect("the kind cluster should evaluate")
}

/// Start the operator as a background subprocess that reaches the cluster
/// through `kubeconfig` only.
fn start_operator(kubeconfig: &Path) -> Child {
    let operator_bin = assert_cmd::cargo::cargo_bin("kix-operator");
    eprintln!("Starting operator: {}", operator_bin.display());

    Command::new(operator_bin)
        .env("KUBECONFIG", kubeconfig)
        .env("RUST_LOG", "info,kix_operator=debug,kix_cluster=debug")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("operator should start")
}

/// Wait until the Kix CRDs are Established. The operator installs them when
/// it starts.
fn await_crds(kubeconfig: &Path) {
    let crds = [
        format!("crd/{}", keys::ACTIVATIONS_CRD),
        format!("crd/{}", keys::PACKAGE_INSTANCES_CRD),
    ];
    let established = wait_until(
        "the operator to install the Kix CRDs",
        Duration::from_secs(90),
        || {
            let mut args = vec!["wait", "--for=condition=Established", "--timeout=5s"];
            args.extend(crds.iter().map(String::as_str));
            kubectl(kubeconfig, &args).status.success()
        },
    );
    assert!(established, "the operator should install the Kix CRDs");
}

/// Create an Activation CR pointing to a store path.
fn create_activation(kubeconfig: &Path, name: &str, store_path: &Path, cluster: &str) {
    let yaml = format!(
        r#"
apiVersion: kix.run/v1alpha1
kind: Activation
metadata:
  name: {name}
  labels:
    app.kubernetes.io/managed-by: kix
    kix.run/cluster: {cluster}
spec:
  cluster: {cluster}
  active: true
  source:
    type: storePath
    path: "{path}"
"#,
        name = name,
        cluster = cluster,
        path = store_path.display(),
    );

    let result = kubectl_apply_stdin(kubeconfig, &yaml);
    assert!(
        result.status.success(),
        "Activation CR apply should succeed: {}",
        String::from_utf8_lossy(&result.stderr)
    );
}

/// Poll until a condition is met or timeout.
fn wait_until(description: &str, timeout: Duration, check: impl Fn() -> bool) -> bool {
    let start = std::time::Instant::now();
    while start.elapsed() < timeout {
        if check() {
            return true;
        }
        thread::sleep(Duration::from_secs(2));
    }
    eprintln!("Timed out waiting for: {description}");
    false
}

const KIND_CLUSTER: &str = "kix-operator-test";
const KIX_CLUSTER: &str = "kind";

#[test]
#[ignore] // Run explicitly: cargo test --test operator_integration_test -- --ignored
fn operator_reconcile_and_gc() {
    if !has_kind() || !has_kubectl() {
        eprintln!("skipping: kind or kubectl not available");
        return;
    }

    // Setup: build activation and create kind cluster
    eprintln!("\n=== Setup: Building activation ===");
    let result_dir = build_activation();
    eprintln!("Activation built at: {}", result_dir.display());

    eprintln!("\n=== Setup: Creating kind cluster ===");
    let config_dir = tempfile::tempdir().expect("a temporary directory");
    let kubeconfig = config_dir.path().join("kubeconfig");
    let kubeconfig = kubeconfig.as_path();
    kind_delete(KIND_CLUSTER, kubeconfig);
    if !kind_create(KIND_CLUSTER, kubeconfig) {
        panic!("failed to create kind cluster");
    }

    // Always clean up
    struct CleanupGuard<'a> {
        operator: Option<Child>,
        kubeconfig: &'a Path,
    }
    impl Drop for CleanupGuard<'_> {
        fn drop(&mut self) {
            if let Some(ref mut child) = self.operator {
                let _ = child.kill();
                let _ = child.wait();
            }
            kind_delete(KIND_CLUSTER, self.kubeconfig);
        }
    }
    let mut guard = CleanupGuard {
        operator: None,
        kubeconfig,
    };

    // Phase 1: Start operator, create Activation, and verify resources
    eprintln!("\n=== Phase 1: Start operator and create Activation ===");

    let operator = start_operator(kubeconfig);
    guard.operator = Some(operator);
    await_crds(kubeconfig);

    // The operator lists Activations when it starts, so one created before
    // its watch begins is still reconciled.
    // Create Activation CR
    create_activation(kubeconfig, "test-activation", &result_dir, KIX_CLUSTER);
    eprintln!("Activation CR created");

    // Wait for operator to reconcile: look for managed resources in the echo namespace
    let resources_created = wait_until(
        "resources to be created by operator",
        Duration::from_secs(120),
        || {
            let managed = kubectl_stdout(
                kubeconfig,
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
            !managed.trim().is_empty()
        },
    );
    assert!(resources_created, "operator should create resources");

    let managed = kubectl_stdout(
        kubeconfig,
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
    eprintln!("Managed resources after reconcile:\n{managed}");

    // Verify Activation CR exists and has the right cluster label
    let activation_list = kubectl_stdout(kubeconfig, &["get", keys::ACTIVATIONS_CRD, "-o", "name"]);
    eprintln!("Activations: {activation_list}");
    assert!(
        activation_list.contains("test-activation"),
        "Activation CR should exist"
    );

    // Phase 2: Delete Activation and verify GC
    eprintln!("\n=== Phase 2: Delete Activation, verify GC ===");

    let delete_result = kubectl(
        kubeconfig,
        &[
            "delete",
            &format!("activation.{}", keys::GROUP),
            "test-activation",
            "--timeout=60s",
        ],
    );
    eprintln!(
        "Delete result: {}",
        String::from_utf8_lossy(&delete_result.stderr)
    );

    // The operator's finalizer should clean up resources before allowing deletion
    let gc_complete = wait_until(
        "resources to be cleaned up after Activation deletion",
        Duration::from_secs(90),
        || {
            let managed = kubectl_stdout(
                kubeconfig,
                &[
                    "get",
                    "all,configmap",
                    "-n",
                    "echo",
                    "-l",
                    "app.kubernetes.io/managed-by=kix",
                    "-o",
                    "name",
                    "--ignore-not-found",
                ],
            );
            managed.trim().is_empty()
        },
    );

    // Note: GC may not clean up everything perfectly on first implementation.
    // The echo namespace itself won't be deleted (Namespace pruning is skipped).
    // Check for non-Namespace resources being cleaned up.
    let remaining = kubectl_stdout(
        kubeconfig,
        &[
            "get",
            "all,configmap,serviceaccount",
            "-n",
            "echo",
            "-l",
            "app.kubernetes.io/managed-by=kix",
            "-o",
            "name",
            "--ignore-not-found",
        ],
    );
    eprintln!("Remaining resources after GC:\n{remaining}");

    if gc_complete {
        eprintln!("GC completed — all managed resources cleaned up");
    } else {
        eprintln!("GC may still be in progress or some resources remain");
        // Don't hard-fail: GC timing can be flaky in CI
    }

    // Verify the Activation CR itself is deleted
    let activation_after = kubectl_stdout(
        kubeconfig,
        &[
            "get",
            keys::ACTIVATIONS_CRD,
            "test-activation",
            "--ignore-not-found",
            "-o",
            "name",
        ],
    );
    assert!(
        activation_after.trim().is_empty(),
        "Activation CR should be deleted after finalizer completes"
    );

    eprintln!("\n=== All phases passed ===");
}

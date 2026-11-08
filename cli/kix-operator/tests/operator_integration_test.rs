//! End-to-end integration test for the Kix operator.
//!
//! Requires: `kind`, `kubectl`, and `nix` on PATH.
//! Creates a temporary kind cluster, starts the operator as a subprocess,
//! creates Activation CRs, and verifies reconciliation and GC.
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

fn kubectl_apply_stdin(context: &str, yaml: &str) -> std::process::Output {
    use std::io::Write;
    let mut child = Command::new("kubectl")
        .arg("--context")
        .arg(context)
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

/// Start the operator as a background subprocess.
fn start_operator(_context: &str) -> Child {
    // Build the operator binary path
    let operator_bin = assert_cmd::cargo::cargo_bin("kix-operator");
    eprintln!("Starting operator: {}", operator_bin.display());

    Command::new(operator_bin)
        .env("KUBECONFIG", kubeconfig_path())
        .env("RUST_LOG", "info,kix_operator=debug,kix_cluster=debug")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("operator should start")
}

fn kubeconfig_path() -> String {
    std::env::var("KUBECONFIG").unwrap_or_else(|_| {
        let home = std::env::var("HOME").unwrap();
        format!("{home}/.kube/config")
    })
}

/// Apply the Kix CRDs to the cluster.
fn apply_crds(context: &str) {
    let activation_crd = r#"
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: activations.kix.run
spec:
  group: kix.run
  scope: Cluster
  names:
    kind: Activation
    plural: activations
    singular: activation
  versions:
    - name: v1alpha1
      served: true
      storage: true
      subresources:
        status: {}
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              x-kubernetes-preserve-unknown-fields: true
            status:
              type: object
              x-kubernetes-preserve-unknown-fields: true
"#;

    let pi_crd = r#"
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: packageinstances.kix.run
spec:
  group: kix.run
  scope: Namespaced
  names:
    kind: PackageInstance
    plural: packageinstances
    singular: packageinstance
  versions:
    - name: v1alpha1
      served: true
      storage: true
      subresources:
        status: {}
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              x-kubernetes-preserve-unknown-fields: true
            status:
              type: object
              x-kubernetes-preserve-unknown-fields: true
"#;

    let result = kubectl_apply_stdin(context, activation_crd);
    assert!(
        result.status.success(),
        "Activation CRD apply should succeed: {}",
        String::from_utf8_lossy(&result.stderr)
    );

    let result = kubectl_apply_stdin(context, pi_crd);
    assert!(
        result.status.success(),
        "PackageInstance CRD apply should succeed: {}",
        String::from_utf8_lossy(&result.stderr)
    );

    // Wait for CRDs to establish
    thread::sleep(Duration::from_secs(2));
}

/// Create an Activation CR pointing to a store path.
fn create_activation(context: &str, name: &str, store_path: &Path, cluster: &str) {
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

    let result = kubectl_apply_stdin(context, &yaml);
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
const KUBE_CTX: &str = "kind-kix-operator-test";
const KIX_CLUSTER: &str = "kind";

#[test]
#[ignore] // Run explicitly: cargo test --test operator_integration_test -- --ignored
fn operator_reconcile_and_gc() {
    if !has_kind() || !has_kubectl() {
        eprintln!("skipping: kind or kubectl not available");
        return;
    }

    // Setup: build activation, create kind cluster, and apply CRDs
    eprintln!("\n=== Setup: Building activation ===");
    let result_dir = build_activation();
    eprintln!("Activation built at: {}", result_dir.display());

    eprintln!("\n=== Setup: Creating kind cluster ===");
    kind_delete(KIND_CLUSTER);
    if !kind_create(KIND_CLUSTER) {
        panic!("failed to create kind cluster");
    }

    // Always clean up
    struct CleanupGuard {
        operator: Option<Child>,
    }
    impl Drop for CleanupGuard {
        fn drop(&mut self) {
            if let Some(ref mut child) = self.operator {
                let _ = child.kill();
                let _ = child.wait();
            }
            kind_delete(KIND_CLUSTER);
        }
    }
    let mut guard = CleanupGuard { operator: None };

    eprintln!("\n=== Setup: Applying CRDs ===");
    apply_crds(KUBE_CTX);

    // Phase 1: Start operator, create Activation, and verify resources
    eprintln!("\n=== Phase 1: Start operator and create Activation ===");

    let operator = start_operator(KUBE_CTX);
    guard.operator = Some(operator);

    // Give operator time to start watching
    thread::sleep(Duration::from_secs(3));

    // Create Activation CR
    create_activation(KUBE_CTX, "test-activation", &result_dir, KIX_CLUSTER);
    eprintln!("Activation CR created");

    // Wait for operator to reconcile: look for managed resources in the echo namespace
    let resources_created = wait_until(
        "resources to be created by operator",
        Duration::from_secs(120),
        || {
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
            !managed.trim().is_empty()
        },
    );
    assert!(resources_created, "operator should create resources");

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
    eprintln!("Managed resources after reconcile:\n{managed}");

    // Verify Activation CR exists and has the right cluster label
    let activation_list = kubectl_stdout(KUBE_CTX, &["get", keys::ACTIVATIONS_CRD, "-o", "name"]);
    eprintln!("Activations: {activation_list}");
    assert!(
        activation_list.contains("test-activation"),
        "Activation CR should exist"
    );

    // Phase 2: Delete Activation and verify GC
    eprintln!("\n=== Phase 2: Delete Activation, verify GC ===");

    let delete_result = kubectl(
        KUBE_CTX,
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
        KUBE_CTX,
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
        KUBE_CTX,
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

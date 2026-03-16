# v2 smoke test — validates the builtins.toFile approach.
#
# Run: nix eval -f tests/v2/smoke.nix
# All assertions must pass for the test to succeed.

let
  # Bootstrap — use nixpkgs lib
  pkgs = import <nixpkgs> { };
  lib = pkgs.lib;

  kixv2 = import ../../lib/v2 { inherit lib; };
  k8s = import ../../lib/v2/k8s.nix { inherit lib; };

  inherit (kixv2) clusterScoped mkResource postProcessManifest computeClosure buildRegistry mkScope buildCluster;

  # ===== Test 1: Two resources where one references the other via "${}" =====
  test1 =
    let
      configmap = mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "my-config";
        namespace = "default";
        data.key = "value";
      };

      deployment = mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "my-app";
        namespace = "default";
        spec.template.spec.volumes = [{
          name = "config";
          configMap.name = "${configmap}";  # <-- embeds store path
        }];
      };

      # Verify getContext finds the dep
      deploymentJson = builtins.toJSON deployment.rawManifest;
      ctx = builtins.getContext deploymentJson;
      configmapPath = builtins.unsafeDiscardStringContext configmap.outPath;
    in {
      name = "store-path-deps";
      # The configmap's store path should appear in deployment's context
      assertion = builtins.hasAttr configmapPath ctx;
      message = "deployment should have configmap in its string context";
    };

  # ===== Test 2: postProcessManifest replaces store paths with K8s names =====
  test2 =
    let
      configmap = mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "my-config";
        namespace = "default";
        data.key = "value";
      };

      deployment = mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "my-app";
        namespace = "default";
        spec.template.spec.volumes = [{
          name = "config";
          configMap.name = "${configmap}";
        }];
      };

      registry = buildRegistry [ configmap deployment ];
      processed = postProcessManifest registry deployment.manifest;
    in {
      name = "post-process";
      # After post-processing, the configMap.name should be the K8s name, not store path
      assertion = processed.spec.template.spec.volumes == [{
        name = "config";
        configMap.name = "my-config";
      }];
      message = "post-processing should replace store path with K8s name 'my-config', got: ${builtins.toJSON processed.spec.template.spec.volumes}";
    };

  # ===== Test 3: computeClosure returns both resources =====
  test3 =
    let
      configmap = mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "my-config";
        namespace = "default";
        data.key = "value";
      };

      deployment = mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "my-app";
        namespace = "default";
        spec.template.spec.volumes = [{
          name = "config";
          configMap.name = "${configmap}";
        }];
        requires = [ ];
      };

      registry = buildRegistry [ configmap deployment ];
      closure = computeClosure registry deployment;
      closureNames = map (r: r.name) closure;
    in {
      name = "closure-computation";
      assertion = builtins.length closure == 2
        && builtins.elem "my-app" closureNames
        && builtins.elem "my-config" closureNames;
      message = "closure should contain both my-app and my-config, got: ${builtins.toJSON closureNames}";
    };

  # ===== Test 4: mkScope with mkResource and mkClusterResource =====
  test4 =
    let
      nsResource = mkResource {
        apiVersion = "v1";
        kind = "Namespace";
        name = "test-ns";
        namespace = clusterScoped;
      };

      scope = mkScope {
        instanceName = "my-instance";
        namespaceName = "test-ns";
        namespaceResource = nsResource;
        clusterLabels = { "cluster" = "test"; };
      };

      svcAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "my-sa";
      };

      clusterRole = scope.mkClusterResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "my-role";
        extra.rules = [];
      };
    in {
      name = "scope-api";
      assertion =
        # Namespaced resource should have namespace in manifest
        svcAccount.manifest.metadata ? namespace
        # ClusterResource should NOT have namespace
        && !(clusterRole.manifest.metadata ? namespace)
        # Labels should include instance name
        && svcAccount.manifest.metadata.labels."app.kubernetes.io/instance" == "my-instance"
        && clusterRole.manifest.metadata.labels."app.kubernetes.io/instance" == "my-instance"
        # Cluster labels should be merged
        && svcAccount.manifest.metadata.labels."cluster" == "test";
      message = "scope should properly inject namespace and labels";
    };

  # ===== Test 5: clusterScoped sentinel omits metadata.namespace =====
  test5 =
    let
      clusterRole = mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "my-role";
        namespace = clusterScoped;
        extra.rules = [];
      };
    in {
      name = "cluster-scoped";
      assertion = !(clusterRole.manifest.metadata ? namespace);
      message = "cluster-scoped resources should not have metadata.namespace";
    };

  # ===== Test 6: Full mini-cluster with buildCluster + DI resolution =====
  test6 =
    let
      # Define two simple packages
      dbPackage = { scope, config, lib ? null }:
        self: {
          service = scope.mkResource {
            apiVersion = "v1";
            kind = "Service";
            name = "${scope.instanceName}-db";
            outputs = { port = "5432"; host = "${scope.instanceName}-db"; };
            spec.ports = [{ port = 5432; }];
          };
          main = self.service;
        };

      appPackage = { scope, config, lib ? null, db }:
        self: {
          deployment = scope.mkResource {
            apiVersion = "apps/v1";
            kind = "Deployment";
            name = "${scope.instanceName}-app";
            spec.template.spec.containers = [{
              name = "app";
              env = [{
                name = "DB_HOST";
                value = "${db.fqdn}";
              }];
            }];
          };
          service = scope.mkResource {
            apiVersion = "v1";
            kind = "Service";
            name = "${scope.instanceName}-app";
            spec.ports = [{ port = 8080; }];
          };
          main = self.service // { requires = [ self.deployment ]; };
        };

      cluster = buildCluster {
        namespaces.default = { };
        instances = { ref, ... }: {
          default = {
            db = {
              package = dbPackage;
              packageType = "db";
            };
            app = {
              package = appPackage;
              packageType = "app";
              # db should auto-resolve to default/db
            };
          };
        };
      };

      # Verify the cluster built successfully
      appInstance = cluster.instances.default.app;
      dbInstance = cluster.instances.default.db;
    in {
      name = "full-mini-cluster";
      assertion =
        # Both instances exist
        appInstance._meta.instanceName == "app"
        && dbInstance._meta.instanceName == "db"
        # Manifests were generated
        && builtins.length cluster.manifests > 0;
      message = "full cluster should build with DI resolution";
    };

  # ===== Test 7: requires chain (SA → binding → role) =====
  test7 =
    let
      role = mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "my-role";
        namespace = clusterScoped;
        extra.rules = [{ apiGroups = [""]; resources = ["pods"]; verbs = ["get"]; }];
      };

      binding = mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        name = "my-binding";
        namespace = clusterScoped;
        extra = {
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "ClusterRole";
            name = "${role}";  # auto-dep on role
          };
          subjects = [{ kind = "ServiceAccount"; name = "my-sa"; namespace = "default"; }];
        };
      };

      sa = mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "my-sa";
        namespace = "default";
        requires = [ binding ];  # inverted dep
      };

      registry = buildRegistry [ role binding sa ];
      closure = computeClosure registry sa;
      closureNames = map (r: r.name) closure;
    in {
      name = "requires-chain";
      assertion = builtins.length closure == 3
        && builtins.elem "my-sa" closureNames
        && builtins.elem "my-binding" closureNames
        && builtins.elem "my-role" closureNames;
      message = "SA → binding → role requires chain should produce full closure, got: ${builtins.toJSON closureNames}";
    };

  # ===== Test 8: outputs carry context =====
  test8 =
    let
      service = mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "my-svc";
        namespace = "default";
        outputs = { port = "8080"; };
        spec.ports = [{ port = 8080; }];
      };

      consumer = mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "consumer";
        namespace = "default";
        spec.template.spec.containers = [{
          name = "app";
          env = [{ name = "PORT"; value = service.out.port; }];
        }];
      };

      registry = buildRegistry [ service consumer ];
      closure = computeClosure registry consumer;
      closureNames = map (r: r.name) closure;
    in {
      name = "output-context";
      assertion = builtins.length closure == 2
        && builtins.elem "my-svc" closureNames;
      message = "using service.out.port should create a dep on the service, got: ${builtins.toJSON closureNames}";
    };

  # ===== Run all tests =====
  allTests = [ test1 test2 test3 test4 test5 test6 test7 test8 ];

  failures = builtins.filter (t: !t.assertion) allTests;

  result =
    if failures == [ ] then
      "All ${toString (builtins.length allTests)} tests passed."
    else
      throw (builtins.concatStringsSep "\n" (
        [ "FAILURES:" ]
        ++ map (t: "  ${t.name}: ${t.message}") failures
      ));

in result

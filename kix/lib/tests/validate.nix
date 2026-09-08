# Tests for the cross-resource resolution checks (kix/lib/eval/validate.nix)
# and for their wiring into buildCluster. Imported by ./default.nix into the
# same test matrix.
#
# The unit cases feed hand-built manifest lists to `crossResourceFailures`
# and check that exactly the expected check fires. The cluster cases go
# through buildCluster to prove the checks gate evaluation and that the
# manifest list they receive has one entry per resource.

{
  lib,
  k8s,
  validate,
  mkCluster,
  baseInstances,
  manifests,
  evalFails,
}:

let
  failures = ms: validate.crossResourceFailures { manifests = ms; };

  # A manifest with the labels every kix resource carries.
  res =
    kind: ns: name: extra:
    lib.recursiveUpdate {
      apiVersion = "v1";
      inherit kind;
      metadata = {
        inherit name;
        labels."app.kubernetes.io/managed-by" = "kix";
      }
      // lib.optionalAttrs (ns != null) { namespace = ns; };
    } extra;

  namespace = name: res "Namespace" null name { };

  podLabels = {
    app = "web";
  };

  deployment =
    ns: name: extra:
    res "Deployment" ns name (
      lib.recursiveUpdate {
        apiVersion = "apps/v1";
        spec = {
          selector.matchLabels = podLabels;
          template = {
            metadata.labels = podLabels;
            spec.containers = [
              {
                name = "web";
                ports = [
                  {
                    name = "http";
                    containerPort = 8080;
                  }
                ];
              }
            ];
          };
        };
      } extra
    );

  cronJob =
    ns: name:
    res "CronJob" ns name {
      apiVersion = "batch/v1";
      spec.jobTemplate.spec.template = {
        metadata.labels = {
          app = "nightly";
        };
        spec.containers = [
          {
            name = "job";
            ports = [
              {
                name = "metrics";
                containerPort = 9000;
              }
            ];
          }
        ];
      };
    };

  service =
    ns: name: selector: extra:
    res "Service" ns name (
      lib.recursiveUpdate {
        spec = {
          inherit selector;
          ports = [
            {
              port = 80;
              targetPort = "http";
            }
          ];
        };
      } extra
    );

  base = ns: [
    (namespace ns)
    (deployment ns "web" { })
    (service ns "web" podLabels { })
  ];

  # The one failure whose text contains `needle`, and nothing else.
  onlyFailure =
    needle: ms:
    let
      fs = failures ms;
    in
    (builtins.length fs == 1 && lib.hasInfix needle (builtins.head fs))
    || throw "expected exactly one failure containing '${needle}', got: ${builtins.toJSON fs}";

  clean =
    ms:
    let
      fs = failures ms;
    in
    fs == [ ] || throw "expected no failures, got: ${builtins.toJSON fs}";

  # Inline packages for the cluster-level cases.
  aliasedPackage = {
    build =
      { self, scope, ... }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "twice";
          data.k = "v";
        };
        # Same resource under a second key: collectResources sees it twice.
        alias = self.cm;
        root = self.cm;
      };
  };

  # A workload naming a ServiceAccount kix does not own, the sanctioned way.
  externalSaPackage = {
    build =
      { self, scope, ... }:
      {
        web = scope.mkDeployment {
          name = "ext";
          spec = {
            selector.matchLabels.app = "ext";
            template.spec = {
              serviceAccountName = k8s.markers.mkUntrackedRef "cluster-provided-sa";
              containers = [
                {
                  name = "c";
                  image = "img:1";
                }
              ];
            };
          };
        };
        root = self.web;
      };
  };

  # Provenance intact, name wrong: constructors accept it, the check must not.
  suffixedSaPackage = {
    build =
      { self, scope, ... }:
      {
        sa = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          name = "real";
        };
        web = scope.mkDeployment {
          name = "sfx";
          spec = {
            selector.matchLabels.app = "sfx";
            template.spec = {
              serviceAccountName = self.sa.out.name + "-typo";
              containers = [
                {
                  name = "c";
                  image = "img:1";
                }
              ];
            };
          };
        };
        root = self.web;
      };
  };

  brokenServicePackage = {
    build =
      { self, scope, ... }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "anchor";
          data.k = "v";
        };
        svc = scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = "dangling";
          requires = [ self.cm ];
          # Hand-typed selector that matches no pod in the build.
          spec.selector.app = "nothing-has-this-label";
          spec.ports = [ { port = 80; } ];
        };
        root = self.svc;
      };
  };
in
{
  v00-consistent-set-is-clean = clean (base "a");

  v01-missing-serviceaccount = onlyFailure "references ServiceAccount 'sa-typo'" (
    base "a" ++ [ (deployment "a" "api" { spec.template.spec.serviceAccountName = "sa-typo"; }) ]
  );

  v02-rolebinding-to-missing-role = onlyFailure "references Role 'nope'" (
    base "a"
    ++ [
      (res "RoleBinding" "a" "rb" {
        apiVersion = "rbac.authorization.k8s.io/v1";
        roleRef = {
          kind = "Role";
          name = "nope";
        };
      })
    ]
  );

  v02b-system-role-is-external = clean (
    base "a"
    ++ [
      (res "ClusterRoleBinding" null "crb" {
        apiVersion = "rbac.authorization.k8s.io/v1";
        roleRef = {
          kind = "ClusterRole";
          name = "system:auth-delegator";
        };
      })
    ]
  );

  v03-configmap-volume-missing = onlyFailure "mounts ConfigMap 'cfg-typo' which does not exist" (
    base "a"
    ++ [
      (deployment "a" "api" {
        spec.template.spec.volumes = [
          {
            name = "cfg";
            configMap.name = "cfg-typo";
          }
        ];
      })
    ]
  );

  v04-service-selector-matches-nothing = onlyFailure "matches no workload pod template" (
    base "a" ++ [ (service "a" "lost" { app = "nope"; } { }) ]
  );

  # Regression: CronJob pods were invisible to checks 4, 12 and 13.
  v04b-service-may-select-cronjob-pods = clean (
    base "a"
    ++ [
      (cronJob "a" "nightly")
      (service "a" "nightly" { app = "nightly"; } {
        spec.ports = [
          {
            port = 9000;
            targetPort = "metrics";
          }
        ];
      })
    ]
  );

  # The operator exemption: CR in the same namespace, Service name prefixed.
  v04c-operator-exemption-same-namespace = clean (
    base "a"
    ++ [
      (res "Prometheus" "a" "prom" { apiVersion = "monitoring.coreos.com/v1"; })
      (service "a" "prom-operated" { operated = "yes"; } { spec.ports = [ { port = 9090; } ]; })
    ]
  );

  # Regression: the exemption never compared namespaces.
  v04d-operator-exemption-is-namespaced = onlyFailure "Service b/prom-operated" (
    base "a"
    ++ base "b"
    ++ [
      (res "Prometheus" "a" "prom" { apiVersion = "monitoring.coreos.com/v1"; })
      (service "b" "prom-operated" { operated = "yes"; } { spec.ports = [ { port = 9090; } ]; })
    ]
  );

  v05-hpa-target-missing = onlyFailure "targets Deployment 'ghost'" (
    base "a"
    ++ [
      (res "HorizontalPodAutoscaler" "a" "hpa" {
        apiVersion = "autoscaling/v2";
        spec.scaleTargetRef = {
          kind = "Deployment";
          name = "ghost";
        };
      })
    ]
  );

  v06-statefulset-needs-headless-service = onlyFailure "does not match any headless Service" (
    base "a"
    ++ [
      (res "StatefulSet" "a" "db" {
        apiVersion = "apps/v1";
        spec = {
          serviceName = "web";
          selector.matchLabels = podLabels;
          template.metadata.labels = podLabels;
        };
      })
    ]
  );

  v07-duplicate-identity = onlyFailure "Duplicate resource: ConfigMap/a/same" (
    base "a"
    ++ [
      (res "ConfigMap" "a" "same" { data.k = "1"; })
      (res "ConfigMap" "a" "same" { data.k = "2"; })
    ]
  );

  v08-managed-by-label = onlyFailure "missing app.kubernetes.io/managed-by=kix" (
    base "a"
    ++ [
      {
        apiVersion = "v1";
        kind = "ConfigMap";
        metadata = {
          name = "bare";
          namespace = "a";
        };
      }
    ]
  );

  v09-selector-outside-template-labels = onlyFailure "is not a subset of pod template labels" (
    base "a" ++ [ (deployment "a" "api" { spec.selector.matchLabels.tier = "api"; }) ]
  );

  v10-ingress-backend-missing = onlyFailure "references Service 'nowhere'" (
    base "a"
    ++ [
      (res "Ingress" "a" "ing" {
        apiVersion = "networking.k8s.io/v1";
        spec.rules = [
          {
            http.paths = [
              {
                path = "/";
                backend.service.name = "nowhere";
              }
            ];
          }
        ];
      })
    ]
  );

  v11-namespace-missing = onlyFailure "Namespace 'b' is referenced" (
    base "a" ++ [ (res "ConfigMap" "b" "stray" { }) ]
  );

  # Sentinel namespaces (`_`-prefixed) never get a Namespace object on purpose.
  v11b-sentinel-namespace-is-exempt = clean (
    base "a" ++ [ (res "ConfigMap" "_cluster" "probe" { }) ]
  );

  v12-networkpolicy-selects-nothing = onlyFailure "podSelector" (
    base "a"
    ++ [
      (res "NetworkPolicy" "a" "np" {
        apiVersion = "networking.k8s.io/v1";
        spec.podSelector.matchLabels.app = "nope";
      })
    ]
  );

  v13-named-targetport-missing = onlyFailure "targetPort 'grpc'" (
    base "a"
    ++ [
      (service "a" "web-grpc" podLabels {
        spec.ports = [
          {
            port = 9;
            targetPort = "grpc";
          }
        ];
      })
    ]
  );

  # --- the reference resolves: one passing case per lookup ---
  # Without these a broken `hasResource` would ship green: every failing
  # case above passes trivially when nothing ever resolves.

  p01-serviceaccount-present = clean (
    base "a"
    ++ [
      (res "ServiceAccount" "a" "api-sa" { })
      (deployment "a" "api" { spec.template.spec.serviceAccountName = "api-sa"; })
    ]
  );

  p02-rolebinding-to-present-role = clean (
    base "a"
    ++ [
      (res "Role" "a" "reader" { apiVersion = "rbac.authorization.k8s.io/v1"; })
      (res "RoleBinding" "a" "rb" {
        apiVersion = "rbac.authorization.k8s.io/v1";
        roleRef = {
          kind = "Role";
          name = "reader";
        };
      })
    ]
  );

  p02b-builtin-cluster-roles-are-external = clean (
    base "a"
    ++
      map
        (
          name:
          res "ClusterRoleBinding" null "crb-${name}" {
            apiVersion = "rbac.authorization.k8s.io/v1";
            roleRef = {
              kind = "ClusterRole";
              inherit name;
            };
          }
        )
        [
          "admin"
          "edit"
          "view"
          "cluster-admin"
          "legacy-psp"
        ]
  );

  p03-configmap-volume-present = clean (
    base "a"
    ++ [
      (res "ConfigMap" "a" "cfg" { data.k = "v"; })
      (deployment "a" "api" {
        spec.template.spec.volumes = [
          {
            name = "cfg";
            configMap.name = "cfg";
          }
        ];
      })
    ]
  );

  p03b-secret-volumes-are-not-checked = clean (
    base "a"
    ++ [
      (deployment "a" "api" {
        spec.template.spec.volumes = [
          {
            name = "creds";
            secret.secretName = "provided-out-of-band";
          }
        ];
      })
    ]
  );

  p04-headless-service-has-no-selector = clean (
    base "a" ++ [ (service "a" "external" { } { spec.ports = [ { port = 443; } ]; }) ]
  );

  p04b-control-plane-scrape-target = clean (
    base "a"
    ++ [
      (service "a" "kube-dns-metrics" { "k8s-app" = "kube-dns"; } { spec.ports = [ { port = 9153; } ]; })
    ]
  );

  p04c-vm-operand-kinds-are-exempt = clean (
    base "a"
    ++ [
      (res "VMCluster" "a" "vm" { apiVersion = "operator.victoriametrics.com/v1beta1"; })
      (service "a" "vm-select" { "app.kubernetes.io/name" = "vmselect"; } {
        spec.ports = [ { port = 8481; } ];
      })
    ]
  );

  # A CR with no namespace (cluster-scoped) does not exempt a namespaced Service.
  p04d-cluster-scoped-cr-does-not-exempt = onlyFailure "Service a/prom-operated" (
    base "a"
    ++ [
      (res "Prometheus" null "prom" { apiVersion = "monitoring.coreos.com/v1"; })
      (service "a" "prom-operated" { operated = "yes"; } { spec.ports = [ { port = 9090; } ]; })
    ]
  );

  p05-hpa-target-present = clean (
    base "a"
    ++ [
      (res "HorizontalPodAutoscaler" "a" "hpa" {
        apiVersion = "autoscaling/v2";
        spec.scaleTargetRef = {
          kind = "Deployment";
          name = "web";
        };
      })
    ]
  );

  p06-statefulset-with-headless-service = clean (
    base "a"
    ++ [
      (service "a" "db-headless" podLabels { spec.clusterIP = "None"; })
      (res "StatefulSet" "a" "db" {
        apiVersion = "apps/v1";
        spec = {
          serviceName = "db-headless";
          selector.matchLabels = podLabels;
          template.metadata.labels = podLabels;
        };
      })
    ]
  );

  p10-ingress-backends-present = clean (
    base "a"
    ++ [
      (res "Ingress" "a" "ing" {
        apiVersion = "networking.k8s.io/v1";
        spec = {
          defaultBackend.service.name = "web";
          rules = [
            {
              http.paths = [
                {
                  path = "/";
                  backend.service.name = "web";
                }
              ];
            }
          ];
        };
      })
    ]
  );

  p10b-ingress-default-backend-missing = onlyFailure "references Service 'gone'" (
    base "a"
    ++ [
      (res "Ingress" "a" "ing" {
        apiVersion = "networking.k8s.io/v1";
        spec.defaultBackend.service.name = "gone";
      })
    ]
  );

  p12-networkpolicy-selects-a-workload = clean (
    base "a"
    ++ [
      (res "NetworkPolicy" "a" "np" {
        apiVersion = "networking.k8s.io/v1";
        spec.podSelector.matchLabels = podLabels;
      })
      (res "NetworkPolicy" "a" "np-all" {
        apiVersion = "networking.k8s.io/v1";
        spec.podSelector = { };
      })
    ]
  );

  p13-numeric-targetport-is-not-checked = clean (
    base "a"
    ++ [
      (service "a" "web-num" podLabels {
        spec.ports = [
          {
            port = 80;
            targetPort = 8080;
          }
        ];
      })
    ]
  );

  # --- external references ---

  # A name declared external resolves whatever its kind.
  e01-external-names-resolve =
    let
      fs = validate.crossResourceFailures {
        manifests = base "a" ++ [
          (deployment "a" "api" { spec.template.spec.serviceAccountName = "provided"; })
        ];
        externalNames = {
          "a/provided" = true;
        };
      };
    in
    fs == [ ] || throw "external ServiceAccount still failed: ${builtins.toJSON fs}";

  # The set is keyed by namespace: marked in `b` does not excuse `a`.
  e01b-external-names-are-namespaced =
    let
      fs = validate.crossResourceFailures {
        manifests = base "a" ++ [
          (deployment "a" "api" { spec.template.spec.serviceAccountName = "provided"; })
        ];
        externalNames = {
          "b/provided" = true;
        };
      };
    in
    (builtins.length fs == 1 && lib.hasInfix "references ServiceAccount 'provided'" (builtins.head fs))
    || throw "namespace key ignored: ${builtins.toJSON fs}";

  # A ServiceRef's declared pod selector is a witness for checks 4 and 12.
  e03-ref-pod-selector-is-a-witness = clean (
    base "a"
    ++ [
      (res "PackageInstance" "a" "service-ref-x-pg" {
        apiVersion = "kix.dev/v1alpha1";
        metadata.annotations = {
          "kix.dev/mode" = "import";
          "kix.dev/import-kind" = "Service";
          "kix.dev/import-name" = "pg";
          "kix.dev/service-selector" = builtins.toJSON {
            "app.kubernetes.io/name" = "postgres";
            cluster = "pg";
          };
          "kix.dev/service-ports" = builtins.toJSON [ { port = 5432; } ];
        };
      })
      (service "a" "pg-rw" { cluster = "pg"; } { spec.ports = [ { port = 5432; } ]; })
      (res "NetworkPolicy" "a" "np" {
        apiVersion = "networking.k8s.io/v1";
        spec.podSelector.matchLabels.cluster = "pg";
      })
    ]
  );

  e03b-ref-pod-selector-is-namespaced = onlyFailure "Service b/pg-rw" (
    base "a"
    ++ base "b"
    ++ [
      (res "PackageInstance" "a" "service-ref-x-pg" {
        apiVersion = "kix.dev/v1alpha1";
        metadata.annotations = {
          "kix.dev/mode" = "import";
          "kix.dev/import-kind" = "Service";
          "kix.dev/import-name" = "pg";
          "kix.dev/service-selector" = builtins.toJSON { cluster = "pg"; };
        };
      })
      (service "b" "pg-rw" { cluster = "pg"; } { spec.ports = [ { port = 5432; } ]; })
    ]
  );

  # An import marker for a Service satisfies an Ingress backend.
  e02-import-marker-is-the-object = clean (
    base "a"
    ++ [
      (res "PackageInstance" "a" "service-ref-x-db" {
        apiVersion = "kix.dev/v1alpha1";
        metadata.annotations = {
          "kix.dev/mode" = "import";
          "kix.dev/import-kind" = "Service";
          "kix.dev/import-apiversion" = "v1";
          "kix.dev/import-name" = "db";
        };
      })
      (res "Ingress" "a" "ing" {
        apiVersion = "networking.k8s.io/v1";
        spec.defaultBackend.service.name = "db";
      })
    ]
  );

  # The marker is namespaced: a ref in another namespace does not count.
  e02b-import-marker-is-namespaced = onlyFailure "references Service 'db'" (
    base "a"
    ++ base "b"
    ++ [
      (res "PackageInstance" "b" "service-ref-x-db" {
        apiVersion = "kix.dev/v1alpha1";
        metadata.annotations = {
          "kix.dev/mode" = "import";
          "kix.dev/import-kind" = "Service";
          "kix.dev/import-name" = "db";
        };
      })
      (res "Ingress" "a" "ing" {
        apiVersion = "networking.k8s.io/v1";
        spec.defaultBackend.service.name = "db";
      })
    ]
  );

  # --- wiring into buildCluster ---

  # kix.untrackedRef on a ServiceAccount name builds.
  v23-untracked-ref-serviceaccount-builds =
    let
      ms = manifests (mkCluster [
        baseInstances
        { instances.infra.ext.package = externalSaPackage; }
      ]);
    in
    builtins.any (m: (m.metadata.name or "") == "ext") ms || throw "external-SA deployment missing";

  # Provenance without resolution is still a failure.
  v24-suffixed-name-with-context-fails = evalFails (mkCluster [
    baseInstances
    { instances.infra.sfx.package = suffixedSaPackage; }
  ]);

  # One entry per resource even when an instance names it twice.
  v20-raw-manifests-dedupe-by-store-path =
    let
      ms = manifests (mkCluster [
        baseInstances
        { instances.infra.twice.package = aliasedPackage; }
      ]);
      hits = builtins.filter (m: (m.kind or "") == "ConfigMap" && (m.metadata.name or "") == "twice") ms;
    in
    builtins.length hits == 1
    || throw "expected one ConfigMap/twice, got ${toString (builtins.length hits)}";

  # A dangling Service selector fails the cluster eval, not just a flake check.
  v21-cross-resource-failure-fails-the-build = evalFails (mkCluster [
    baseInstances
    { instances.infra.dangling.package = brokenServicePackage; }
  ]);

}

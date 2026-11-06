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
  # Kix's own annotation keys and API names, spelled once in
  # core/annotations.nix.
  kixAnnotations = import ../core/annotations.nix;
  kixKeys = kixAnnotations.keys;
  # Each manifest's identity hash is a readable stand-in built from its
  # kind, namespace and name; `dependsOn` writes the same ids, so check 21
  # can follow kix.run/depends-on in hand-built lists.
  idOf = m: "${m.kind}-${m.metadata.namespace or "_"}-${m.metadata.name}";
  dependsOn = targets: {
    metadata.annotations.${kixKeys.dependsOn} = builtins.concatStringsSep "," (map idOf targets);
  };
  failures =
    ms:
    validate.crossResourceFailures {
      manifests = ms;
      identityHashes = map idOf ms;
      owners = map (_: null) ms;
    };

  # Failures with externalNames set as well.
  failuresWith =
    { manifests, externalNames }:
    validate.crossResourceFailures {
      inherit manifests externalNames;
      identityHashes = map idOf manifests;
      owners = map (_: null) manifests;
    };

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

  pdb =
    ns: name: selector: extra:
    res "PodDisruptionBudget" ns name (
      lib.recursiveUpdate {
        apiVersion = "policy/v1";
        spec = {
          minAvailable = 1;
          selector.matchLabels = selector;
        };
      } extra
    );

  # A ServiceRef marker as scope.mkServiceRef renders it: the operator's
  # pods exist by declaration.
  serviceRef =
    ns: svcName: selector:
    res "PackageInstance" ns "service-ref-${svcName}" {
      apiVersion = kixAnnotations.apiVersion;
      metadata.annotations = {
        ${kixKeys.mode} = "import";
        ${kixKeys.importKind} = "Service";
        ${kixKeys.importName} = svcName;
        ${kixKeys.serviceSelector} = builtins.toJSON selector;
        ${kixKeys.servicePorts} = builtins.toJSON [
          {
            name = "http";
            port = 80;
          }
        ];
      };
    };

  # A Job whose pod labels satisfy a Service selector in its namespace.
  job =
    ns: name: labels:
    res "Job" ns name {
      apiVersion = "batch/v1";
      spec.template = {
        metadata.labels = labels;
        spec = {
          restartPolicy = "Never";
          containers = [
            {
              name = "run";
              image = "img:1";
            }
          ];
        };
      };
    };

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

  # Exactly one failure per needle, each containing its needle.
  failuresInclude =
    needles: ms:
    let
      fs = failures ms;
    in
    (
      builtins.length fs == builtins.length needles
      && builtins.all (n: builtins.any (lib.hasInfix n) fs) needles
    )
    || throw "expected failures containing ${builtins.toJSON needles}, got: ${builtins.toJSON fs}";

  clean =
    ms:
    let
      fs = failures ms;
    in
    fs == [ ] || throw "expected no failures, got: ${builtins.toJSON fs}";

  crdOf =
    kind: plural: scope:
    res "CustomResourceDefinition" null "${plural}.example.com" {
      apiVersion = "apiextensions.k8s.io/v1";
      spec = {
        group = "example.com";
        names.kind = kind;
        inherit scope;
        versions = [
          {
            name = "v1";
            served = true;
            storage = true;
          }
        ];
      };
    };
  crd = crdOf "Widget" "widgets";
  vmCrd = res "CustomResourceDefinition" null "vmclusters.operator.victoriametrics.com" {
    apiVersion = "apiextensions.k8s.io/v1";
    spec = {
      group = "operator.victoriametrics.com";
      names.kind = "VMCluster";
      scope = "Namespaced";
      versions = [
        {
          name = "v1beta1";
          served = true;
          storage = true;
        }
      ];
    };
  };

  # A CRD ref marker for a prometheus-operator kind in namespace `ns`, and
  # a custom resource of that kind that depends on it.
  promRef =
    ns: kind: plural:
    res "PackageInstance" ns "crd-ref-x-${plural}-monitoring-coreos-com" {
      apiVersion = kixAnnotations.apiVersion;
      metadata.annotations = {
        ${kixKeys.mode} = "import";
        ${kixKeys.importKind} = "CustomResourceDefinition";
        ${kixKeys.importApiVersion} = "apiextensions.k8s.io/v1";
        ${kixKeys.importName} = "${plural}.monitoring.coreos.com";
        ${kixKeys.crdKind} = kind;
        ${kixKeys.crdVersion} = "v1";
        ${kixKeys.crdServedVersions} = "v1";
        ${kixKeys.crdScope} = "Namespaced";
      };
    };
  promCr = kind: plural: ns: name: [
    (promRef "a" kind plural)
    (res kind ns name (
      lib.recursiveUpdate { apiVersion = "monitoring.coreos.com/v1"; } (dependsOn [
        (promRef "a" kind plural)
      ])
    ))
  ];

  # Inline packages for the cluster-level cases.
  clusterConfigMapPackage = {
    build =
      { self, scope, ... }:
      {
        cm = scope.mkClusterResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "unns";
          data.k = "v";
        };
        root = self.cm;
      };
  };

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

  # A provider that exposes an import marker through `out`, and a consumer
  # that holds that marker as a part. Both instances list the marker.
  markerProviderPackage = {
    build =
      { self, scope, ... }:
      {
        secret = scope.mkSecretRef {
          name = "creds";
          keys = [ "password" ];
        };
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "provider";
          data.k = "v";
        };
        root = {
          resource = self.cm;
          out.secret = self.secret;
        };
      };
  };
  markerConsumerPackage = {
    build =
      {
        self,
        scope,
        provider,
        ...
      }:
      {
        held = provider.out.secret;
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "consumer";
          data.secret = provider.out.secret.out.name;
        };
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

  v03-configmap-volume-missing =
    onlyFailure "mounts ConfigMap 'cfg-typo' which is not in the cluster build"
      (
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

  # A namespaced lookup must not be satisfied by a cluster-scoped object of
  # the same kind and name (kixpkgs#71 item 5). ConfigMap is namespaced in
  # Kubernetes; the cluster-scoped one here is synthetic, which is the point:
  # the checker must not guess. Check 18 also refuses the synthetic object.
  v03b-cluster-scoped-namesake-does-not-satisfy-namespaced-lookup =
    failuresInclude
      [
        "mounts ConfigMap 'shared' which is not in the cluster build"
        "ConfigMap shared (v1) is a namespaced kind"
      ]
      (
        base "a"
        ++ [
          (res "ConfigMap" null "shared" { data.k = "v"; })
          (deployment "a" "api" {
            spec.template.spec.volumes = [
              {
                name = "cfg";
                configMap.name = "shared";
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

  # A Service over operator-created pods declares the CR; the CR is present.
  v04c-operand-of-declared-cr-present = clean (
    base "a"
    ++ promCr "Prometheus" "prometheuses" "a" "prom"
    ++ [
      (service "a" "prom-thanos" { operated = "yes"; } {
        metadata.annotations.${kixKeys.operandOf} = "monitoring.coreos.com/Prometheus/prom";
        spec.ports = [ { port = 10901; } ];
      })
    ]
  );

  # The declaration is namespaced: the CR must be in the Service's namespace.
  v04d-operand-of-is-namespaced =
    onlyFailure
      "declares ${kixKeys.operandOf}=monitoring.coreos.com/Prometheus/prom but that custom resource"
      (
        base "a"
        ++ base "b"
        ++ promCr "Prometheus" "prometheuses" "a" "prom"
        ++ [
          (service "b" "prom-thanos" { operated = "yes"; } {
            metadata.annotations.${kixKeys.operandOf} = "monitoring.coreos.com/Prometheus/prom";
            spec.ports = [ { port = 10901; } ];
          })
        ]
      );

  # Keyed by group: a kind of the same name in another group does not count.
  v04e-operand-of-checks-the-group =
    onlyFailure "declares ${kixKeys.operandOf}=other.example/Prometheus/prom"
      (
        base "a"
        ++ promCr "Prometheus" "prometheuses" "a" "prom"
        ++ [
          (service "a" "prom-thanos" { operated = "yes"; } {
            metadata.annotations.${kixKeys.operandOf} = "other.example/Prometheus/prom";
            spec.ports = [ { port = 10901; } ];
          })
        ]
      );

  # A declaration that is not group/Kind/name is reported as such.
  v04g-operand-of-malformed = onlyFailure "which is not of the form <group>/<Kind>/<name>" (
    base "a"
    ++ [
      (service "a" "prom-thanos" { operated = "yes"; } {
        metadata.annotations.${kixKeys.operandOf} = "Prometheus/prom";
        spec.ports = [ { port = 10901; } ];
      })
    ]
  );

  # No declaration, no match: the plain message, and no kind is exempt by name.
  v04f-no-kind-is-exempt-by-name = onlyFailure "matches no workload pod template" (
    base "a"
    ++ [
      (res "VMCluster" "a" "vm" (
        lib.recursiveUpdate { apiVersion = "operator.victoriametrics.com/v1beta1"; } (dependsOn [ vmCrd ])
      ))
      vmCrd
      (service "a" "vm-select" { "app.kubernetes.io/name" = "vmselect"; } {
        spec.ports = [ { port = 8481; } ];
      })
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

  v09-selector-outside-template-labels = onlyFailure "does not match pod template labels" (
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

  # A selector reaches pods in its own namespace only (red team on #75).
  v04h-service-cannot-select-pods-in-another-namespace =
    onlyFailure "matches no workload pod template"
      (
        base "a"
        ++ [
          (namespace "b")
          (service "b" "web-b" podLabels { })
        ]
      );

  v12b-networkpolicy-cannot-select-pods-in-another-namespace = onlyFailure "podSelector" (
    base "a"
    ++ [
      (namespace "b")
      (res "NetworkPolicy" "b" "np" {
        apiVersion = "networking.k8s.io/v1";
        spec.podSelector.matchLabels = podLabels;
      })
    ]
  );

  # --- 14. PodDisruptionBudget selectors ---

  v14c-pdb-cannot-select-pods-in-another-namespace =
    onlyFailure "PodDisruptionBudget b/pdb selector"
      (
        base "a"
        ++ [
          (namespace "b")
          (pdb "b" "pdb" podLabels { })
        ]
      );

  v14-pdb-selects-nothing = onlyFailure "PodDisruptionBudget a/lost selector" (
    base "a" ++ [ (pdb "a" "lost" { app = "nope"; } { }) ]
  );

  v14b-pdb-operand-of-missing-cr = onlyFailure "but that custom resource is not in the build" (
    base "a"
    ++ [
      (pdb "a" "am" { "app.kubernetes.io/name" = "alertmanager"; } {
        metadata.annotations.${kixKeys.operandOf} = "monitoring.coreos.com/Alertmanager/am";
      })
    ]
  );

  p14-pdb-selects-pod-template = clean (base "a" ++ [ (pdb "a" "web" podLabels { }) ]);

  # matchExpressions-only selectors have no matchLabels to resolve.
  p14b-pdb-without-matchlabels-is-skipped = clean (
    base "a"
    ++ [
      (pdb "a" "expr" { } {
        spec.selector = {
          matchExpressions = [
            {
              key = "app";
              operator = "In";
              values = [ "web" ];
            }
          ];
        };
      })
    ]
  );

  p14c-pdb-over-ref-pods = clean (
    base "a"
    ++ [
      (serviceRef "a" "vmselect-vm" { "app.kubernetes.io/name" = "vmselect"; })
      (pdb "a" "vmselect" { "app.kubernetes.io/name" = "vmselect"; } { })
    ]
  );

  p14d-pdb-operand-of-declared-cr-present = clean (
    base "a"
    ++ promCr "Alertmanager" "alertmanagers" "a" "am"
    ++ [
      (pdb "a" "am" { "app.kubernetes.io/name" = "alertmanager"; } {
        metadata.annotations.${kixKeys.operandOf} = "monitoring.coreos.com/Alertmanager/am";
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

  # The cluster-scoped bucket still serves kinds that are cluster-scoped:
  # a RoleBinding may bind a ClusterRole.
  p02c-rolebinding-to-present-clusterrole = clean (
    base "a"
    ++ [
      (res "ClusterRole" null "reader" { apiVersion = "rbac.authorization.k8s.io/v1"; })
      (res "RoleBinding" "a" "rb" {
        apiVersion = "rbac.authorization.k8s.io/v1";
        roleRef = {
          kind = "ClusterRole";
          name = "reader";
        };
      })
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

  # A cluster-scoped CR (no namespace) cannot be the operand source of a namespaced Service.
  p04d-cluster-scoped-cr-does-not-exempt =
    onlyFailure
      "declares ${kixKeys.operandOf}=monitoring.coreos.com/Prometheus/prom but that custom resource"
      (
        base "a"
        # A ref that declares the kind cluster-scoped, so check 18 accepts
        # the CR without a namespace.
        ++ map (
          m:
          if m.kind == "PackageInstance" then
            lib.recursiveUpdate m { metadata.annotations.${kixKeys.crdScope} = "Cluster"; }
          else
            m
        ) (promCr "Prometheus" "prometheuses" null "prom")
        ++ [
          (service "a" "prom-operated" { operated = "yes"; } {
            metadata.annotations.${kixKeys.operandOf} = "monitoring.coreos.com/Prometheus/prom";
            spec.ports = [ { port = 9090; } ];
          })
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
      fs = failuresWith {
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
      fs = failuresWith {
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
        apiVersion = kixAnnotations.apiVersion;
        metadata.annotations = {
          ${kixKeys.mode} = "import";
          ${kixKeys.importKind} = "Service";
          ${kixKeys.importName} = "pg";
          ${kixKeys.serviceSelector} = builtins.toJSON {
            "app.kubernetes.io/name" = "postgres";
            cluster = "pg";
          };
          ${kixKeys.servicePorts} = builtins.toJSON [ { port = 5432; } ];
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
        apiVersion = kixAnnotations.apiVersion;
        metadata.annotations = {
          ${kixKeys.mode} = "import";
          ${kixKeys.importKind} = "Service";
          ${kixKeys.importName} = "pg";
          ${kixKeys.serviceSelector} = builtins.toJSON { cluster = "pg"; };
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
        apiVersion = kixAnnotations.apiVersion;
        metadata.annotations = {
          ${kixKeys.mode} = "import";
          ${kixKeys.importKind} = "Service";
          ${kixKeys.importApiVersion} = "v1";
          ${kixKeys.importName} = "db";
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
        apiVersion = kixAnnotations.apiVersion;
        metadata.annotations = {
          ${kixKeys.mode} = "import";
          ${kixKeys.importKind} = "Service";
          ${kixKeys.importName} = "db";
        };
      })
      (res "Ingress" "a" "ing" {
        apiVersion = "networking.k8s.io/v1";
        spec.defaultBackend.service.name = "db";
      })
    ]
  );

  # --- 15. Job pods are not Service endpoints ---

  v15-job-pods-selected-by-service = onlyFailure "would route traffic to the Job pod" (
    base "a" ++ [ (job "a" "hook" podLabels) ]
  );

  # Distinct labels, or a Service in another namespace, are fine.
  v15b-job-pods-with-own-labels = clean (
    base "a"
    ++ base "b"
    ++ [
      (job "a" "hook" {
        app = "hook";
      })
      (job "b" "other" {
        app = "web";
        role = "other";
      })
    ]
    # A superset in another namespace: b's Service selects b's Job pod,
    # so that one is a failure; take it out of the clean set.
    |> builtins.filter (m: !(m.kind == "Job" && m.metadata.namespace == "b"))
  );

  # --- 16. kix.run/rerun is for Jobs ---

  v16-rerun-on-a-deployment-is-refused = onlyFailure "the rerun rule applies to Jobs only" (
    base "a"
    ++ [
      (deployment "a" "worker" {
        metadata.annotations.${kixKeys.rerun} = "on-change";
        spec.selector.matchLabels.app = "worker";
        spec.template.metadata.labels.app = "worker";
      })
    ]
  );

  v16c-rerun-with-another-value-is-refused = onlyFailure "the supported value" (
    base "a"
    ++ [
      (lib.recursiveUpdate (job "a" "probe" { app = "probe"; }) {
        metadata.annotations.${kixKeys.rerun} = "always";
      })
    ]
  );

  v16b-rerun-on-a-job-is-fine = clean (
    base "a"
    ++ [
      (lib.recursiveUpdate (job "a" "probe" { app = "probe"; }) {
        metadata.annotations.${kixKeys.rerun} = "on-change";
      })
    ]
  );

  # --- 17. priorityClassName references ---

  v17a-priority-class-missing = onlyFailure "sets priorityClassName 'nope'" (
    base "a"
    ++ [
      (deployment "a" "prio" { spec.template.spec.priorityClassName = "nope"; })
    ]
  );

  v17b-priority-class-built-is-fine = clean (
    base "a"
    ++ [
      (deployment "a" "prio" { spec.template.spec.priorityClassName = "mine"; })
      (res "PriorityClass" null "mine" { apiVersion = "scheduling.k8s.io/v1"; })
    ]
  );

  # The classes Kubernetes ships with are never in a kix build.
  v17c-system-priority-class-is-builtin = clean (
    base "a"
    ++ [
      (deployment "a" "prio" {
        spec.template.spec.priorityClassName = "system-cluster-critical";
      })
    ]
  );

  v18a-namespaced-builtin-without-namespace =
    onlyFailure "ConfigMap shared (v1) is a namespaced kind but has no metadata.namespace"
      (base "a" ++ [ (res "ConfigMap" null "shared" { }) ]);

  # The group decides: a custom kind named like a built-in is not refused
  # unless its CRD in the build says Namespaced.
  v18b-same-name-in-another-group-is-fine = clean (
    base "a"
    ++ [
      (crdOf "Service" "services" "Cluster")
      (res "Service" null "edge" (
        lib.recursiveUpdate { apiVersion = "example.com/v1"; } (dependsOn [
          (crdOf "Service" "services" "Cluster")
        ])
      ))
    ]
  );

  v18c-namespaced-custom-kind-without-namespace =
    onlyFailure "Widget w (example.com/v1) is a namespaced kind"
      (
        base "a"
        ++ [
          (crd "Namespaced")
          (res "Widget" null "w" (
            lib.recursiveUpdate { apiVersion = "example.com/v1"; } (dependsOn [ (crd "Namespaced") ])
          ))
        ]
      );

  v18d-cluster-scoped-custom-kind-is-fine = clean (
    base "a"
    ++ [
      (crd "Cluster")
      (res "Widget" null "w" (
        lib.recursiveUpdate { apiVersion = "example.com/v1"; } (dependsOn [ (crd "Cluster") ])
      ))
    ]
  );

  # --- wiring into buildCluster ---

  # scope.mkClusterResource with a namespaced kind fails the cluster eval.
  v18e-cluster-resource-of-namespaced-kind-fails-the-build = evalFails (mkCluster [
    baseInstances
    { instances.infra.unns.package = clusterConfigMapPackage; }
  ]);

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

  # kix-packages.json lists a resource once under its instance, even when
  # the instance names it under two parts.
  v20-package-index-lists-an-alias-once =
    let
      index =
        (mkCluster [
          baseInstances
          { instances.infra.twice.package = aliasedPackage; }
        ]).packageIndexContent;
      repeated = lib.filterAttrs (
        _: paths: builtins.length paths != builtins.length (lib.unique paths)
      ) index.packages;
    in
    repeated == { }
    || throw "kix-packages.json repeats a path under ${toString (builtins.attrNames repeated)}";

  # kix-packages.json lists an import marker that a consumer holds through
  # the provider's `out` under the provider only, so the marker's owner does
  # not depend on store-path order.
  v20-package-index-lists-a-shared-marker-under-its-builder =
    let
      cluster = mkCluster [
        baseInstances
        {
          instances.infra.provider.package = markerProviderPackage;
          instances.infra.consumer.package = markerConsumerPackage;
        }
      ];
      plain = v: builtins.unsafeDiscardStringContext (toString v);
      packages = lib.mapAttrs (_: map plain) cluster.packageIndexContent.packages;
      provider = cluster.clusterInstances.infra.provider;
      consumer = cluster.clusterInstances.infra.consumer;
      providerPi = plain provider._packageInstance.outPath;
      consumerPi = plain consumer._packageInstance.outPath;
      marker = plain provider.out.secret.outPath;
      consumerCm = plain (consumer.raw or consumer).cm.outPath;
      listedUnder =
        path: builtins.attrNames (lib.filterAttrs (_: paths: builtins.elem path paths) packages);
      allPaths = builtins.concatLists (builtins.attrValues packages);
      repeated = builtins.filter (p: builtins.length (builtins.filter (q: q == p) allPaths) > 1) (
        lib.unique allPaths
      );
    in
    if repeated != [ ] then
      throw "kix-packages.json lists ${toString repeated} under more than one package"
    else if listedUnder marker != [ providerPi ] then
      throw "marker is listed under ${toString (listedUnder marker)}, expected the provider"
    else if !(builtins.elem consumerCm packages.${consumerPi}) then
      throw "the consumer lost its own ConfigMap"
    else
      true;

  # A dangling Service selector fails the cluster eval, not just a flake check.
  v21-cross-resource-failure-fails-the-build = evalFails (mkCluster [
    baseInstances
    { instances.infra.dangling.package = brokenServicePackage; }
  ]);

}

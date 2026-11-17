# Tests for kix/packages/experimental/cert-manager: the flag and env guards, the release
# check, the gated CRD handles, the metrics gate, and the `apiserver` ingress
# intent source in the cilium package. cert-manager runs as instance
# `cert-manager` in namespace `cert-manager`.

{
  lib,
  eval,
  kixKeys,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  containerBase,
  prometheusStub,
  ...
}:

let
  certManagerPackage = import ../../../packages/experimental/cert-manager;
  ciliumPackage = import ../../../packages/experimental/cilium;

  clusterWith =
    {
      config ? { },
      modules ? [ ],
    }:
    mkCluster (
      [
        {
          instances.cert-manager.cert-manager = {
            package = certManagerPackage;
            inherit config;
          };
        }
      ]
      ++ modules
    );

  deploymentOfAll =
    cluster: name:
    (byName name (ofKind "Deployment" (manifests cluster))).spec.template.spec.containers;
  deploymentOf = cluster: name: builtins.head (deploymentOfAll cluster name);

  # A consumer that builds a ClusterIssuer, a Certificate, and a
  # CertificateRequest through out.crds.
  consumerPackage = {
    meta.version = "test";
    build =
      {
        self,
        scope,
        certManager,
        ...
      }:
      {
        issuer = scope.mkCR certManager.out.crds.ClusterIssuer {
          name = "probe";
          spec.selfSigned = { };
        };
        request = scope.mkCR certManager.out.crds.CertificateRequest {
          name = "probe";
          spec = {
            request = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURSBSRVFVRVNULS0tLS0K";
            issuerRef = {
              name = self.issuer.out.name;
              kind = "ClusterIssuer";
              group = "cert-manager.io";
            };
          };
        };
        cert = scope.mkCR certManager.out.crds.Certificate {
          name = "probe";
          spec = {
            secretName = "probe-tls";
            dnsNames = [ "probe.example.test" ];
            issuerRef = {
              name = self.issuer.out.name;
              kind = "ClusterIssuer";
              group = "cert-manager.io";
            };
          };
        };
        root = {
          resource = self.cert;
          requires = [
            self.issuer
            self.request
          ];
        };
      };
  };
in
{
  # The cilium enforcer translates `from = "apiserver"` into the entities
  # its apiserver egress rule uses, keeping the intent's ports.
  cert-manager-apiserver-ingress-source =
    let
      webPackage = {
        meta = {
          version = "test";
          network.intents.w.ingress = [
            {
              from = "apiserver";
              ports = [ { port = 8443; } ];
            }
          ];
        };
        build =
          { self, scope, ... }:
          {
            web = scope.mkDeployment {
              name = "web";
              spec = {
                selector.matchLabels.app = "web";
                template.spec.containers = [
                  (
                    containerBase
                    // {
                      name = "web";
                      image = "example.test/web:1";
                    }
                  )
                ];
              };
            };
            root = self.web;
          };
      };
      ms = manifests (mkCluster [
        {
          cluster.roles.cni = {
            binding = "shadowable";
            provider = "cilium (environment)";
          };
          networkPolicy.enable = true;
          instances.net.cilium.package = ciliumPackage;
          instances.net.platform-cilium.package = eval.mkImport {
            roles = [ "cni" ];
            out.helmChartConfig = null;
          };
          instances.app.web.package = webPackage;
        }
      ]);
      cnp = byName "web-deployment-web-ingress" (ofKind "CiliumNetworkPolicy" ms);
      rule = builtins.head cnp.spec.ingress;
    in
    (
      cnp != null
      &&
        rule.fromEntities == [
          "kube-apiserver"
          "remote-node"
          "host"
        ]
      && (builtins.head (builtins.head rule.toPorts).ports).port == "8443"
    )
    || throw "apiserver ingress source: ${builtins.toJSON cnp}";

  # extraArgs are appended, and each component refuses the flags it derives.
  cert-manager-extra-args-guard =
    let
      appended = (deploymentOf (clusterWith { config.extraArgs = [ "--v=4" ]; }) "cert-manager").args;
    in
    (
      lib.last appended == "--v=4"
      && evalFails (clusterWith {
        config.webhook.extraArgs = [ "--secure-port=10260" ];
      })
      && evalFails (clusterWith {
        config.extraArgs = [
          "--cluster-resource-namespace"
          "x"
        ];
      })
      && evalFails (clusterWith {
        config.extraArgs = [ "--acme-http01-solver-image=x" ];
      })
      && evalFails (clusterWith {
        config.cainjector.extraArgs = [ "--leader-election-namespace=x" ];
      })
    )
    || throw "extraArgs guard: controller args ${builtins.toJSON appended}";

  # The controller keeps its POD_NAMESPACE beside the instance's env, and
  # refuses an env that sets it.
  cert-manager-env-keeps-pod-namespace =
    let
      env = builtins.listToAttrs (
        map (e: lib.nameValuePair e.name e)
          (deploymentOf (clusterWith {
            config.env.HTTPS_PROXY = "http://proxy.example.test:3128";
          }) "cert-manager").env
      );
    in
    (
      env.POD_NAMESPACE.valueFrom.fieldRef.fieldPath == "metadata.namespace"
      && env.HTTPS_PROXY.value == "http://proxy.example.test:3128"
      && evalFails (clusterWith {
        config.env.POD_NAMESPACE = "x";
      })
    )
    || throw "controller env: ${builtins.toJSON env}";

  # A tag of the vendored minor release renders on every image without a
  # digest; another minor release fails, on the controller's tag and on each
  # follower's own tag.
  cert-manager-release-check =
    let
      cluster = clusterWith { config.image.tag = "v1.21.2"; };
      images = map (c: c.image) (
        builtins.concatMap (m: m.spec.template.spec.containers) (
          ofKind "Deployment" (manifests cluster) ++ ofKind "Job" (manifests cluster)
        )
      );
      controllerArgs = (deploymentOf cluster "cert-manager").args;
    in
    (
      builtins.length images == 4
      && builtins.all (i: lib.hasSuffix ":v1.21.2" i) images
      && builtins.elem "--acme-http01-solver-image=quay.io/jetstack/cert-manager-acmesolver:v1.21.2" controllerArgs
      && evalFails (clusterWith {
        config.image.tag = "v1.22.0";
      })
      && evalFails (clusterWith {
        config.image.tag = "latest";
      })
      && builtins.elem "quay.io/jetstack/cert-manager-webhook:v1.21.2" (
        map (c: c.image) (
          deploymentOfAll (clusterWith { config.webhook.image.tag = "v1.21.2"; }) "cert-manager-webhook"
        )
      )
      && evalFails (clusterWith {
        config.webhook.image.tag = "v1.22.0";
      })
      && evalFails (clusterWith {
        config.cainjector.image.tag = "v1.16.0";
      })
      && evalFails (clusterWith {
        config.startupapicheck.image.tag = "v1.20.0";
      })
      && evalFails (clusterWith {
        config.operandImages.acmesolver.tag = "v1.19.0";
      })
    )
    || throw "release check: images ${builtins.toJSON images}";

  # Custom resources built through out.crds declare readiness and require
  # the API-check Job.
  cert-manager-crd-handles-gated =
    let
      cluster = clusterWith {
        modules = [ { instances.cert-manager.consumer.package = consumerPackage; } ];
      };
      ms = manifests cluster;
      jobHash = builtins.unsafeDiscardStringContext cluster.instances.cert-manager.cert-manager.raw.apiCheck.out.identityHash;
      annotations = m: m.metadata.annotations or { };
      gated =
        m:
        lib.hasInfix jobHash ((annotations m).${kixKeys.dependsOn} or "")
        &&
          builtins.fromJSON (annotations m).${kixKeys.readiness} == {
            condition = {
              type = "Ready";
              status = "True";
            };
          };
      cert = byName "probe" (ofKind "Certificate" ms);
      issuer = byName "probe" (ofKind "ClusterIssuer" ms);
      request = byName "probe" (ofKind "CertificateRequest" ms);
      kinds = builtins.attrNames cluster.instances.cert-manager.cert-manager.out.crds;
    in
    (
      gated cert
      && gated issuer
      && gated request
      &&
        kinds == [
          "Certificate"
          "CertificateRequest"
          "Challenge"
          "ClusterIssuer"
          "Issuer"
          "Order"
        ]
    )
    || throw "gated handles: ${
      builtins.toJSON {
        inherit
          cert
          issuer
          request
          kinds
          ;
      }
    }";

  # Without a prometheus provider there are no metrics Services, ports, or
  # monitors; with one there are three of each and one PrometheusRule whose
  # alerts select the controller Service.
  cert-manager-metrics-gated =
    let
      count = kind: ms: builtins.length (ofKind kind ms);
      without = manifests (clusterWith { });
      withProm = manifests (clusterWith {
        modules = [ { instances.monitoring.prometheus.package = prometheusStub; } ];
      });
      disabled = manifests (clusterWith {
        config.metrics.enabled = false;
        modules = [ { instances.monitoring.prometheus.package = prometheusStub; } ];
      });
      webhookPorts = ms: map (p: p.name) (byName "cert-manager-webhook" (ofKind "Service" ms)).spec.ports;
      rule = builtins.head (ofKind "PrometheusRule" withProm);
      alertRules = (builtins.head rule.spec.groups).rules;
    in
    (
      count "Service" without == 1
      && webhookPorts without == [ "https" ]
      && count "ServiceMonitor" without == 0
      && count "Service" withProm == 3
      &&
        webhookPorts withProm == [
          "https"
          "metrics"
        ]
      && count "ServiceMonitor" withProm == 3
      && count "PrometheusRule" withProm == 1
      &&
        map (r: r.alert) alertRules == [
          "CertManagerAbsent"
          "CertManagerCertificateNotReady"
          "CertManagerCertificateRenewalOverdue"
        ]
      && builtins.all (
        r: lib.hasInfix ''namespace="cert-manager",service="cert-manager"'' r.expr
      ) alertRules
      && count "Service" disabled == 1
      && count "ServiceMonitor" disabled == 0
    )
    || throw "metrics gate: ${
      builtins.toJSON {
        without = count "Service" without;
        withProm = count "Service" withProm;
      }
    }";
}

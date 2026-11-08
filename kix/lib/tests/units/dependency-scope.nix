# Tests for the namespace rule of dependency resolution (eval/resolve.nix
# resolveArg, eval/auto.nix pickOptional). A package argument is filled
# from the consumer's own namespace. An instance in another namespace binds
# only when the cluster definition names it with `ref`, or when its package
# serves the whole cluster (meta.nix servesCluster): `meta.scope =
# "cluster"`, a role in `meta.roles`, or a `cluster:` entry in
# `meta.conflictsWith`. `kix.mkImport` stand-ins serve the whole cluster.
# `meta.scope = "namespace"` refuses even a `ref` from another namespace.

{
  lib,
  mkCluster,
  mkCmPackage,
  manifests,
  ofKind,
  byName,
  evalFails,
  eval,
  ...
}:

let
  # A provider answering `svc`, with `metaExtra` merged into its meta.
  provider =
    metaExtra:
    mkCmPackage {
      name = "svc";
      metaExtra = {
        defaultAliases = [ "svc" ];
      }
      // metaExtra;
      out.who = "svc";
    };

  plain = provider { };

  # A ConfigMap named `consumer` whose `who` records the instance that
  # answered `svc`, as `<namespace>/<instance>`.
  mkConsumer = optional: {
    meta.version = "test";
    build =
      if optional then
        {
          self,
          scope,
          svc ? null,
          ...
        }:
        {
          cm = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "consumer";
            extra.data.who =
              if svc == null then
                "none"
              else
                "${svc._meta.namespaceName or "?"}/${svc._meta.instanceName or "?"}";
          };
          root = self.cm;
        }
      else
        {
          self,
          scope,
          svc,
          ...
        }:
        {
          cm = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "consumer";
            extra.data.who = "${svc._meta.namespaceName or "?"}/${svc._meta.instanceName or "?"}";
          };
          root = self.cm;
        };
  };

  consumer = mkConsumer false;
  optionalConsumer = mkConsumer true;

  boundTo = cluster: (byName "consumer" (ofKind "ConfigMap" (manifests cluster))).data.who;

  # The consumer in `a`, the provider in `ns`.
  withProvider =
    ns: pkg:
    mkCluster [
      { instances.a.consumer.package = consumer; }
      { instances.${ns}.svc.package = pkg; }
    ];
in
{
  dependency-scope-same-namespace-binds =
    boundTo (withProvider "a" plain) == "a/svc" || throw "same-namespace provider not bound";

  dependency-scope-ref-binds-across-namespaces =
    let
      cluster = mkCluster [
        (
          { ref, ... }:
          {
            instances.a.consumer = {
              package = consumer;
              deps.svc = ref.b.svc;
            };
            instances.b.svc.package = plain;
          }
        )
      ];
    in
    boundTo cluster == "b/svc" || throw "ref to another namespace not bound: ${boundTo cluster}";

  dependency-scope-cluster-scope-binds-implicitly =
    boundTo (
      withProvider "b" (provider {
        scope = "cluster";
      })
    ) == "b/svc"
    || throw "meta.scope = \"cluster\" provider not bound from another namespace";

  dependency-scope-role-binds-implicitly =
    boundTo (
      withProvider "b" (provider {
        roles = [ "loadBalancer" ];
      })
    ) == "b/svc"
    || throw "role-claiming provider not bound from another namespace";

  dependency-scope-cluster-conflict-binds-implicitly =
    boundTo (
      withProvider "b" (provider {
        conflictsWith = [ "cluster:svc" ];
      })
    ) == "b/svc"
    || throw "cluster-conflict provider not bound from another namespace";

  # A single instance in another namespace whose package serves only by
  # name is not bound. The message text is checked by hand with nix eval.
  dependency-scope-foreign-single-refuses =
    evalFails (withProvider "b" plain) || throw "a plain provider in another namespace was bound";

  dependency-scope-two-foreign-refuse =
    evalFails (mkCluster [
      {
        instances.a.consumer.package = consumer;
        instances.b.svc.package = plain;
        instances.c.svc.package = plain;
      }
    ])
    || throw "two providers in other namespaces evaluated";

  # meta.scope = "namespace" wins over a role or a cluster conflict.
  dependency-scope-namespace-scope-wins-over-conflict =
    evalFails (
      withProvider "b" (provider {
        scope = "namespace";
        conflictsWith = [ "cluster:svc" ];
      })
    )
    || throw "a meta.scope = \"namespace\" provider with a cluster conflict was bound from another namespace";

  dependency-scope-namespace-scope-refuses-ref =
    evalFails (mkCluster [
      (
        { ref, ... }:
        {
          instances.a.consumer = {
            package = consumer;
            deps.svc = ref.b.svc;
          };
          instances.b.svc.package = provider { scope = "namespace"; };
        }
      )
    ])
    || throw "a ref to a meta.scope = \"namespace\" provider in another namespace evaluated";

  dependency-scope-import-binds-across-namespaces =
    boundTo (withProvider "b" (eval.mkImport { out.who = "svc"; })) == "b/svc"
    || throw "an import in another namespace was not bound";

  dependency-scope-unknown-scope-value-refuses =
    evalFails (
      withProvider "a" (provider {
        scope = "global";
      })
    )
    || throw "meta.scope = \"global\" evaluated";

  # An optional argument whose only match is in another namespace takes its
  # default, and the instance's diagnostics name the skipped instance and
  # the deps line to add.
  dependency-scope-optional-foreign-takes-default =
    let
      cluster = mkCluster [
        {
          instances.a.consumer.package = optionalConsumer;
          instances.b.svc.package = plain;
        }
      ];
      warnings = cluster.instances.a.consumer._diagnostics.warnings;
      message = "optional dependency 'svc' has no instance in namespace 'a', so Kix skips it. b/svc matches in another namespace. To use it, add this line to instances.a.consumer:\n  deps.svc = ref.b.svc;";
      expected = "a/consumer: ${message}";
      # With the scorecard on, the same text is a warning-level finding, so
      # `kix check` shows it.
      findings =
        (mkCluster [
          {
            instances.a.consumer.package = optionalConsumer;
            instances.b.svc.package = plain;
            scorecard = {
              enable = true;
              rules.architecture = import ../../rules/architecture.nix { inherit lib; };
            };
          }
        ]).scorecardReport.findings;
      finding = lib.findFirst (f: f.rule == "dependencies.optionalInOtherNamespace") null findings;
    in
    (
      boundTo cluster == "none"
      && builtins.elem expected warnings
      && finding != null
      && finding.severity == "warning"
      && finding.namespace == "a"
      && finding.instance == "consumer"
      && finding.message == message
    )
    || throw "optional foreign dependency: bound to ${boundTo cluster}; warnings ${builtins.toJSON warnings}; finding ${builtins.toJSON finding}";

  # A serving provider in another namespace binds an optional argument
  # without a warning.
  dependency-scope-optional-serving-binds =
    let
      cluster = mkCluster [
        {
          instances.a.consumer.package = optionalConsumer;
          instances.b.svc.package = provider { scope = "cluster"; };
        }
      ];
      warnings = cluster.instances.a.consumer._diagnostics.warnings;
    in
    (boundTo cluster == "b/svc" && !(builtins.any (lib.hasInfix "optional dependency 'svc'") warnings))
    || throw "optional serving dependency: bound to ${boundTo cluster}; warnings ${builtins.toJSON warnings}";

  # A demand from `a` switches on a dormant optional instance in `b` and
  # binds to it, because the cluster author chose where it lives. A
  # `meta.scope = "namespace"` optional instance stays out of reach.
  dependency-scope-optional-instance-activates-across-namespaces =
    let
      withOptional =
        pkg:
        mkCluster [
          {
            instances.a.consumer.package = consumer;
            instances.b.svc = {
              package = pkg;
              optional = true;
            };
          }
        ];
    in
    (
      boundTo (withOptional plain) == "b/svc"
      && evalFails (
        withOptional (provider {
          scope = "namespace";
        })
      )
    )
    || throw "optional instance in another namespace: bound to ${boundTo (withOptional plain)}";

  # An instance that a demand creates from availablePackages in autoNamespace
  # binds to the requester in another namespace.
  dependency-scope-auto-instantiated-in-auto-namespace-binds =
    let
      cluster = mkCluster [
        {
          availablePackages.svc.package = plain;
          autoNamespace = "platform";
          instances.a.consumer.package = consumer;
        }
      ];
    in
    boundTo cluster == "platform/svc"
    || throw "auto-instantiated instance in autoNamespace: bound to ${boundTo cluster}";

  # An always-on instance in another namespace that nothing demanded still
  # needs a `ref`, even when availablePackages could have placed one.
  dependency-scope-declared-foreign-still-refuses =
    evalFails (mkCluster [
      {
        availablePackages.svc.package = plain;
        autoNamespace = "platform";
        instances.a.consumer.package = consumer;
        instances.b.svc.package = plain;
      }
    ])
    || throw "a declared plain provider in another namespace was bound";
}

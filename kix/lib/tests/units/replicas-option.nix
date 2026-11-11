# Tests for the `replicas` option of echo-server and dns-exporter: the
# value reaches the Deployment, zero is refused, and the removed name
# `replicaCount` fails with a message that names `replicas`.

{
  lib,
  eval,
  kixlib,
  mkCluster,
  manifests,
  ofKind,
  evalFails,
  ...
}:

let
  packages = {
    echo-server = import ../../../packages/stable/echo-server;
    dns-exporter = import ../../../packages/experimental/dns-exporter;
  };

  withConfig =
    package: config:
    mkCluster [
      {
        instances.demo.app = {
          inherit package config;
        };
      }
    ];

  replicasOf = ms: map (d: d.spec.replicas) (ofKind "Deployment" ms);

  # The package's failed assertion messages for `config`. Throws lose
  # their message in tryEval, so the message is read from the assertions.
  failedMessages =
    package: config:
    let
      attrs = package (
        builtins.intersectAttrs (builtins.functionArgs package) {
          scope = {
            instanceName = "app";
            namespaceName = "demo";
          };
          inherit lib;
          kix = kixlib;
          availability = "none";
        }
      );
      evaluated = eval.evaluateInstanceConfig {
        packageOptions = attrs.options;
        instCfg.config.imports = [ config ];
        namespaceName = "demo";
        instanceName = "app";
      };
    in
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (
        attrs.assertions {
          config = evaluated;
          deps = { };
        }
      )
    );

  check =
    name: package:
    let
      renamed = failedMessages package { replicaCount = 2; };
    in
    (
      replicasOf (manifests (withConfig package { replicas = 3; })) == [ 3 ]
      && evalFails (withConfig package { replicas = 0; })
      && evalFails (withConfig package { replicaCount = 2; })
      && renamed == [ "replicaCount was renamed to replicas. Set config.replicas instead." ]
      && failedMessages package { } == [ ]
    )
    || throw "${name} replicas: ${builtins.toJSON { inherit renamed; }}";
in
{
  replicas-option-echo-server = check "echo-server" packages.echo-server;
  replicas-option-dns-exporter = check "dns-exporter" packages.dns-exporter;
}

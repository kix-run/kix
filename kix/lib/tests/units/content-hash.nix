# Tests for `out.contentHash`: the hash of a resource's own content, which a
# pod template's `checksum/<name>` annotation reads so pods roll when the
# data they read changes. It ignores changes below the resource in the
# graph and Kix's own annotations, keeps a SOPS Secret's digest, and carries
# the same dependency as `out.identityHash`.

{
  lib,
  kixKeys,
  mkCluster,
  manifests,
  byName,
  ...
}:

let
  # A package with a Service, a ConfigMap whose data names the Service's
  # address, a Secret, and a Deployment whose pod template carries the
  # ConfigMap's and the Secret's content hashes. `servicePort` changes the
  # Service only, `greeting` changes the ConfigMap's data, `cmAnnotations`
  # adds annotations to the ConfigMap, and `secretArgs` goes to mkSecret.
  appPackage =
    {
      servicePort ? 80,
      greeting ? "hello",
      cmAnnotations ? { },
      secretArgs ? {
        stringData.token = "t";
      },
    }:
    {
      meta.version = "test";
      build =
        { self, scope, ... }:
        {
          svc = scope.mkResource {
            apiVersion = "v1";
            kind = "Service";
            name = "backend";
            spec = {
              selector = scope.selectorLabels;
              ports = [
                {
                  name = "http";
                  port = servicePort;
                }
              ];
            };
          };
          cm = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "cfg";
            annotations = cmAnnotations;
            data = {
              inherit greeting;
              backend = self.svc.out.fqdn;
            };
          };
          secret = scope.mkSecret ({ name = "creds"; } // secretArgs);
          deploy = scope.mkDeployment {
            name = "web";
            spec = {
              selector.matchLabels = scope.selectorLabels;
              template = {
                metadata.annotations = {
                  "checksum/config" = self.cm.out.contentHash;
                  "checksum/creds" = self.secret.out.contentHash;
                };
                spec.containers = [
                  {
                    name = "web";
                    image = "nginx";
                  }
                ];
              };
            };
          };
          root = self.deploy;
        };
    };

  clusterOf = args: mkCluster [ { instances.a.app.package = appPackage args; } ];

  partOf = args: part: (clusterOf args).instances.a.app.raw.${part};
  hashes =
    args: part:
    let
      out = (partOf args part).out;
    in
    {
      identity = builtins.unsafeDiscardStringContext out.identityHash;
      content = builtins.unsafeDiscardStringContext out.contentHash;
    };

  deploymentOf =
    args: byName "web" (builtins.filter (m: m.kind == "Deployment") (manifests (clusterOf args)));
  checksumsOf = args: (deploymentOf args).spec.template.metadata.annotations;
  dependsOnOf =
    args: lib.splitString "," ((deploymentOf args).metadata.annotations.${kixKeys.dependsOn} or "");

  base = hashes { } "cm";
in
{
  # A change to the Service the ConfigMap names changes the ConfigMap's
  # identity hash through `kix.run/depends-on`, and leaves its content hash
  # and the Deployment's checksum annotation unchanged.
  content-hash-ignores-dependency-change =
    let
      moved = hashes { servicePort = 8080; } "cm";
    in
    (moved.identity != base.identity || throw "the identity hash should change with the Service")
    && (moved.content == base.content || throw "the content hash should not change with the Service")
    && (
      (checksumsOf { servicePort = 8080; })."checksum/config" == (checksumsOf { })."checksum/config"
      || throw "the Deployment's checksum/config should not change with the Service"
    );

  # A change to the ConfigMap's data changes its content hash.
  content-hash-follows-data =
    (hashes { greeting = "bye"; } "cm").content != base.content
    || throw "the content hash should change with data";

  # A `kix.run/*` annotation is Kix metadata and leaves the content hash
  # unchanged. Any other annotation changes it.
  content-hash-ignores-kix-annotations =
    (
      (hashes { cmAnnotations.${kixKeys.cedeFields} = "data"; } "cm").content == base.content
      || throw "a kix.run annotation should not change the content hash"
    )
    && (
      (hashes { cmAnnotations."example.com/note" = "x"; } "cm").content != base.content
      || throw "an annotation outside kix.run should change the content hash"
    );

  # Reading out.contentHash makes the reader depend on the resource, the
  # same as reading out.identityHash.
  content-hash-carries-dependency =
    let
      deps = dependsOnOf { };
    in
    (
      builtins.elem base.identity deps
      || throw "the Deployment should depend on the ConfigMap: ${toString deps}"
    )
    && (
      builtins.elem (hashes { } "secret").identity deps
      || throw "the Deployment should depend on the Secret: ${toString deps}"
    )
    && (
      (checksumsOf { })."checksum/config" == base.content
      || throw "the annotation should hold the content hash"
    );

  # Kix fills a SOPS Secret at deploy time, so its content hash follows the
  # SHA-256 of the encrypted file that `kix.run/sops-digest` records.
  content-hash-follows-sops-digest =
    let
      sopsHash =
        file:
        (hashes {
          secretArgs = {
            keys = [ "token" ];
            source = file;
          };
        } "secret").content;
    in
    (
      sopsHash ./content-hash.nix == sopsHash ./content-hash.nix
      || throw "the same file should give the same hash"
    )
    && (
      sopsHash ./content-hash.nix != sopsHash ./secret-sources.nix
      || throw "another file should change the hash"
    );

  # Inline Secret values are part of the content.
  content-hash-follows-secret-data =
    (hashes { secretArgs.stringData.token = "u"; } "secret").content != (hashes { } "secret").content
    || throw "the content hash should change with stringData";
}

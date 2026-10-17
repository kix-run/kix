# Tests for where a Secret's values come from: the `kix.run/secret-sources`
# stamp scope.mkSecret writes (one `key=source` per key), `plainKeys`, and
# the security.secretSource scorecard rule, which reports a key whose source
# `cluster.secrets.accept` does not list and stays silent when the cluster
# sets nothing.

{
  lib,
  kixKeys,
  mkCluster,
  manifests,
  evalFails,
  ...
}:

let
  rules = import ../../rules { inherit lib; };

  # A package that builds one Secret from `args` (merged into mkSecret) in
  # namespace `a`.
  secretPackage = args: {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        secret = scope.mkSecret ({ name = "s"; } // args);
        root = self.secret;
      };
  };

  # A package that names a Secret something else creates.
  refPackage = {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        ref = scope.mkSecretRef {
          name = "ext";
          keys = [ "k" ];
        };
        root = self.ref;
      };
  };

  # A package that builds a Secret with scope.mkResource, so the stamp and
  # the data are whatever `args` says.
  rawSecretPackage = args: {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        secret = scope.mkResource (
          {
            apiVersion = "v1";
            kind = "Secret";
            name = "raw";
          }
          // args
        );
        root = self.secret;
      };
  };

  # A cluster of one instance of `package`, with the security rules on and
  # `accept` as cluster.secrets.accept (null leaves it unset).
  clusterOf =
    package: accept:
    mkCluster [
      {
        scorecard = {
          enable = true;
          rules.security = rules.security;
        };
        cluster.secrets.accept = accept;
        instances.a.inst.package = package;
      }
    ];

  stampOf =
    args:
    let
      secret = lib.findFirst (m: m.kind == "Secret" && m.metadata.name == "s") null (
        manifests (clusterOf (secretPackage args) null)
      );
    in
    secret.metadata.annotations.${kixKeys.secretSources};

  findingsOf =
    package: accept:
    builtins.filter (f: lib.hasSuffix "secretSource" (f.rule or ""))
      ((clusterOf package accept).scorecardReport or { findings = [ ]; }).findings;

  messagesOf = package: accept: map (f: f.message) (findingsOf package accept);

  inlineAndSops = {
    keys = [
      "username"
      "password"
    ];
    stringData.username = "u";
    source = ./secret-sources.nix;
  };
in
{
  # Each key's source: a value in the manifest is inline, a key the SOPS
  # file fills is sops.
  secret-sources-stamp-inline-and-sops =
    stampOf inlineAndSops == "username=inline,password=sops" || throw "stamp: ${stampOf inlineAndSops}";

  # plainKeys marks a valued key as plain; a basic-auth username is plain by
  # type; a plain key with no value is refused.
  secret-sources-stamp-plain-keys =
    let
      declared = stampOf (inlineAndSops // { plainKeys = [ "username" ]; });
      byType = stampOf {
        type = "kubernetes.io/basic-auth";
        stringData = {
          username = "u";
          password = "p";
        };
      };
    in
    (
      declared == "username=plain,password=sops"
      && byType == "password=inline,username=plain"
      && evalFails (clusterOf (secretPackage (inlineAndSops // { plainKeys = [ "password" ]; })) null)
    )
    || throw "plain keys: ${declared} / ${byType}";

  # A Secret a controller fills is stamped for every key.
  secret-sources-stamp-controller =
    stampOf { keys = [ ]; } == "*=controller" || throw "controller stamp: ${stampOf { keys = [ ]; }}";

  # A value under extra.data is stamped like one under stringData.
  secret-sources-stamp-extra-data =
    stampOf { extra.data.cert = "YQ=="; } == "cert=inline"
    || throw "extra.data stamp: ${stampOf { extra.data.cert = "YQ=="; }}";

  # A key with a value that `keys` leaves out is refused, so no value
  # escapes the stamp; `keys = [ ]` beside a value is the same refusal.
  secret-sources-refuses-undeclared-value =
    evalFails (
      clusterOf (secretPackage {
        keys = [ "a" ];
        plainKeys = [ "a" ];
        stringData = {
          a = "x";
          password = "p";
        };
      }) null
    )
    && evalFails (
      clusterOf (secretPackage {
        keys = [ ];
        stringData.password = "p";
      }) null
    )
    || throw "a valued key outside keys was accepted";

  # With cluster.secrets.accept unset, the rule reports nothing.
  secret-sources-rule-silent-when-unset =
    findingsOf (secretPackage { stringData.password = "p"; }) null == [ ]
    || throw "secretSource fired with cluster.secrets.accept unset";

  # An inline key is reported by name when inline is not accepted, and the
  # build fails once the cluster raises the cap to error.
  secret-sources-rule-reports-inline =
    let
      accept = [
        "sops"
        "external"
      ];
      messages = messagesOf (secretPackage inlineAndSops) accept;
      failing = mkCluster [
        {
          scorecard = {
            enable = true;
            maxSeverity = "error";
            rules.security = rules.security;
          };
          cluster.secrets.accept = accept;
          instances.a.inst.package = secretPackage inlineAndSops;
        }
      ];
    in
    (
      builtins.length messages == 1
      && lib.hasInfix "Secret 's': key(s) username is written into the build (inline)" (
        builtins.head messages
      )
      && lib.hasInfix "accepts sops, external" (builtins.head messages)
      && evalFails failing
    )
    || throw "inline finding: ${builtins.toJSON messages}";

  # A plain key beside a SOPS key passes a cluster that forbids inline.
  secret-sources-rule-accepts-plain =
    findingsOf (secretPackage (inlineAndSops // { plainKeys = [ "username" ]; })) [ "sops" ] == [ ]
    || throw "a plain key was reported";

  # An inline key of a Secret classified `configuration` is reported as
  # configuration, and accepted when the cluster lists it.
  secret-sources-rule-configuration =
    let
      configured = secretPackage {
        stringData."app.yaml" = "{}";
        meta.classification = "configuration";
      };
      refused = messagesOf configured [ "sops" ];
      accepted = findingsOf configured [
        "sops"
        "configuration"
      ];
    in
    (
      builtins.length refused == 1
      && lib.hasInfix "configuration the package rendered" (builtins.head refused)
      && accepted == [ ]
    )
    || throw "configuration finding: ${builtins.toJSON refused}";

  # A stamp on a Secret scope.mkSecret did not build cannot hide a value:
  # a key present in stringData is inline whatever the stamp says.
  secret-sources-rule-ignores-stamp-on-valued-key =
    let
      spoofed = rawSecretPackage {
        annotations.${kixKeys.secretSources} = "password=sops";
        extra.stringData.password = "p";
      };
      messages = messagesOf spoofed [ "sops" ];
    in
    (
      builtins.length messages == 1
      && lib.hasInfix "key(s) password is written into the build (inline)" (builtins.head messages)
    )
    || throw "spoofed stamp: ${builtins.toJSON messages}";

  # A chart Secret with `data: null` is scored, not a type error.
  secret-sources-rule-null-data =
    let
      messages = messagesOf (rawSecretPackage {
        extra.data = null;
        extra.stringData.password = "p";
      }) [ "sops" ];
    in
    (builtins.length messages == 1 && lib.hasInfix "key(s) password" (builtins.head messages))
    || throw "null data: ${builtins.toJSON messages}";

  # A Secret something else creates is external: reported only when the
  # cluster leaves external out.
  secret-sources-rule-external =
    let
      refused = messagesOf refPackage [ "sops" ];
    in
    (
      builtins.length refused == 1
      && lib.hasInfix "Secret 'ext' is created outside Kix (external)" (builtins.head refused)
      && findingsOf refPackage [ "external" ] == [ ]
    )
    || throw "external finding: ${builtins.toJSON refused}";
}

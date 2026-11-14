# Tests for the warning a cluster raises when no instance answers the `dns`
# alias (eval/instance.nix, eval/cluster.nix).

{
  lib,
  mkCluster,
  mkCmPackage,
  ...
}:

let
  plain = name: mkCmPackage { inherit name; };
  dns = mkCmPackage {
    name = "dns";
    metaExtra = {
      defaultAliases = [ "dns" ];
      # A DNS provider serves every namespace.
      scope = "cluster";
    };
  };
  dnsWarningsOf =
    cluster: builtins.filter (lib.hasInfix "no DNS instance") cluster.diagnostics.warnings;
in
{
  # A cluster with no DNS instance lists the warning once, however many
  # instances lack DNS, in the file the CLI reads.
  dns-warning-listed-once =
    let
      cluster = mkCluster [
        {
          instances.a.one.package = plain "one";
          instances.b.two.package = plain "two";
        }
      ];
      listed = builtins.fromJSON (builtins.readFile cluster.activationFiles.warnings);
    in
    builtins.length (dnsWarningsOf cluster) == 1
    && builtins.length (builtins.filter (lib.hasInfix "no DNS instance") listed) == 1
    || throw "expected one DNS warning, got ${builtins.toJSON cluster.diagnostics.warnings}";

  # A cluster with a DNS instance raises no such warning.
  dns-warning-absent-with-dns =
    let
      cluster = mkCluster [
        {
          instances.a.one.package = plain "one";
          instances.dns.dns.package = dns;
        }
      ];
    in
    dnsWarningsOf cluster == [ ]
    || throw "unexpected DNS warning: ${builtins.toJSON (dnsWarningsOf cluster)}";
}

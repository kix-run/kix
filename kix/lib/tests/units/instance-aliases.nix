# Tests for an instance's `aliases` (kix/lib/meta.nix effectiveAliases) and
# for the `meta.conflictsWith` check that reads the package's default
# aliases (checkMetaStatic).

{
  mkCluster,
  mkCmPackage,
  manifests,
  hasName,
  evalFails,
  ...
}:

let
  provider = mkCmPackage {
    name = "provider";
    metaExtra.defaultAliases = [ "svc" ];
  };

  consumer = {
    meta.version = "test";
    build =
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
          extra.data.svc = svc._meta.instanceName;
        };
        root = self.cm;
      };
  };

  withProviderAliases =
    aliases:
    mkCluster [
      {
        instances.a.provider = {
          package = provider;
        }
        // aliases;
        instances.a.consumer.package = consumer;
      }
    ];

  singleton = mkCmPackage {
    name = "singleton";
    metaExtra = {
      defaultAliases = [ "single" ];
      conflictsWith = [ "cluster:single" ];
    };
  };
in
{
  # An unset `aliases` keeps the package's default alias, so the consumer
  # binds the provider.
  instance-aliases-unset-keeps-defaults =
    hasName "consumer" (manifests (withProviderAliases { }))
    || throw "a provider with unset aliases did not answer its default alias";

  # `aliases = [ ]` replaces the defaults, so the provider answers no alias
  # and the consumer's required `svc` finds nothing.
  instance-aliases-empty-list-drops-defaults =
    evalFails (withProviderAliases {
      aliases = [ ];
    })
    || throw "a provider with aliases = [ ] still answered its default alias";

  # Two instances of a package that declares `conflictsWith` on its own
  # default alias fail even when both replace that alias.
  instance-aliases-conflicts-with-survives-own-aliases =
    let
      pair =
        first: second:
        mkCluster [
          {
            instances.a.one = {
              package = singleton;
            }
            // first;
            instances.b.two = {
              package = singleton;
            }
            // second;
          }
        ];
    in
    (
      evalFails (pair { } { })
      && evalFails (pair { aliases = [ "first" ]; } { aliases = [ "second" ]; })
      && evalFails (pair { aliases = [ ]; } { aliases = [ ]; })
      && !(evalFails (mkCluster [
        {
          instances.a.one = {
            package = singleton;
            aliases = [ "first" ];
          };
        }
      ]))
    )
    || throw "two instances of a singleton package with their own aliases evaluated, or one alone failed";
}

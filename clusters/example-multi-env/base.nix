# clusters/example-multi-env/base.nix: shared package configuration for all environments.
#
# This module defines the service catalog and common settings. Environment-specific
# cluster definitions (dev.nix, prod.nix) import this and override what differs.
#
# Pattern: packages are defined once, config varies per environment.

{
  lib,
  packages,
  kix,
  ...
}:

{
  # Packages available for auto-instantiation across all environments.
  availablePackages = packages;

  # Common labels applied to every resource in every environment.
  clusterLabels = {
    "app.kubernetes.io/part-of" = "my-project";
  };

  # Service definitions shared across dev and prod.

  instances.app = {
    # The main application: the same package, with config that varies per env.
    # A placeholder: use your app package.
    my-app = {
      package = packages.echo-server;
    };
  };

  instances.infra = {
    cert-manager = {
      package = packages.experimental.cert-manager;
    };
  };

  instances.cache = {
    valkey = {
      package = packages.valkey;
    };
    # Development only; outside it, a SOPS `source` with
    # keys = [ "password" ], or a secret-ref.
    valkey-password = {
      package = packages.secret;
      aliases = [ "valkeyPassword" ];
      config.stringData.password = "development-only-password";
    };
  };
}

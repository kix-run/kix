# The first arc-runner-set setting that is refused, as a message without the
# instance prefix, or null. The package throws it before calling arc's
# builder, so the message names this package's options rather than the
# runner set spec. extraSpec paths that an option sets are refused later by
# kix.mergeGuarded.
{ lib, name }:
config:
let
  githubConfigUrl = import ../arc/github-config-url.nix;
  extra = config.extraSpec;

  # extraSpec paths set from a dependency or from `rules`, with the fix.
  derived = [
    {
      path = [ "githubConfigSecret" ];
      fix = "It is the Secret of deps.githubConfigSecret; wire another secret with deps.githubConfigSecret = ref.<ns>.<instance>.";
    }
    {
      path = [
        "template"
        "spec"
        "serviceAccountName"
      ];
      fix = "The runner pods use the ServiceAccount ${name}-runner, which arc creates; give it permissions with `rules`.";
    }
    {
      path = [
        "template"
        "spec"
        "automountServiceAccountToken"
      ];
      fix = "The token is mounted when `rules` is set and not otherwise; set `rules` to give the runner pods API access.";
    }
    {
      path = [
        "template"
        "spec"
        "priorityClassName"
      ];
      fix = "It is the PriorityClass of deps.priorityClass; wire a priority-class instance there.";
    }
  ];
  derivedHit = lib.findFirst (d: lib.hasAttrByPath d.path extra) null derived;

  containers = lib.attrByPath [ "template" "spec" "containers" ] [ ] extra;
  unnamed = builtins.filter (c: !(builtins.isAttrs c) || !(c ? name)) containers;
  runnerOverride = lib.findFirst (c: c.name == "runner") { } containers;
  # Fields of the `runner` container that options own.
  ownedHits = builtins.filter (f: runnerOverride ? ${f}) [
    "image"
    "env"
    "resources"
  ];
  quoted = lib.concatMapStringsSep " and " (f: "`${f}`");
in
if config.minRunners > config.maxRunners then
  "minRunners (${toString config.minRunners}) is greater than maxRunners (${toString config.maxRunners}). Lower minRunners or raise maxRunners."
else if githubConfigUrl.problem config.githubConfigUrl != null then
  "githubConfigUrl ${githubConfigUrl.problem config.githubConfigUrl}"
else if derivedHit != null then
  "extraSpec sets ${lib.concatStringsSep "." derivedHit.path}. ${derivedHit.fix}"
else if !(builtins.isList containers) then
  "extraSpec.template.spec.containers must be a list of containers."
else if unnamed != [ ] then
  "extraSpec.template.spec.containers has an entry without a name. Entries are matched by name; name each one."
else if ownedHits != [ ] then
  "extraSpec.template.spec.containers.runner sets ${quoted ownedHits}, which the ${quoted ownedHits} ${
    if builtins.length ownedHits == 1 then "option sets; use the option" else "options set; use the options"
  }."
else
  null

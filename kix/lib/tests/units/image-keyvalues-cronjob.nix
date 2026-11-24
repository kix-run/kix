# Tests for both forms of kix.options.image, kix.keyValues, and the CronJob
# name limit. The workloads come from a minimal package defined below.

{
  lib,
  kixlib,
  kixKeys,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  ...
}:

let
  # The value of an `image` option built by `kix.options.image args`, with
  # `defs` as the instance's definitions.
  imageWith =
    args: defs:
    (lib.evalModules {
      modules = [
        { options.image = kixlib.options.image args; }
      ]
      ++ map (d: { image = d; }) defs;
    }).config.image;

  fieldsOf = img: {
    inherit (img)
      repository
      tag
      digest
      pullPolicy
      ;
  };

  succeeds = v: (builtins.tryEval (builtins.deepSeq v true)).success;

  digest = "sha256:${lib.fixedWidthString 64 "0" ""}";

  # One workload of `kind` named `name`, built through the scope builder.
  workloadPackage =
    kind: name:
    { ... }:
    {
      meta.version = "test";
      build =
        { self, scope, ... }:
        let
          podTemplate = {
            metadata.labels = scope.selectorLabels;
            spec = {
              restartPolicy = "Never";
              containers = [
                {
                  name = "task";
                  image = "task:1";
                }
              ];
            };
          };
        in
        {
          workload =
            if kind == "Job" then
              scope.mkJob {
                inherit name;
                spec.template = podTemplate;
              }
            else
              scope.mkCronJob {
                inherit name;
                spec = {
                  schedule = "0 * * * *";
                  jobTemplate.spec.template = podTemplate;
                };
              };
          root = self.workload;
        };
    };

  clusterWith = kind: name: mkCluster [ { instances.app.task.package = workloadPackage kind name; } ];
in
{
  # With repository and tag the option keeps its default, and the package's
  # digest is dropped when an instance changes the tag.
  image-keyvalues-cronjob-image-default-form =
    let
      args = {
        repository = "docker.io/library/nginx";
        tag = "1.27";
        inherit digest;
      };
      declared = fieldsOf (imageWith args [ ]);
      retagged = fieldsOf (imageWith args [ { tag = "1.28"; } ]);
    in
    (
      declared == {
        repository = "docker.io/library/nginx";
        tag = "1.27";
        inherit digest;
        pullPolicy = "IfNotPresent";
      }
      &&
        retagged == {
          repository = "docker.io/library/nginx";
          tag = "1.28";
          digest = null;
          pullPolicy = "IfNotPresent";
        }
    )
    || throw "kix.options.image default form: declared ${builtins.toJSON declared}, retagged ${builtins.toJSON retagged}";

  # Without repository and tag the option's default is { } and neither
  # field has one: an instance that sets nothing, or only the repository,
  # fails; one that sets both gets them. With only repository declared, an
  # instance supplies the tag. A digest without a tag is refused.
  image-keyvalues-cronjob-image-required-form =
    let
      required = imageWith { };
      given = fieldsOf (required [
        {
          repository = "ghcr.io/example/app";
          tag = "1.0.0";
        }
      ]);
      partial = fieldsOf (imageWith { repository = "ghcr.io/example/app"; } [ { tag = "2.0.0"; } ]);
      optionDefault = (kixlib.options.image { }).default;
    in
    (
      !(succeeds (fieldsOf (required [ ])))
      && !(succeeds (fieldsOf (required [ { repository = "ghcr.io/example/app"; } ])))
      && optionDefault == { }
      &&
        given == {
          repository = "ghcr.io/example/app";
          tag = "1.0.0";
          digest = null;
          pullPolicy = "IfNotPresent";
        }
      && partial.tag == "2.0.0"
      && partial.repository == "ghcr.io/example/app"
      && !(succeeds (kixlib.options.image { inherit digest; }))
    )
    || throw "kix.options.image required form: given ${builtins.toJSON given}, partial ${builtins.toJSON partial}, option default ${builtins.toJSON optionDefault}";

  # kix.keyValues names the rerun value that scope.mkJob writes, and the
  # cross-resource check for kix.run/rerun accepts it.
  image-keyvalues-cronjob-keyvalues-rerun =
    let
      cluster = clusterWith "Job" "migrate";
      job = byName "migrate" (ofKind "Job" (manifests cluster));
    in
    (
      kixlib.keyValues.rerunOnChange == "on-change"
      && !(evalFails cluster)
      && job.metadata.annotations.${kixKeys.rerun} or null == "on-change"
    )
    || throw "kix.keyValues rerun: Job annotations ${
      builtins.toJSON (job.metadata.annotations or null)
    }";

  # A CronJob name may be 52 characters, not 53: the CronJob controller
  # appends an 11-character suffix to the Jobs it creates.
  image-keyvalues-cronjob-cronjob-name-max-52 =
    let
      nameOf = n: lib.fixedWidthString n "a" "";
    in
    (!(evalFails (clusterWith "CronJob" (nameOf 52))) && evalFails (clusterWith "CronJob" (nameOf 53)))
    || throw "CronJob name limit: 52 ${
      if evalFails (clusterWith "CronJob" (nameOf 52)) then "fails" else "passes"
    }, 53 ${if evalFails (clusterWith "CronJob" (nameOf 53)) then "fails" else "passes"}";

  # Container security rules in `kix/lib/rules/security.nix` inspect a CronJob's
  # pod spec (`spec.jobTemplate.spec.template.spec`), catching violations and
  # passing a compliant CronJob.
  image-keyvalues-cronjob-security-rules =
    let
      securityRules = import ../../rules/security.nix { inherit lib; };
      cronJob = podSpec: {
        apiVersion = "batch/v1";
        kind = "CronJob";
        metadata.name = "backup";
        spec = {
          schedule = "0 * * * *";
          jobTemplate.spec.template.spec = podSpec;
        };
      };
      findingsFor =
        rule: resource:
        if rule.appliesTo { inherit resource; } then rule.check { inherit resource; } else [ ];
      bad = cronJob {
        hostNetwork = true;
        containers = [
          {
            name = "task";
            image = "example/task:latest";
            securityContext.privileged = true;
          }
        ];
        initContainers = [
          {
            name = "init";
            image = "example/init:REPLACE_ME";
          }
        ];
      };
      good = cronJob {
        securityContext.runAsNonRoot = true;
        containers = [
          {
            name = "task";
            image = "example/task:1.0.0";
            securityContext.readOnlyRootFilesystem = true;
          }
        ];
      };
      checkedRules = [
        securityRules.nonRoot
        securityRules.noPrivileged
        securityRules.readOnlyRootfs
        securityRules.noHostNetwork
        securityRules.noLatestTag
        securityRules.noUnresolvedPlaceholder
      ];
    in
    (
      builtins.all (rule: findingsFor rule bad != [ ]) checkedRules
      && builtins.all (rule: findingsFor rule good == [ ]) checkedRules
    )
    || throw "CronJob security rules: bad=${
      builtins.toJSON (map (r: findingsFor r bad) checkedRules)
    } good=${builtins.toJSON (map (r: findingsFor r good) checkedRules)}";
}

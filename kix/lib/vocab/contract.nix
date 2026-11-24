# Build provider/consumer contract validators for `kix.contracts.*`.
{ lib }:

let
  inherit (import ../core/error.nix { inherit lib; }) refuseWho;
in
{
  # Build the field for a login a contract carries in `out.credentials`: a
  # Secret, or a secret instance, whose `out.keyRef` reads each of `keys`.
  # A provider Kix runs publishes its own Secret. A `kix.mkImport` names one
  # with `credentials = ref.<namespace>.<instance>`. The Secret must be in
  # the consumer's namespace, which the workload builder checks.
  credentialsField =
    {
      keys,
      required ? true,
    }:
    {
      inherit required keys;
      shape = "a secret (out.keyRef) with the keys ${lib.concatStringsSep " and " keys}, such as ref.<namespace>.<instance> naming a secret or secret-ref instance in the consumer's namespace";
      test =
        v:
        let
          out = if builtins.isAttrs v then v.out or { } else { };
          declared = out.keys or null;
        in
        builtins.isFunction (out.keyRef or null)
        && (!builtins.isList declared || lib.all (k: builtins.elem k declared) keys);
    };

  # Build a contract from a field table. Every contract has these parts and
  # no others.
  #
  # - `name`, `alias`, `fields`: as given. `alias` is the dependency name a
  #   consumer takes the contract under. A field without `required` is
  #   required. `path` is where a package reaches the contract under `kix`,
  #   such as `contracts.redis`, for the errors that name a function of it.
  # - `check scope out`: validate that a provider's `root.out` defines every
  #   field in `fields` with the expected shape, and return `out`. The error
  #   names the provider instance in `scope`.
  # - `problems out`: return the list of missing or malformed field messages
  #   for a consumer (requiring only fields with `required = true`, plus shape
  #   checks on optional fields when present).
  # - `assertions dep`: build the assertion list for a consumer dependency
  #   `dep`, for the consumer's `deps.<name>.assertions`. Kix sets the
  #   instance, its package, and the dependency on each assertion.
  # - `requireAs dependency scope dep`: validate `dep`, which the consumer in
  #   `scope` takes as dependency `dependency`, eagerly and return `dep`, or
  #   fail.
  # - `require scope dep`: `requireAs` for a dependency named `alias`.
  # - `helpers`: the functions and values this contract gives its consumers.
  # - `options`: the option set, or the function that builds one, that a
  #   consumer adds to its own options. Null when the contract has none.
  mkContract =
    {
      name,
      alias,
      path,
      here,
      fields,
      remedyNoun ? alias,
      extraProblems ? (_: [ ]),
      helpers ? { },
      options ? null,
    }:
    let
      problemsWith =
        all: out:
        builtins.concatMap (
          field:
          let
            f = fields.${field};
          in
          if !(out ? ${field}) then
            lib.optional (all || f.required or true) "${field} is missing (${f.shape})"
          else if !(f.test out.${field}) then
            [ "${field} is not ${f.shape}" ]
          else
            [ ]
        ) (builtins.attrNames fields)
        ++ extraProblems out;

      providerOf =
        dep:
        let
          meta = dep._meta or { };
        in
        if meta ? namespaceName && meta ? instanceName then
          "${meta.namespaceName}/${meta.instanceName}"
        else
          "the instance it resolved to";

      # Return `k` applied to the `fail` of `scope`. Refuse a string in place
      # of `scope`, the `who` of the removed form, and name the form to use.
      withFail =
        helper: scope: k:
        if builtins.isString scope then
          refuseWho {
            helper = "${path}.${helper}";
            fix = "Pass `scope` instead of `who`.";
          }
        else
          k scope.fail;

      # Return the error, as `kix.fail` takes it, for a consumer whose
      # dependency `dep` breaks the contract. A consumer may take the
      # contract under any dependency name, so the text names the provider
      # and leaves the dependency to the record's `dependency` field, which
      # `deps.<name>.assertions` and `requireAs` set.
      consumerError = dep: found: {
        message = "`out` from ${providerOf dep} does not satisfy the ${name} contract (${here}): ${lib.concatStringsSep "; " found}.";
        fix = "For a kix.mkImport provider, set the fields listed above in its `out = { ... };`. Otherwise, point this instance at a different ${remedyNoun} with `deps.<name> = ref.<namespace>.<instance>;`, or fix `root.out` in the provider package.";
      };

      # Validate a consumer dependency `dep` eagerly and return `dep`, or fail.
      # The error names `dep` as dependency `dependency`. `helper` names the
      # function a refusal of `who` names.
      requireNamed =
        helper: dependency: scope: dep:
        let
          found = problemsWith false (dep.out or { });
        in
        withFail helper scope (
          fail: if found == [ ] then dep else fail ({ inherit dependency; } // consumerError dep found)
        );
    in
    {
      inherit
        name
        alias
        fields
        helpers
        options
        ;

      requireAs = requireNamed "requireAs";

      # Return the contract problems a consumer reports for `out`.
      problems = problemsWith false;

      # Validate that a provider's `root.out` satisfies every contract field,
      # and return `out`.
      check =
        scope: out:
        let
          found = problemsWith true out;
        in
        withFail "check" scope (
          fail:
          if found == [ ] then
            out
          else
            fail {
              message = "`root.out` does not satisfy the ${name} contract (${here}): ${lib.concatStringsSep "; " found}.";
              fix = "If one of those fields comes from an option on this instance, fix that option in your cluster definition; otherwise fix `root.out` in the package.";
            }
        );

      # Build dependency assertions for a consumer of `dep`. Refuse a string
      # in its place, the `who` of the removed form, and name the form to
      # use.
      assertions =
        dep:
        let
          found = problemsWith false (dep.out or { });
        in
        if builtins.isString dep then
          refuseWho {
            helper = "${path}.assertions";
            reason = "Kix adds the instance and package to each assertion automatically.";
            fix = "Pass only the dependency, such as `deps.<name>.assertions = kix.${path}.assertions;` (or `dep: kix.${path}.assertions dep ++ ...`).";
          }
        else
          lib.optional (found != [ ]) ({ assertion = false; } // consumerError dep found);

      # Like `requireAs`, for a consumer that takes the contract under its
      # alias.
      require = requireNamed "require" alias;
    };
}

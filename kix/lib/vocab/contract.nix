# Build provider/consumer contract validators for `kix.contracts.*`.
{ lib }:

let
  inherit (import ../core/error.nix { inherit lib; }) fail;
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
  #   required.
  # - `check who out`: validate that a provider's `root.out` defines every
  #   field in `fields` with the expected shape, and return `out`.
  # - `problems out`: return the list of missing or malformed field messages
  #   for a consumer (requiring only fields with `required = true`, plus shape
  #   checks on optional fields when present).
  # - `assertions who dep`: build the module assertion list for a consumer
  #   dependency `dep`.
  # - `require who dep`: validate `dep` eagerly and return `dep`, or fail.
  # - `helpers`: the functions and values this contract gives its consumers.
  # - `options`: the option set, or the function that builds one, that a
  #   consumer adds to its own options. Null when the contract has none.
  mkContract =
    {
      name,
      alias,
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

      # Return the error, as `kix.fail` takes it, for a consumer whose
      # dependency `dep` breaks the contract.
      consumerError = who: dep: found: {
        message = "${who}: deps.${alias} resolved to ${providerOf dep}, whose out does not honour the ${name} contract (${here}): ${lib.concatStringsSep "; " found}.";
        fix = "set them on that instance's out (a kix.mkImport sets them in `out`), or wire another ${remedyNoun} with deps.${alias} = ref.<ns>.<instance>.";
      };
    in
    {
      inherit
        name
        alias
        fields
        helpers
        options
        ;

      # Return the contract problems a consumer reports for `out`.
      problems = problemsWith false;

      # Validate that a provider's `root.out` satisfies every contract field,
      # and return `out`.
      check =
        who: out:
        let
          found = problemsWith true out;
        in
        if found == [ ] then
          out
        else
          fail {
            message = "${who}: root.out does not honour the ${name} contract (${here}): ${lib.concatStringsSep "; " found}.";
            fix = "Correct the fields named above where the package sets `out` on its `root`. If the package reads one from a setting of the instance, change that setting.";
          };

      # Build dependency assertions for a consumer of `dep`.
      assertions =
        who: dep:
        let
          found = problemsWith false (dep.out or { });
        in
        lib.optional (found != [ ]) ({ assertion = false; } // consumerError who dep found);

      # Validate a consumer dependency `dep` eagerly and return `dep`, or fail.
      require =
        who: dep:
        let
          found = problemsWith false (dep.out or { });
        in
        if found == [ ] then dep else fail (consumerError who dep found);
    };
}

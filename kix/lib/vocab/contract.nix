# Build provider/consumer contract validators for `kix.contracts.*`.
{ lib }:

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
      inherit required;
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

  # Build a contract checker from a field table.
  #
  # - `check who out`: validate that a provider's `root.out` defines every
  #   field in `fields` with the expected shape, and return `out`.
  # - `problems out`: return the list of missing or malformed field messages
  #   for a consumer (requiring only fields with `required = true`, plus shape
  #   checks on optional fields when present).
  # - `assertions who dep`: build the module assertion list for a consumer
  #   dependency `dep`.
  # - `require who dep`: validate `dep` eagerly and return `dep`, or throw.
  mkContract =
    {
      name,
      alias,
      here,
      fields,
      remedyNoun ? alias,
      extraProblems ? (_: [ ]),
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
            lib.optional (all || f.required) "${field} is missing (${f.shape})"
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

      consumerMessage =
        who: dep: found:
        "${who}: deps.${alias} resolved to ${providerOf dep}, whose out does not honour the ${name} contract: ${lib.concatStringsSep "; " found}. Set them on that instance's out (a kix.mkImport sets them in `out`), or wire another ${remedyNoun} with deps.${alias} = ref.<ns>.<instance> (${here}).";
    in
    {
      inherit alias fields;

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
          throw "${who}: root.out does not honour the ${name} contract: ${lib.concatStringsSep "; " found} (${here})";

      # Build dependency assertions for a consumer of `dep`.
      assertions =
        who: dep:
        let
          found = problemsWith false (dep.out or { });
        in
        lib.optional (found != [ ]) {
          assertion = false;
          message = consumerMessage who dep found;
        };

      # Validate a consumer dependency `dep` eagerly and return `dep`, or throw.
      require =
        who: dep:
        let
          found = problemsWith false (dep.out or { });
        in
        if found == [ ] then dep else throw (consumerMessage who dep found);
    };
}

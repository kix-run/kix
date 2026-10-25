# The refusals of volsync's out.mkReplicationSource, as a pure function, so
# kix/lib/tests/units/volsync.nix can check each message.

{ lib }:
rec {
  # VolSync names a mover Job volsync-<src|dst>-<resource name> and hashes
  # the resource name when the result exceeds 63 characters
  # (internal/controller/utils/utils.go).
  maxNameLength = 51;

  # The keys the restic mover reads from the repository Secret by name
  # (internal/controller/mover/restic/mover.go).
  resticKeys = [
    "RESTIC_REPOSITORY"
    "RESTIC_PASSWORD"
    "AWS_ACCESS_KEY_ID"
    "AWS_SECRET_ACCESS_KEY"
  ];

  # trigger.schedule, as the CRD's pattern and the operator's cron parser
  # (robfig/cron with five fields and descriptors) accept it.
  cronField = "(([0-9]+,)*[0-9]+|[0-9]+[/-][0-9]+|\\*(/[0-9]+)?)";
  scheduleOk =
    s:
    builtins.match "@(annually|yearly|monthly|weekly|daily|hourly)" s != null
    || builtins.match "${cronField}( ${cronField}){4}" s != null;

  # The first problem with mkReplicationSource's arguments, or null.
  replicationSourceProblem =
    {
      name,
      schedule,
      copyMethod,
      restic,
      extraSpec ? { },
    }:
    let
      unknownRestic = builtins.attrNames (
        removeAttrs restic [
          "repository"
          "endpointService"
          "storePort"
        ]
      );
      endpointService = restic.endpointService or null;
      storePort = restic.storePort or null;
      repository = restic.repository or null;
      declared = repository.out.keys or [ ];
      missing = builtins.filter (k: !(builtins.elem k declared)) resticKeys;
      otherMovers = builtins.filter (m: extraSpec ? ${m}) [
        "rclone"
        "rsync"
        "rsyncTLS"
        "syncthing"
        "external"
      ];
    in
    if builtins.match "[a-z0-9]([-a-z0-9]*[a-z0-9])?" name == null then
      "the name is not a DNS-1123 label. Use lower-case letters, digits, and hyphens."
    else if builtins.stringLength name > maxNameLength then
      "the name is longer than ${toString maxNameLength} characters, so VolSync hashes its mover Job's name and Kix cannot select the mover pods for network policy. Shorten it."
    else if !(scheduleOk schedule) then
      "schedule \"${schedule}\" is not five cron fields (minute hour day-of-month month day-of-week) or one of @hourly, @daily, @weekly, @monthly, @yearly, @annually."
    else if
      !(builtins.elem copyMethod [
        "Direct"
        "Clone"
        "Snapshot"
      ])
    then
      "copyMethod \"${toString copyMethod}\" is not Direct, Clone, or Snapshot."
    else if unknownRestic != [ ] then
      "restic sets ${lib.concatStringsSep ", " unknownRestic}, which the builder does not know. It takes repository, endpointService, and storePort; put other restic fields in extraSpec.restic."
    else if repository == null then
      "restic.repository is required: a secret dependency with the keys ${lib.concatStringsSep ", " resticKeys}."
    else if missing != [ ] then
      "restic.repository is secret \"${repository.out.name}\", which declares ${
        if declared == [ ] then "no keys" else lib.concatStringsSep ", " declared
      }; the restic mover reads ${lib.concatStringsSep ", " missing} from it. Add them to that secret's keys."
    else if endpointService != null && storePort != null then
      "restic sets both endpointService and storePort. storePort is the port of a store outside the cluster; remove it."
    else if endpointService != null && !(endpointService.out ? fqdn) then
      "restic.endpointService has no out.fqdn. Pass an instance whose root is its S3 Service."
    else if
      storePort != null && !(builtins.isInt storePort && storePort >= 1 && storePort <= 65535)
    then
      "restic.storePort ${builtins.toJSON storePort} is not a port number."
    else if otherMovers != [ ] then
      "extraSpec sets ${lib.concatStringsSep ", " otherMovers}, and this builder configures a restic mover. Build other movers with scope.mkCR volsync.out.crds.ReplicationSource."
    else
      null;
}

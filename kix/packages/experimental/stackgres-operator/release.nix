# The StackGres release this package targets, and the operand image table
# that release ships.
#
# versions.properties is upstream's
# stackgres-k8s/src/common/src/main/resources/versions-1.19.properties at the
# tag `release`, copied unchanged. Each entry is `<version>-build-<build>`.
# The operator picks operand images from this table, never from the cluster
# file, so Kix reads the same table to name those images and to check
# `postgres.version` before the operator sees it. The rules below follow
# StackGres's Component.java and Components.java (ComponentsV119):
#   - a major ("17") means its newest minor in the table;
#   - Patroni is the newest Patroni entry whose build equals the PostgreSQL
#     entry's build, and its image tag is v<patroni>-pg<minor>-build-<build>;
#   - postgres-util is tagged v<minor>-build-<build>;
#   - the exporter and pgbouncer are their newest entries;
#   - cluster-controller is tagged with the operator image tag;
#   - kubectl is the newest entry within one minor of the API server's,
#     else the newest entry (KubectlUtil.java).
{ lib }:

let
  inherit (import ../../../lib/core/error.nix { inherit lib; }) fail;
  release = "1.19.5";

  text = builtins.readFile ./versions.properties;
  # A trailing backslash continues the value on the next line.
  lines = builtins.filter (l: l != "" && !(lib.hasPrefix "#" l)) (
    map lib.trim (lib.splitString "\n" (builtins.replaceStrings [ "\\\n" ] [ "" ] text))
  );
  table = builtins.listToAttrs (
    map (
      line:
      let
        m = builtins.match "([^=]+)=(.*)" line;
      in
      {
        name = lib.trim (builtins.elemAt m 0);
        value = builtins.filter (e: e != "") (map lib.trim (lib.splitString "," (builtins.elemAt m 1)));
      }
    ) lines
  );

  parseEntry =
    entry:
    let
      m = builtins.match "([0-9][0-9.]*)-build-([0-9.]+)" entry;
    in
    if m == null then
      fail {
        message = "kix/packages/experimental/stackgres-operator/versions.properties: \"${entry}\" is not <version>-build-<build>.";
      }
    else
      {
        version = builtins.elemAt m 0;
        build = builtins.elemAt m 1;
        major = builtins.head (lib.splitString "." (builtins.elemAt m 0));
      };

  entries = key: map parseEntry table.${key};

  # Newest first: by version, then by build.
  newer =
    a: b:
    let
      c = builtins.compareVersions a.version b.version;
    in
    if c != 0 then c > 0 else builtins.compareVersions a.build b.build > 0;
  newest = list: builtins.head (lib.sort newer list);

  postgresql = entries "postgresql";

  # PostgreSQL minors the table lists whose images quay.io does not publish.
  # 12.22-build-6.44 joins to Patroni build 6.44, and there is no
  # ongres/patroni tag v4.1.0-pg12.22-build-6.44. The operator would create
  # pods that cannot pull.
  unpublished = [ "12.22" ];

  minorOf =
    version:
    let
      m = builtins.match "[vV]?[0-9]+[.]([0-9]+).*" version;
    in
    if m == null then null else lib.toInt (builtins.head m);
in
{
  inherit release;

  # The kubectl images the backup and major-upgrade Jobs may run, from
  # `registry`. With `k8sVersion` (the cluster's, such as "1.34") the one the
  # operator picks; without it every candidate, since the operator picks by
  # the live API server's minor.
  kubectlImages =
    { registry, k8sVersion }:
    let
      all = lib.sort newer (entries "kubectl");
      serverMinor = if k8sVersion == null then null else minorOf k8sVersion;
      near = builtins.filter (
        e:
        let
          minor = minorOf e.version;
        in
        serverMinor >= minor - 1 && serverMinor <= minor + 1
      ) all;
      picked = if near != [ ] then builtins.head near else builtins.head all;
      image = e: "${registry}/ongres/kubectl:v${e.version}-build-${e.build}";
    in
    if serverMinor == null then map image all else [ (image picked) ];

  # The images StackGres runs for an SGCluster at `version` ("17" or
  # "17.11"), from `registry` (the operator's registry prefix) and
  # `operatorTag`. Reports through `fail`, the calling instance's
  # `scope.fail`, when the table has no such release.
  resolvePostgres =
    {
      fail,
      version,
      registry,
      operatorTag,
    }:
    let
      majors = lib.naturalSort (lib.unique (map (e: e.major) postgresql));
      isMajor = builtins.match "[0-9]+" version != null;
      askedMajor = builtins.head (lib.splitString "." version);
      matching = builtins.filter (
        e: if isMajor then e.major == version else e.version == version
      ) postgresql;
      pg = newest matching;
      minorsOf =
        major:
        lib.concatStringsSep ", " (
          map (e: e.version) (
            builtins.filter (e: e.major == major && !(builtins.elem e.version unpublished)) postgresql
          )
        );
      patroni = newest (builtins.filter (e: e.build == pg.build) (entries "patroni"));
      exporter = newest (entries "prometheus-postgres-exporter");
      pgbouncer = newest (entries "pgbouncer");
    in
    if version == "latest" then
      fail {
        option = "postgres.version";
        message = "postgres.version cannot be \"latest\". Upgrading the StackGres operator could switch the database to a new major PostgreSQL version, which requires an SGDbOps resource of type `majorVersionUpgrade`.";
        fix = "Pin a major such as \"17\".";
      }
    else if matching == [ ] then
      fail {
        option = "postgres.version";
        message = "postgres.version \"${version}\" is not supported by StackGres ${release}.";
        fix =
          if builtins.elem askedMajor majors then
            "PostgreSQL ${askedMajor} minors it ships: ${minorsOf askedMajor}."
          else
            "Use a major (${lib.concatStringsSep ", " majors}) or one of its minors.";
      }
    else if builtins.elem pg.version unpublished then
      fail {
        option = "postgres.version";
        message = "postgres.version \"${version}\" selects PostgreSQL ${pg.version} (build ${pg.build}), which has no published StackGres container images on quay.io, so the pods cannot start.";
        fix = "Pin another minor: ${minorsOf pg.major}.";
      }
    else
      {
        inherit (pg) major;
        minor = pg.version;
        images = {
          patroni = "${registry}/ongres/patroni:v${patroni.version}-pg${pg.version}-build-${pg.build}";
          postgresUtil = "${registry}/ongres/postgres-util:v${pg.version}-build-${pg.build}";
          prometheusPostgresExporter = "${registry}/ongres/prometheus-postgres-exporter:v${exporter.version}-build-${exporter.build}";
          pgbouncer = "${registry}/ongres/pgbouncer:v${pgbouncer.version}-build-${pgbouncer.build}";
          clusterController = "${registry}/stackgres/cluster-controller:${operatorTag}";
        };
      };
}

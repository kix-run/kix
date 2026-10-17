"""Make Plausible's ClickHouse schema replicated on every replica.

Plausible's migrations create plain MergeTree tables on a fresh install and
switch to ReplicatedMergeTree with ON CLUSTER only once the tables they
check are already replicated (Plausible.IngestRepo.clustered_table?). The
migrations run against one replica, CLICKHOUSE_URL, and this script then:

  1. replaces each table of the database that is not replicated with a
     Replicated* table of the same definition on that replica, moving its
     parts across with ATTACH PARTITION FROM (hard links, no copy), and
     swapping the two with EXCHANGE TABLES;
  2. creates every replicated table, dictionary, and SQL function of that
     replica on the rest of the cluster with ON CLUSTER '{cluster}' and IF
     NOT EXISTS, so the other replicas fetch the parts from it.

It runs as an init container, so Plausible is not running (the Deployment
uses Recreate) and nothing writes to a table while it is swapped. Every
step is safe to repeat, and a run finds nothing to do once every table is
on every replica. Environment:

  CLICKHOUSE_URL       http://host:port/database, one replica
  CLICKHOUSE_USER      the user, which Plausible's dictionaries log in as
  CLICKHOUSE_PASSWORD  its password
  REPLICAS             how many replicas the server has
"""

import os
import re
import sys
import urllib.parse
import urllib.request

URL = urllib.parse.urlsplit(os.environ["CLICKHOUSE_URL"])
DATABASE = URL.path.strip("/")
USER = os.environ["CLICKHOUSE_USER"]
PASSWORD = os.environ["CLICKHOUSE_PASSWORD"]
REPLICAS = int(os.environ["REPLICAS"])
ON_CLUSTER = "ON CLUSTER '{cluster}'"
# Where Plausible's own replicated tables keep their Keeper path
# (priv/data_migrations/NumericIDs/sql/create-events-v2.sql.eex).
ZK_PATH = "/clickhouse/{cluster}/tables/{shard}/{database}/%s"
SUFFIX = "__kix_replicated"


def query(sql, fmt=None, **settings):
    body = sql + (f" FORMAT {fmt}" if fmt else "")
    params = urllib.parse.urlencode({"database": DATABASE, **settings})
    request = urllib.request.Request(
        f"http://{URL.hostname}:{URL.port or 8123}/?{params}",
        data=body.encode(),
        headers={"X-ClickHouse-User": USER, "X-ClickHouse-Key": PASSWORD},
    )
    try:
        with urllib.request.urlopen(request, timeout=300) as response:
            return response.read().decode()
    except urllib.error.HTTPError as e:
        sys.exit(f"replicate: {e.read().decode().strip()}\nin: {sql}")


def rows(sql, **settings):
    out = query(sql, "TSVRaw", **settings)
    return [line.split("\t") for line in out.splitlines() if line]


def quote(name):
    return "`" + name.replace("`", "``") + "`"


def literal(text):
    return "'" + text.replace("\\", "\\\\").replace("'", "\\'") + "'"


def replicated_ddl(create, table, new_name):
    """The CREATE TABLE text `create` with a Replicated* engine, named `new_name`."""
    head = re.match(r"CREATE TABLE \S+", create)
    if not head:
        sys.exit(f"replicate: cannot parse the definition of {table}: {create}")
    prefix = f"CREATE TABLE {quote(DATABASE)}.{quote(new_name)}"
    rest = create[head.end():]
    path = literal(ZK_PATH % table) + ", '{replica}'"
    engine = re.search(r"ENGINE = (\w*MergeTree)(\(([^)]*)\))?", rest)
    if engine:
        args = engine.group(3)
        new_engine = f"ENGINE = Replicated{engine.group(1)}({path}{', ' + args if args else ''})"
        return prefix + rest[: engine.start()] + new_engine + rest[engine.end():]
    # Ecto's schema_migrations is a TinyLog table: no ORDER BY to keep.
    if re.search(r"ENGINE = TinyLog\s*$", rest):
        return prefix + re.sub(r"ENGINE = TinyLog\s*$", f"ENGINE = ReplicatedMergeTree({path}) ORDER BY tuple()", rest)
    sys.exit(f"replicate: {table} has an engine this script does not convert: {create}")


def convert(table, engine, create):
    staged = table + SUFFIX
    # A run interrupted before the swap leaves a staging table with some of
    # the parts; ATTACH PARTITION FROM would duplicate them, so start over.
    query(f"DROP TABLE IF EXISTS {quote(staged)} SYNC")
    query(replicated_ddl(create, table, staged))
    if engine.endswith("MergeTree"):
        for (partition,) in rows(
            f"SELECT DISTINCT partition_id FROM system.parts "
            f"WHERE database = {literal(DATABASE)} AND table = {literal(table)} AND active"
        ):
            query(f"ALTER TABLE {quote(staged)} ATTACH PARTITION ID {literal(partition)} FROM {quote(table)}")
    else:
        query(f"INSERT INTO {quote(staged)} SELECT * FROM {quote(table)}")
    query(f"EXCHANGE TABLES {quote(table)} AND {quote(staged)}")
    query(f"DROP TABLE {quote(staged)} SYNC")
    print(f"replicate: converted {table} ({engine})")


def main():
    tables = rows(
        f"SELECT name, engine, create_table_query FROM system.tables "
        f"WHERE database = {literal(DATABASE)} AND NOT is_temporary ORDER BY name"
    )
    # A staging table left after the swap holds the old, unreplicated copy.
    names = {name for name, _, _ in tables}
    for name, engine, _ in tables:
        if name.endswith(SUFFIX) and name[: -len(SUFFIX)] in names:
            query(f"DROP TABLE {quote(name)} SYNC")
    tables = [t for t in tables if not t[0].endswith(SUFFIX)]

    for name, engine, create in tables:
        if engine.endswith("MergeTree") and not engine.startswith("Replicated") or engine == "TinyLog":
            convert(name, engine, create)

    # Step 2: the same objects on every replica. Keeper registers each
    # replica of a replicated table, a replica that is down included, so a
    # table registered fewer times than the cluster has replicas is missing
    # somewhere: just converted, or a replica that was down or is new. Then
    # every function, dictionary, and table goes out with ON CLUSTER and IF
    # NOT EXISTS. throw_only_active waits for the replicas that are up and
    # reports their errors; one that is down runs the statements from the
    # DDL queue when it returns. Functions and dictionaries come first:
    # column defaults call dictGet, which ClickHouse checks when it creates
    # the table, and neither checks its own references. Later functions and
    # dictionaries are Plausible's to create, with ON CLUSTER, once its
    # tables are replicated.
    db = literal(DATABASE)
    replicas = int(rows("SELECT count() FROM system.clusters WHERE cluster = getMacro('cluster')")[0][0])
    # ON CLUSTER reaches the replicas the cluster definition lists when the
    # statement is issued. The Altinity operator adds a replica to it some
    # time after the replica starts, so on a first install the definition
    # can list fewer than the server has. Exiting fails the init container,
    # and the kubelet runs it again.
    if replicas < REPLICAS:
        sys.exit(f"replicate: the cluster definition lists {replicas} of {REPLICAS} replicas; waiting for the rest")
    incomplete = rows(f"SELECT table FROM system.replicas WHERE database = {db} AND total_replicas < {replicas}")
    if not incomplete:
        print(f"replicate: {DATABASE} is replicated on all {replicas} replicas")
        return
    kinds = [
        # (what, query for name and definition, CREATE keyword)
        ("function", "SELECT name, create_query FROM system.functions WHERE origin = 'SQLUserDefined'", "FUNCTION"),
        ("dictionary", f"SELECT name, create_table_query FROM system.tables WHERE database = {db} AND engine = 'Dictionary'", "DICTIONARY"),
        ("table", f"SELECT name, create_table_query FROM system.tables WHERE database = {db} AND engine LIKE 'Replicated%'", "TABLE"),
    ]
    for what, select, keyword in kinds:
        for name, create in rows(select + " ORDER BY name"):
            target = quote(name) if what == "function" else f"{quote(DATABASE)}.{quote(name)}"
            if what == "dictionary":
                # SHOW CREATE masks the source password; Plausible's
                # dictionaries log in as this same user
                # (Plausible.MigrationUtils.dictionary_connection_params).
                create = create.replace("PASSWORD '[HIDDEN]'", f"PASSWORD {literal(PASSWORD)}")
            statement = re.sub(rf"^CREATE {keyword} \S+", f"CREATE {keyword} IF NOT EXISTS {target} {ON_CLUSTER}", create)
            query(statement, distributed_ddl_output_mode="throw_only_active")
    print(f"replicate: created {DATABASE}'s objects on every replica ({len(incomplete)} tables were missing somewhere)")


main()

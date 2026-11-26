//! The check that the files `kix gc` builds make the build the cluster runs.
//!
//! `kix gc` deletes what the files' build no longer has. When the cluster
//! runs another build, that would delete objects the running build still
//! uses, so gc refuses before it lists or deletes anything.

use miette::{Result, miette};

use kix::cluster::activation::{Record, Records};

/// Refuse when Kix cluster `cluster` has a current deploy record and the
/// files make another build, `files_hash` being the identity hash of the
/// files' build. A cluster without a current record passes: the default
/// mode stops on it by itself. Reads the records through `records`.
pub(super) async fn refuse_other_build(
    records: Option<&Records>,
    cluster: &str,
    files_hash: Option<&str>,
) -> Result<()> {
    let Some(records) = records else {
        return Ok(());
    };
    let Some(active) = records.active(cluster).await.map_err(|e| miette!("{e}"))? else {
        return Ok(());
    };
    if active.identity_hash.is_some() && active.identity_hash.as_deref() == files_hash {
        return Ok(());
    }
    let stopped = records.stopped(cluster).await.map_err(|e| miette!("{e}"))?;
    let partial = stopped.iter().find(|r| {
        r.partly_deployed().is_some()
            && files_hash.is_some()
            && r.identity_hash.as_deref() == files_hash
    });
    Err(miette!(
        "{}",
        other_build(cluster, &active, files_hash, partial)
    ))
}

fn short(hash: Option<&str>) -> String {
    match hash {
        Some(h) => h[..12.min(h.len())].to_string(),
        None => "unknown".to_string(),
    }
}

/// Return the refusal for files that make build `files_hash` while the
/// cluster runs `active`. `partial` is a record `kix deploy --only` left
/// partly deployed with the files' build.
pub(super) fn other_build(
    cluster: &str,
    active: &Record,
    files_hash: Option<&str>,
    partial: Option<&Record>,
) -> String {
    let mut out = format!(
        "[K6276] the files make another build than the one Kix cluster '{cluster}' runs, so `kix gc` stopped\n  \
         Nothing was deleted and no deployment record was retired.\n\n  \
         The cluster runs:  deployment record {} (build {})\n  \
         The files make:    build {}\n",
        active.name,
        short(active.identity_hash.as_deref()),
        short(files_hash),
    );
    if let Some(partial) = partial {
        let only = partial
            .partly_deployed()
            .map(|p| p.only.join(", "))
            .unwrap_or_default();
        out.push_str(&format!(
            "\n  Deployment record {} holds the files' build partly deployed: `kix deploy --only` applied {only}. \
             `kix deploy {cluster}` applies the rest of it.\n",
            partial.name,
        ));
    }
    out.push_str(&format!(
        "\n  Why:\n    \
         `kix gc` deletes what the files' build no longer has. While the cluster runs another build, \
         that would delete objects the running build still uses.\n\n  \
         Next (choose one):\n    \
         - Deploy the files with `kix deploy {cluster}`, then run `kix gc {cluster}`.\n    \
         - Deploy the files and delete what they no longer have in one step with `kix deploy {cluster} --prune`.\n    \
         - Check out the commit the cluster runs and run `kix gc {cluster}` there."
    ));
    out
}

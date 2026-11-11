//! The change records JSON that `scripts/change-records.py json` writes
//! reads in Kix. The fixture was made from sample records with
//! `python3 scripts/change-records.py --root <dir> json --version 0.10.0`;
//! make it again the same way when the format changes.

use kix_core::changes::{Document, Kind};

#[test]
fn the_script_output_reads() {
    let text = include_str!("fixtures/changes/kix-0.10.0-changes.json");
    let doc = Document::parse(text).expect("the script's JSON reads");
    assert_eq!(doc.version, "0.10.0");
    let by_name = |name: &str| {
        doc.records
            .iter()
            .find(|r| r.name == name)
            .unwrap_or_else(|| panic!("{name}"))
    };
    let error = by_name("rename-replicas");
    assert_eq!(error.kind, Kind::Error);
    assert_eq!(error.id.as_deref(), Some("K0001"));
    assert_eq!(error.packages, ["echo-server"]);
    assert_eq!(error.cli, ["--old-flag"]);
    let data = by_name("move-data");
    assert_eq!(data.kind, Kind::Silent);
    assert!(data.touches_data);
    let stop = by_name("move-state");
    assert!(stop.state && stop.required_stop);
    let security = by_name("tls-fix");
    assert_eq!(security.kind, Kind::Security);
    assert_eq!(security.cve, ["CVE-2026-0001"]);
    assert!(security.workaround.is_some());
    assert_eq!(by_name("new-thing").library, ["kix.contracts.redis"]);
}

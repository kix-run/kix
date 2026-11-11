//! Change records: one file per user-visible change under the repository's
//! `changes/` folder, described in `changes/README.md`.
//!
//! `build.rs` checks every record and builds it into Kix, so [`compiled`]
//! holds every record up to this version of Kix. An error a record
//! describes prints the record's id in brackets, such as `[K0001]`, and
//! [`find`] looks that id up.

mod record;

use std::sync::OnceLock;

pub use record::{Compiled, Document, DocumentError, Kind, Record, RecordError, SCHEMA, is_id};

/// Return every record built into this Kix, sorted by folder and then by
/// file name.
pub fn compiled() -> &'static [Compiled] {
    static RECORDS: OnceLock<Vec<Compiled>> = OnceLock::new();
    RECORDS.get_or_init(|| {
        serde_json::from_str(include_str!(concat!(env!("OUT_DIR"), "/changes.json")))
            .expect("build.rs writes valid change records")
    })
}

/// Return the record built into this Kix whose id is `id`. The id may be in
/// brackets and in any case.
pub fn find(id: &str) -> Option<&'static Compiled> {
    find_in(compiled(), id)
}

/// Return the record in `records` whose id is `id`. The id may be in
/// brackets and in any case.
pub fn find_in<'a>(records: &'a [Compiled], id: &str) -> Option<&'a Compiled> {
    let id = normalize_id(id)?;
    records
        .iter()
        .find(|c| c.record.id.as_deref() == Some(id.as_str()))
}

/// Return `input` as a record id (`K0001`), accepting brackets and any case,
/// or `None` when it does not have the shape of one.
pub fn normalize_id(input: &str) -> Option<String> {
    let trimmed = input.trim();
    let bare = trimmed
        .strip_prefix('[')
        .and_then(|s| s.strip_suffix(']'))
        .unwrap_or(trimmed);
    let id = bare.to_ascii_uppercase();
    is_id(&id).then_some(id)
}

/// Return each id written in brackets in `text`, such as `[K0001]`, in the
/// order they first appear.
pub fn ids_in(text: &str) -> Vec<String> {
    let mut ids: Vec<String> = Vec::new();
    for (start, _) in text.match_indices("[K") {
        let Some(candidate) = text.get(start + 1..start + 6) else {
            continue;
        };
        if is_id(candidate)
            && text[start + 6..].starts_with(']')
            && !ids.iter().any(|i| i == candidate)
        {
            ids.push(candidate.to_owned());
        }
    }
    ids
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(text: &str) -> Result<Record, RecordError> {
        Record::parse("example", text)
    }

    /// Assert that `text` fails to parse with a problem containing `needle`.
    fn refused(text: &str, needle: &str) {
        let err = parse(text).expect_err("the record should be refused");
        assert!(
            err.0.iter().any(|p| p.contains(needle)),
            "expected a problem containing {needle:?}, got {err}"
        );
    }

    const ERROR_RECORD: &str = "+++\nkind = \"error\"\npackages = [\"echo-server\", \"dns-exporter\"]\nid = \"K0001\"\n+++\n`echo-server` renames `replicaCount` to `replicas`.\n";

    #[test]
    fn changes_parse_a_full_record() {
        let r = parse(ERROR_RECORD).unwrap();
        assert_eq!(r.name, "example");
        assert_eq!(r.kind, Kind::Error);
        assert_eq!(r.packages, ["echo-server", "dns-exporter"]);
        assert_eq!(r.id.as_deref(), Some("K0001"));
        assert!(r.is_breaking());
        assert_eq!(
            r.body.trim(),
            "`echo-server` renames `replicaCount` to `replicas`."
        );
    }

    #[test]
    fn changes_parse_every_field() {
        let r = parse(
            "+++\nkind = \"silent\"\nlibrary = [\"kix.contracts.redis\"]\ncli = [\"--old\"]\nstate = true\ntouches-data = true\nrequired-stop = true\n+++\nMoved.\n",
        )
        .unwrap();
        assert_eq!(r.kind, Kind::Silent);
        assert_eq!(r.library, ["kix.contracts.redis"]);
        assert_eq!(r.cli, ["--old"]);
        assert!(r.state && r.touches_data && r.required_stop);
        assert_eq!(r.id, None);

        let r = parse(
            "+++\nkind = \"security\"\ncve = [\"CVE-2026-1\"]\nworkaround = \"Set x.\"\n+++\nFixed.\n",
        )
        .unwrap();
        assert_eq!(r.cve, ["CVE-2026-1"]);
        assert_eq!(r.workaround.as_deref(), Some("Set x."));
        assert!(!r.is_breaking());
    }

    #[test]
    fn changes_refuse_a_bad_layout() {
        refused("kind = \"added\"\n", "must start with a `+++` line");
        refused("+++\nkind = \"added\"\nText.\n", "no closing `+++` line");
        refused("+++\nkind = \n+++\nText.\n", "not valid TOML");
        refused(
            "+++\nkind = \"added\"\n+++\n\n  \n",
            "text below the header is empty",
        );
    }

    #[test]
    fn changes_refuse_bad_fields() {
        refused("+++\n+++\nText.\n", "`kind` is required");
        refused("+++\nkind = \"removed\"\n+++\nText.\n", "is unknown");
        refused("+++\nkind = 1\n+++\nText.\n", "`kind` must be a string");
        refused(
            "+++\nkind = \"added\"\ntouchesData = true\n+++\nText.\n",
            "unknown field `touchesData`",
        );
        refused(
            "+++\nkind = \"added\"\npackages = \"caddy\"\n+++\nText.\n",
            "`packages` must be a list of strings",
        );
        refused(
            "+++\nkind = \"added\"\npackages = [1]\n+++\nText.\n",
            "`packages` must be a list of strings",
        );
        refused(
            "+++\nkind = \"added\"\nstate = \"yes\"\n+++\nText.\n",
            "`state` must be true or false",
        );
    }

    #[test]
    fn changes_refuse_bad_kind_and_field_combinations() {
        refused("+++\nkind = \"error\"\n+++\nText.\n", "needs an `id`");
        refused(
            "+++\nkind = \"added\"\nid = \"K001\"\n+++\nText.\n",
            "must be K and four digits",
        );
        refused(
            "+++\nkind = \"added\"\nid = \"k0001\"\n+++\nText.\n",
            "must be K and four digits",
        );
        refused(
            "+++\nkind = \"error\"\nid = \"K0001\"\ntouches-data = true\n+++\nText.\n",
            "`touches-data` is only for",
        );
        refused(
            "+++\nkind = \"note\"\nrequired-stop = true\n+++\nText.\n",
            "`required-stop` needs `state = true`",
        );
        refused(
            "+++\nkind = \"fixed\"\ncve = [\"CVE-1\"]\n+++\nText.\n",
            "`cve` is only for",
        );
        refused(
            "+++\nkind = \"security\"\n+++\nText.\n",
            "needs a `workaround`",
        );
        refused(
            "+++\nkind = \"security\"\nworkaround = \"  \"\n+++\nText.\n",
            "needs a `workaround`",
        );
        refused(
            "+++\nkind = \"fixed\"\nworkaround = \"x\"\n+++\nText.\n",
            "`workaround` is only for",
        );
    }

    #[test]
    fn changes_report_every_problem() {
        let err = parse("+++\nkind = \"error\"\ncolour = 1\n+++\n\n").unwrap_err();
        assert_eq!(err.0.len(), 3, "{err}");
    }

    #[test]
    fn changes_kinds_follow_the_changelog() {
        assert_eq!(Kind::Error.heading(), "Breaking (shows an error)");
        assert_eq!(Kind::Silent.heading(), "Breaking (no error)");
        let breaking: Vec<_> = Kind::ALL.into_iter().filter(|k| k.is_breaking()).collect();
        assert_eq!(breaking, [Kind::Error, Kind::Silent]);
        for k in Kind::ALL {
            assert_eq!(Kind::from_name(k.name()), Some(k));
        }
    }

    #[test]
    fn changes_read_the_json_document() {
        let doc = Document::parse(
            r#"{
              "schema": "kix.run/changes/v1",
              "version": "0.10.0",
              "future": {"x": 1},
              "records": [{
                "name": "rename-replica-count",
                "kind": "error",
                "packages": ["echo-server"],
                "library": [], "cli": [],
                "state": false, "touchesData": false, "requiredStop": true,
                "id": "K0001", "cve": [], "workaround": null,
                "body": "Renamed.",
                "addedLater": "skipped"
              }, {"name": "minimal", "kind": "added"}]
            }"#,
        )
        .unwrap();
        assert_eq!(doc.version, "0.10.0");
        assert_eq!(doc.records.len(), 2);
        let r = &doc.records[0];
        assert_eq!(r.kind, Kind::Error);
        assert!(r.required_stop);
        assert_eq!(r.id.as_deref(), Some("K0001"));
        assert_eq!(doc.records[1].body, "");

        let json = serde_json::to_value(r).unwrap();
        assert_eq!(json["touchesData"], false);
        assert_eq!(json["requiredStop"], true);
    }

    #[test]
    fn changes_refuse_another_schema() {
        let err = Document::parse(
            r#"{"schema": "kix.run/changes/v2", "version": "1.0.0", "records": []}"#,
        )
        .unwrap_err();
        assert!(matches!(err, DocumentError::Schema(_)), "{err}");
        assert!(Document::parse("{").is_err());
    }

    fn compiled_fixture() -> Vec<Compiled> {
        vec![
            Compiled {
                release: Some("0.10.0".into()),
                record: parse(ERROR_RECORD).unwrap(),
            },
            Compiled {
                release: None,
                record: Record::parse("plain", "+++\nkind = \"added\"\n+++\nNew.\n").unwrap(),
            },
        ]
    }

    #[test]
    fn changes_find_by_id_in_any_form() {
        let records = compiled_fixture();
        for form in ["K0001", "k0001", "[K0001]", " [k0001] "] {
            let found = find_in(&records, form).unwrap_or_else(|| panic!("{form}"));
            assert_eq!(found.record.name, "example");
            assert_eq!(found.release.as_deref(), Some("0.10.0"));
        }
        assert!(find_in(&records, "K0002").is_none());
        assert!(find_in(&records, "K01").is_none());
        assert!(find_in(&records, "plain").is_none());
    }

    #[test]
    fn changes_find_ids_in_text() {
        assert_eq!(
            ids_in("[K0002] x [K0001] y [K0002] [K12] [k0003] K0004 [K00051]"),
            ["K0002", "K0001"]
        );
        assert!(ids_in("no ids, and a trailing [K").is_empty());
    }

    #[test]
    fn changes_compiled_records_are_valid() {
        // Every compiled record passed `Record::parse` in build.rs, and
        // the ids are unique.
        let mut ids: Vec<_> = compiled()
            .iter()
            .filter_map(|c| c.record.id.clone())
            .collect();
        let n = ids.len();
        ids.sort();
        ids.dedup();
        assert_eq!(ids.len(), n);
    }
}

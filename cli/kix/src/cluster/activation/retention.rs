//! Retention policy and retirement planning for superseded Activation records.

use super::record::{Record, sort_newest_first};

/// Default minimum and maximum number of `Superseded` records kept by
/// [`RetentionPolicy`].
///
/// Each retained record keeps one hash in the `kix.run/activations` annotation
/// on every managed resource (which is subject to Kubernetes's 256 KiB
/// annotation size limit).
pub const DEFAULT_KEEP_MIN: usize = 10;
pub const DEFAULT_KEEP_MAX: usize = 50;

/// Retention policy governing how many `Superseded` records to keep by count
/// and age.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RetentionPolicy {
    /// Minimum number of newest rollback targets to keep regardless of age.
    pub keep_min: usize,
    /// Maximum total number of `Superseded` records to keep.
    pub keep_max: usize,
    /// Maximum age for records beyond `keep_min`, or `None` to disable
    /// age-based retirement.
    pub keep_for: Option<chrono::Duration>,
    /// Reference timestamp used to evaluate `keep_for`.
    pub now: chrono::DateTime<chrono::Utc>,
}

/// Reason a `Superseded` record was selected for retirement.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RetireReason {
    /// Exceeded the `keep_max` cap on retained records.
    BeyondMax(usize),
    /// Older than `keep_for` and not protected by the `keep_min` floor.
    OlderThan(chrono::Duration),
    /// Missing or malformed timestamps in `deployed-at`, `status.failure.at`,
    /// and `metadata.creationTimestamp`.
    UnknownAge,
}

/// A record selected for retirement along with the reason it was retired.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Retired {
    pub record: Record,
    pub reason: RetireReason,
}

/// Partition of `Superseded` records into kept and retired sets.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Retirement {
    /// Records to retain, sorted newest first.
    pub kept: Vec<Record>,
    /// Records to delete, sorted newest first, each paired with its [`RetireReason`].
    pub retire: Vec<Retired>,
}

/// Partition a cluster's `Superseded` records into kept and retired sets under
/// `policy`.
///
/// Sorts records newest first by [`Record::retention_time`] (with missing
/// timestamps sorting oldest and ties broken by name). Among records that
/// completed a deploy ([`Record::was_ever_current`]):
/// * The newest `keep_min` are always kept regardless of age.
/// * Records beyond `keep_max` are retired with [`RetireReason::BeyondMax`].
/// * Records between `keep_min` and `keep_max` are retired when `keep_for` is
///   set and the record is older than `keep_for` (or has [`RetireReason::UnknownAge`]).
///
/// Records that never completed a deploy do not count toward `keep_min` so a
/// series of failed deploys cannot displace the last valid rollback target.
/// They are subject to `keep_for`, and if the total number of kept records
/// still exceeds `keep_max`, the oldest incomplete records are retired first.
pub fn retire_plan(mut superseded: Vec<Record>, policy: &RetentionPolicy) -> Retirement {
    let keep_max = policy.keep_max.max(policy.keep_min);
    sort_newest_first(&mut superseded);
    let mut plan = Retirement::default();
    let mut targets = 0;
    for record in superseded {
        if record.was_ever_current() {
            let i = targets;
            targets += 1;
            if i < policy.keep_min {
                plan.kept.push(record);
                continue;
            }
            if i >= keep_max {
                plan.retire.push(Retired {
                    record,
                    reason: RetireReason::BeyondMax(keep_max),
                });
                continue;
            }
        }
        match (policy.keep_for, record.retention_time()) {
            (None, _) => plan.kept.push(record),
            (Some(_), None) => plan.retire.push(Retired {
                record,
                reason: RetireReason::UnknownAge,
            }),
            (Some(max_age), Some(t)) if policy.now - t > max_age => plan.retire.push(Retired {
                record,
                reason: RetireReason::OlderThan(max_age),
            }),
            (Some(_), Some(_)) => plan.kept.push(record),
        }
    }
    // Enforce keep_max across all kept records by retiring the oldest records
    // that never completed a deploy.
    while plan.kept.len() > keep_max {
        let Some(i) = plan.kept.iter().rposition(|r| !r.was_ever_current()) else {
            break;
        };
        plan.retire.push(Retired {
            record: plan.kept.remove(i),
            reason: RetireReason::BeyondMax(keep_max),
        });
    }
    plan.retire.sort_by(|a, b| {
        b.record
            .retention_time()
            .cmp(&a.record.retention_time())
            .then_with(|| a.record.name.cmp(&b.record.name))
    });
    plan
}

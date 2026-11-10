//! Path-based ignore matching for the structural differ.

use std::collections::BTreeSet;

/// Check if a JSON path matches any ignore pattern.
///
/// Supports:
/// - Exact paths: `$.spec.template.metadata.annotations`
/// - Suffix wildcards: `*.annotations` matches any path ending in `.annotations`
pub(crate) fn path_ignored(path: &str, ignore_paths: &BTreeSet<String>) -> bool {
    if ignore_paths.is_empty() {
        return false;
    }
    if ignore_paths.contains(path) {
        return true;
    }
    for pattern in ignore_paths {
        if let Some(suffix) = pattern.strip_prefix('*')
            && path.ends_with(suffix)
        {
            return true;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    fn set(patterns: &[&str]) -> BTreeSet<String> {
        patterns.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn exact_match() {
        let ignore = set(&["$.metadata.annotations"]);
        assert!(path_ignored("$.metadata.annotations", &ignore));
        assert!(!path_ignored("$.metadata.labels", &ignore));
    }

    #[test]
    fn suffix_wildcard() {
        let ignore = set(&["*.annotations"]);
        assert!(path_ignored("$.metadata.annotations", &ignore));
        assert!(path_ignored(
            "$.spec.template.metadata.annotations",
            &ignore
        ));
        assert!(!path_ignored("$.metadata.labels", &ignore));
    }
}

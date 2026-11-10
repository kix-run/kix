//! Sanitize untrusted text for terminal output.

use std::fmt::Write;

/// Maximum number of characters that [`printable`] shows for a single string.
pub(crate) const MAX_SHOWN_CHARS: usize = 512;

/// Return `s` with non-printable or visually ambiguous characters replaced by
/// their Unicode code points, such as `cluster-admin⟨U+200B⟩`.
///
/// Escapes control characters (which can move the cursor or clear the screen),
/// Unicode format characters (including bidirectional controls), and line or
/// paragraph separators. Use this for text that Kix did not generate, such as
/// names from an external build, so that distinct strings always look
/// distinct. Shows at most [`MAX_SHOWN_CHARS`] characters and summarizes any
/// remaining bytes.
pub fn printable(s: &str) -> String {
    printable_up_to(s, MAX_SHOWN_CHARS)
}

/// Format `s` like [`printable`], showing at most `max_chars` characters.
pub fn printable_up_to(s: &str, max_chars: usize) -> String {
    let (shown, rest) = match s.char_indices().nth(max_chars) {
        Some((i, _)) => s.split_at(i),
        None => (s, ""),
    };
    let mut out = String::with_capacity(shown.len());
    for c in shown.chars() {
        if is_hidden(c) {
            let _ = write!(out, "⟨U+{:04X}⟩", c as u32);
        } else {
            out.push(c);
        }
    }
    if !rest.is_empty() {
        let _ = write!(out, "… ({} more bytes)", rest.len());
    }
    out
}

/// Return whether [`printable`] escapes `c` as its code point: control
/// characters (`Cc`), format characters (`Cf`, which includes every
/// `Bidi_Control` character), or line and paragraph separators (`Zl`, `Zp`).
pub(crate) fn is_hidden(c: char) -> bool {
    c.is_control() || is_format(c) || matches!(c, '\u{2028}' | '\u{2029}')
}

/// Return whether `c` is a Unicode `Bidi_Control` character.
#[cfg(test)]
fn is_bidi_control(c: char) -> bool {
    matches!(
        c,
        '\u{61c}' | '\u{200e}'..='\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}'
    )
}

/// Return whether `c` is a Unicode format character (`General_Category=Cf`,
/// Unicode 16), such as zero-width space (`U+200B`), word joiner (`U+2060`),
/// byte order mark (`U+FEFF`), soft hyphen (`U+00AD`), or a tag character.
fn is_format(c: char) -> bool {
    matches!(
        c,
        '\u{ad}'
            | '\u{600}'..='\u{605}'
            | '\u{61c}'
            | '\u{6dd}'
            | '\u{70f}'
            | '\u{890}'..='\u{891}'
            | '\u{8e2}'
            | '\u{180e}'
            | '\u{200b}'..='\u{200f}'
            | '\u{202a}'..='\u{202e}'
            | '\u{2060}'..='\u{2064}'
            | '\u{2066}'..='\u{206f}'
            | '\u{feff}'
            | '\u{fff9}'..='\u{fffb}'
            | '\u{110bd}'
            | '\u{110cd}'
            | '\u{13430}'..='\u{1343f}'
            | '\u{1bca0}'..='\u{1bca3}'
            | '\u{1d173}'..='\u{1d17a}'
            | '\u{e0001}'
            | '\u{e0020}'..='\u{e007f}'
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn long_text_is_cut_short() {
        let text = "a".repeat(1 << 20);
        let shown = printable(&text);
        assert!(shown.len() < 2 * MAX_SHOWN_CHARS, "{} bytes", shown.len());
        assert!(
            shown.ends_with(&format!("({} more bytes)", (1 << 20) - MAX_SHOWN_CHARS)),
            "{shown}"
        );
    }

    #[test]
    fn hidden_characters_show_as_their_code_points() {
        assert_eq!(printable("\u{61c}"), "⟨U+061C⟩");
        assert_eq!(printable("x\u{1b}[2J"), "x⟨U+001B⟩[2J");
        assert_eq!(printable("a\nb"), "a⟨U+000A⟩b");
        assert_eq!(printable("cluster-admin\u{200b}"), "cluster-admin⟨U+200B⟩");
        for c in [
            '\u{ad}',
            '\u{2060}',
            '\u{feff}',
            '\u{202e}',
            '\u{2028}',
            '\u{e0041}',
        ] {
            assert_eq!(printable(&c.to_string()), format!("⟨U+{:04X}⟩", c as u32));
        }
        assert_eq!(printable("café Straße"), "café Straße");
    }

    /// Every Bidi_Control character is a format character, so `printable`
    /// escapes them all.
    #[test]
    fn bidi_controls_are_format_characters() {
        for c in (0..=0x10FFFFu32).filter_map(char::from_u32) {
            if is_bidi_control(c) {
                assert!(is_format(c), "U+{:04X}", c as u32);
            }
        }
    }
}

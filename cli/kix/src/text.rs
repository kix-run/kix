//! Text from outside kix, made safe to print.

use std::fmt::Write;

/// The most characters of one piece of outside text that [`printable`]
/// shows.
pub const MAX_SHOWN_CHARS: usize = 512;

/// `s` with every character that does not show as itself replaced by its
/// code point, flagged: `cluster-admin⟨U+200B⟩`. Those are control
/// characters, which can move the cursor or clear the screen, and Unicode's
/// format characters and line and paragraph separators, which are
/// invisible, reorder text (bidirectional controls), or break a line. For
/// text kix did not write, such as a name from a bundle, so two names that
/// differ always look different. Only the first [`MAX_SHOWN_CHARS`]
/// characters show, and the rest is counted.
pub fn printable(s: &str) -> String {
    printable_up_to(s, MAX_SHOWN_CHARS)
}

/// [`printable`] showing up to `max_chars` characters.
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

/// Whether [`printable`] shows `c` as its code point: a control character
/// (General_Category Cc), a format character (Cf, which holds every
/// Bidi_Control character), or a line or paragraph separator (Zl, Zp).
pub fn is_hidden(c: char) -> bool {
    c.is_control() || is_format(c) || matches!(c, '\u{2028}' | '\u{2029}')
}

/// Unicode's Bidi_Control characters.
pub fn is_bidi_control(c: char) -> bool {
    matches!(
        c,
        '\u{61c}' | '\u{200e}'..='\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}'
    )
}

/// Unicode's format characters (General_Category Cf, Unicode 16), such as
/// the zero-width space U+200B, the word joiner U+2060, the byte order mark
/// U+FEFF, the soft hyphen U+00AD, and the tag characters.
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

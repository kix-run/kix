//! What the fuzz targets share: a container written from frames the fuzzer
//! changes as plain bytes, and bounds on what `PathsChecked::read` and
//! `PlanFile::verify` hold.

use std::alloc::{GlobalAlloc, Layout, System};
use std::io::Cursor;
use std::sync::atomic::{AtomicIsize, Ordering};

use kix::plan::file::PlanFile;
use kix_bundle::PathsChecked;

/// Separates the frames of a `*_frames` target's input.
pub const FRAME_SEPARATOR: &[u8] = b"\n\0kix-frame\0\n";

/// The bundle file of `input`: each piece between [`FRAME_SEPARATOR`]s is
/// one frame's decompressed bytes, the first the header. A fuzzer that
/// changes these bytes reaches the header and file checks; one that
/// changes a compressed bundle mostly reaches zstd's.
pub fn bundle_of_frames(input: &[u8]) -> Vec<u8> {
    let mut frames: Vec<&[u8]> = Vec::new();
    let mut rest = input;
    while let Some(at) = rest
        .windows(FRAME_SEPARATOR.len())
        .position(|w| w == FRAME_SEPARATOR)
    {
        frames.push(&rest[..at]);
        rest = &rest[at + FRAME_SEPARATOR.len()..];
    }
    frames.push(rest);
    let mut out = Vec::new();
    let mut table = Vec::new();
    for frame in frames {
        let mut c = zstd::bulk::Compressor::new(1).unwrap();
        c.include_contentsize(true).unwrap();
        let stored = c.compress(frame).unwrap();
        table.push((stored.len() as u32, frame.len() as u32));
        out.extend(stored);
    }
    out.extend(0x184D_2A5Eu32.to_le_bytes());
    out.extend((8 * table.len() as u32 + 9).to_le_bytes());
    for (stored, size) in &table {
        out.extend(stored.to_le_bytes());
        out.extend(size.to_le_bytes());
    }
    out.extend((table.len() as u32).to_le_bytes());
    out.push(0);
    out.extend(0x8F92_EAB1u32.to_le_bytes());
    out
}

/// The decompressed size the seek table of `bundle` gives frame 0 (the
/// header) and the largest other frame, or `None` without a table these
/// can be read from.
pub fn declared_sizes(bundle: &[u8]) -> Option<(u64, u64)> {
    let u32_at = |at: usize| -> Option<u64> {
        Some(u32::from_le_bytes(bundle.get(at..at + 4)?.try_into().ok()?) as u64)
    };
    let footer = bundle.len().checked_sub(9)?;
    let frames = usize::try_from(u32_at(footer)?).ok()?;
    let table = footer.checked_sub(frames.checked_mul(8)?)?;
    let sizes: Vec<u64> = (0..frames)
        .map(|k| u32_at(table + 8 * k + 4))
        .collect::<Option<_>>()?;
    let (header, data) = sizes.split_first()?;
    Some((*header, data.iter().copied().max().unwrap_or(0)))
}

/// Counts the bytes the process holds and the most it has held since
/// [`reset_peak`]. The fuzz targets run one input at a time on one thread.
struct Counting;

static NOW: AtomicIsize = AtomicIsize::new(0);
static PEAK: AtomicIsize = AtomicIsize::new(0);

fn add(bytes: isize) {
    let now = NOW.fetch_add(bytes, Ordering::Relaxed) + bytes;
    PEAK.fetch_max(now, Ordering::Relaxed);
}

// SAFETY: each method passes its arguments to `System` unchanged.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let p = unsafe { System.alloc(layout) };
        if !p.is_null() {
            add(layout.size() as isize);
        }
        p
    }
    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        let p = unsafe { System.alloc_zeroed(layout) };
        if !p.is_null() {
            add(layout.size() as isize);
        }
        p
    }
    unsafe fn dealloc(&self, p: *mut u8, layout: Layout) {
        unsafe { System.dealloc(p, layout) };
        add(-(layout.size() as isize));
    }
    unsafe fn realloc(&self, p: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        let q = unsafe { System.realloc(p, layout, new_size) };
        if !q.is_null() {
            add(new_size as isize - layout.size() as isize);
        }
        q
    }
}

#[global_allocator]
static COUNTING: Counting = Counting;

/// The most bytes held while `f` ran, beyond what was held when it began.
pub fn peak_during<T>(f: impl FnOnce() -> T) -> (T, u64) {
    let start = NOW.load(Ordering::Relaxed);
    PEAK.store(start, Ordering::Relaxed);
    let out = f();
    (out, (PEAK.load(Ordering::Relaxed) - start).max(0) as u64)
}

/// `PathsChecked::read` holds the header, as read and parsed, one frame
/// compressed and decompressed, and the Activation record parsed. Bounded
/// by [`HOLD_FACTOR`] times the header and the largest frame, as the seek
/// table declares them, plus [`RECORD_FACTOR`] times the record's cap, as
/// parsed JSON takes up to about a hundred times its text, plus
/// [`HOLD_SLACK`] for fixed state.
pub const HOLD_FACTOR: u64 = 4;
pub const RECORD_FACTOR: u64 = 128;
pub const HOLD_SLACK: u64 = 1024 * 1024;

/// Check `bundle` the way the Kix Enterprise server does, and fail when
/// that held more than the bound. With `KIX_FUZZ_REPORT` set, print what
/// it held against the bound.
pub fn check_paths(bundle: &[u8]) {
    let (result, peak) = peak_during(|| PathsChecked::read(Cursor::new(bundle)).map(drop));
    let Some((header, frame)) = declared_sizes(bundle) else {
        assert!(result.is_err(), "a bundle without a seek table was read");
        assert!(
            peak <= HOLD_SLACK,
            "{peak} bytes held reading a bundle without a seek table"
        );
        return;
    };
    let record = frame.min(kix_bundle::MAX_RECORD_BYTES);
    let bound = HOLD_FACTOR * (header + frame) + RECORD_FACTOR * record + HOLD_SLACK;
    if std::env::var_os("KIX_FUZZ_REPORT").is_some() {
        eprintln!(
            "held {peak} header {header} frame {frame} ratio {:.2} read {}",
            peak as f64 / (header + frame).max(1) as f64,
            result.is_ok()
        );
    }
    assert!(
        peak <= bound,
        "PathsChecked::read held {peak} bytes; header {header}, largest frame {frame}, bound {bound}"
    );
}

/// The most [`read_plan_file`] may hold. `PlanFile::verify` holds the
/// header as read (at most 8 MiB) and parsed (at most
/// `MAX_HEADER_VALUES` values), and one frame (at most 4 MiB) compressed
/// and decompressed; reading a manifest holds one file of at most 256 KiB,
/// parsed.
pub const PLAN_HOLD_BYTES: u64 = 256 * 1024 * 1024;

/// Read `file` the way the Kix Enterprise server does: verify it, then read
/// every shown manifest. Fail when that held more than [`PLAN_HOLD_BYTES`].
pub fn read_plan_file(file: &[u8]) {
    let (_, peak) = peak_during(|| {
        let Ok((mut plan, _)) = PlanFile::verify(Cursor::new(file)) else {
            return;
        };
        let ids: Vec<String> = plan.header().shown.keys().cloned().collect();
        for id in ids {
            let _ = plan.old_manifest(&id);
            let _ = plan.new_manifest(&id);
        }
    });
    if std::env::var_os("KIX_FUZZ_REPORT").is_some() {
        eprintln!("held {peak} for {} bytes", file.len());
    }
    assert!(
        peak <= PLAN_HOLD_BYTES,
        "reading a plan file held {peak} bytes"
    );
}

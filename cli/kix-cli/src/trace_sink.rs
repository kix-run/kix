//! Runtime-switchable tracing writer.
//!
//! By default writes to stderr. When the `--tui` deploy renderer is active it
//! would otherwise overwrite the ratatui viewport, so we redirect all tracing
//! output to a per-invocation log file for the lifetime of the TUI session.

use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

struct Sink {
    file: Option<File>,
    path: Option<PathBuf>,
}

fn sink() -> &'static Mutex<Sink> {
    static SINK: OnceLock<Mutex<Sink>> = OnceLock::new();
    SINK.get_or_init(|| {
        Mutex::new(Sink {
            file: None,
            path: None,
        })
    })
}

/// Route subsequent tracing output to `path`. Returns the resolved path.
pub fn redirect_to_file(path: &Path) -> io::Result<PathBuf> {
    let file = OpenOptions::new().create(true).append(true).open(path)?;
    let mut guard = sink().lock().unwrap();
    guard.file = Some(file);
    guard.path = Some(path.to_path_buf());
    Ok(path.to_path_buf())
}

/// Stop redirecting; subsequent tracing output returns to stderr.
pub fn restore_stderr() -> Option<PathBuf> {
    let mut guard = sink().lock().unwrap();
    guard.file = None;
    guard.path.take()
}

/// Return a [`Writer`] for the tracing subscriber.
pub fn make_writer() -> Writer {
    Writer
}

pub struct Writer;

impl Write for Writer {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let mut guard = sink().lock().unwrap();
        if let Some(f) = guard.file.as_mut() {
            f.write(buf)
        } else {
            io::stderr().write(buf)
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        let mut guard = sink().lock().unwrap();
        if let Some(f) = guard.file.as_mut() {
            f.flush()
        } else {
            io::stderr().flush()
        }
    }
}

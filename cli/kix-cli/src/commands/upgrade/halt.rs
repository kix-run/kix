//! How `kix upgrade` ends before it finishes.

use miette::Report;

use crate::exit::Exit;

/// Why `kix upgrade` ends early. Each step of the run returns a [`Flow`], and
/// [`Halt::end`] is the one place that turns a halt into the command's exit.
#[derive(Debug)]
pub enum Halt {
    /// Kix refuses to start or to go on. The text says why and what to do
    /// next, and the command exits with [`Exit::Failure`].
    Refused(String),
    /// The run has printed why it stopped, and the command exits with this
    /// code.
    Stopped(Exit),
    /// An error for `main` to report.
    Error(Report),
}

/// The result of one step of `kix upgrade`.
pub type Flow<T> = std::result::Result<T, Halt>;

impl Halt {
    /// Print what is left to say, and return how the command ends.
    pub fn end(self) -> miette::Result<Exit> {
        match self {
            Halt::Refused(text) => {
                println!("{text}");
                Ok(Exit::Failure)
            }
            Halt::Stopped(exit) => Ok(exit),
            Halt::Error(report) => Err(report),
        }
    }
}

impl From<Report> for Halt {
    fn from(report: Report) -> Self {
        Halt::Error(report)
    }
}

/// Return the halt that refuses with `text`.
pub fn refused(text: impl Into<String>) -> Halt {
    Halt::Refused(text.into())
}

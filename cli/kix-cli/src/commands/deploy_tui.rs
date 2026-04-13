//! Live inline TUI dashboard for `kix deploy --tui`.
//!
//! Architecture:
//!   - `TuiObserver` implements `ReconcileObserver`. Its `on_event` is called
//!     from the async reconcile engine; it clones the event and pushes it over
//!     an mpsc channel — never blocks, never draws directly.
//!   - A dedicated OS thread owns the ratatui `Terminal` (inline viewport).
//!     It receives events, updates `DeployState`, emits historical log lines
//!     above the viewport via `insert_before`, and re-renders the sticky
//!     dashboard on every update and on a ~100ms tick (for elapsed timers).
//!   - `TuiDriver` owns the thread handle and sender. Dropping it closes the
//!     channel, the render thread exits cleanly, and the terminal is restored.
//!
//! Non-TTY callers should check `is_supported()` before constructing a driver
//! and fall back to the plain line-based `CliObserver`.

use std::io::{self, Stdout, Write};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use crossterm::{
    cursor,
    event::{self, Event, KeyCode, KeyEventKind, KeyModifiers},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode},
};
use ratatui::{
    Terminal, TerminalOptions, Viewport,
    backend::CrosstermBackend,
    buffer::Buffer,
    layout::{Constraint, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Paragraph, Widget},
};

use kix::cluster::apply::ApplyAction;
use kix::cluster::cancel::CancelToken;
use kix::cluster::readiness::{self, ImportTarget};
use kix::cluster::reconcile::{ReconcileEvent, ReconcileObserver};
use kix::manifest::types::ResourceId;

/// Height reserved at the bottom of the terminal for the sticky dashboard.
const VIEWPORT_HEIGHT: u16 = 13;
/// Redraw cadence for elapsed timers even when no events arrive.
const TICK: Duration = Duration::from_millis(100);

// ── Public surface ──────────────────────────────────────────────────────────

/// Returns true if stdout is a TTY and a TUI can be reasonably rendered.
pub fn is_supported() -> bool {
    crate::output::is_interactive()
}

/// Observer handed to the reconcile engine. Cheap to clone (just a Sender).
#[derive(Clone)]
pub struct TuiObserver {
    tx: Sender<Msg>,
}

impl ReconcileObserver for TuiObserver {
    fn on_event(&self, event: &ReconcileEvent) {
        // Clone the event and forward it. If the render thread has exited
        // (e.g. panic during teardown), silently drop the event — losing a
        // line is strictly better than panicking the reconcile engine.
        let _ = self.tx.send(Msg::Event(Box::new(event.clone())));
    }
}

/// Owns the render thread. Drop to shut down cleanly.
pub struct TuiDriver {
    tx: Sender<Msg>,
    thread: Option<JoinHandle<()>>,
    input_thread: Option<JoinHandle<()>>,
    input_shutdown: Arc<AtomicBool>,
}

impl TuiDriver {
    /// Initialize the terminal and spawn the render thread.
    ///
    /// `cluster_name`, `total_waves`, and `total_apply` are displayed in the
    /// dashboard header. `cancel` is signalled when the user presses Ctrl+C
    /// in the TUI so the reconcile engine can abort gracefully — raw mode
    /// would otherwise swallow Ctrl+C entirely.
    pub fn spawn(
        cluster_name: String,
        total_waves: usize,
        cancel: CancelToken,
    ) -> io::Result<Self> {
        enable_raw_mode()?;
        let mut stdout = io::stdout();
        execute!(stdout, cursor::Hide)?;

        let backend = CrosstermBackend::new(stdout);
        let terminal = Terminal::with_options(
            backend,
            TerminalOptions {
                viewport: Viewport::Inline(VIEWPORT_HEIGHT),
            },
        )?;

        let (tx, rx) = mpsc::channel::<Msg>();
        let state = DeployState::new(cluster_name, total_waves);

        let thread = thread::Builder::new()
            .name("kix-deploy-tui".into())
            .spawn(move || run_ui(terminal, state, rx))?;

        // Input thread: raw mode delivers Ctrl+C as a key event rather than
        // SIGINT, so we poll crossterm events and translate Ctrl+C into a
        // cancel signal. Without this, there is no way to abort a running
        // deploy from the TUI.
        let input_shutdown = Arc::new(AtomicBool::new(false));
        let input_shutdown_worker = input_shutdown.clone();
        let input_thread = thread::Builder::new()
            .name("kix-deploy-tui-input".into())
            .spawn(move || input_loop(input_shutdown_worker, cancel))?;

        Ok(Self {
            tx,
            thread: Some(thread),
            input_thread: Some(input_thread),
            input_shutdown,
        })
    }

    pub fn observer(&self) -> TuiObserver {
        TuiObserver {
            tx: self.tx.clone(),
        }
    }
}

impl Drop for TuiDriver {
    fn drop(&mut self) {
        // Signal the render thread to finalize (print a summary frame) and
        // then exit. Closing the channel would work too, but Shutdown gives
        // the thread a chance to tear the viewport down in order.
        self.input_shutdown.store(true, Ordering::Release);
        let _ = self.tx.send(Msg::Shutdown);
        if let Some(handle) = self.thread.take() {
            let _ = handle.join();
        }
        if let Some(handle) = self.input_thread.take() {
            let _ = handle.join();
        }
        // Best-effort terminal restore; ignore errors since we can't do
        // anything useful with them at this point.
        let _ = disable_raw_mode();
        let _ = execute!(io::stdout(), cursor::Show);
        let _ = io::stdout().flush();
    }
}

/// Poll crossterm for Ctrl+C and map it to a graceful cancel. A second
/// Ctrl+C within the same session escalates to a hard exit in case the
/// reconcile engine is wedged and not honouring the cancel token.
fn input_loop(shutdown: Arc<AtomicBool>, cancel: CancelToken) {
    let mut already_cancelled = false;
    while !shutdown.load(Ordering::Acquire) {
        match event::poll(Duration::from_millis(100)) {
            Ok(true) => {
                let Ok(ev) = event::read() else { continue };
                let Event::Key(k) = ev else { continue };
                if k.kind == KeyEventKind::Release {
                    continue;
                }
                let is_ctrl_c = k.modifiers.contains(KeyModifiers::CONTROL)
                    && matches!(k.code, KeyCode::Char('c') | KeyCode::Char('C'));
                if !is_ctrl_c {
                    continue;
                }
                if already_cancelled {
                    // Second Ctrl+C: force-exit. Drop won't run on
                    // process::exit, so restore the terminal manually first.
                    let _ = disable_raw_mode();
                    let _ = execute!(io::stdout(), cursor::Show);
                    let _ = io::stdout().flush();
                    std::process::exit(130);
                }
                cancel.cancel();
                already_cancelled = true;
            }
            Ok(false) => {}
            Err(_) => break,
        }
    }
}

// ── Internal messages ───────────────────────────────────────────────────────

enum Msg {
    // Boxed to keep the enum small — ReconcileEvent is ~240 bytes and would
    // otherwise pessimize every channel slot and every Shutdown send.
    Event(Box<ReconcileEvent>),
    Shutdown,
}

// ── State model ─────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ResourceState {
    // Reconcile emits no pre-apply event, so entries only ever enter the
    // in-flight list in WaitingReady or Failed state today. `Applying` and
    // `Ready` are reserved for future events (e.g. a `ResourceApplying` hook)
    // and intentionally absent here to keep the dead-code lint honest.
    WaitingReady,
    Failed,
}

#[derive(Debug, Clone)]
struct InFlight {
    rid: ResourceId,
    label: String,
    state: ResourceState,
    started_at: Instant,
    detail: Option<String>,
}

/// Life-cycle state of a single wave within the overall deploy.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
enum WaveLifecycle {
    /// Engine hasn't touched this wave yet.
    #[default]
    Pending,
    /// Current wave — applying or polling readiness.
    Active,
    /// Wave finished successfully (all resources ready).
    Complete,
    /// Wave was skipped entirely (resume-from-crash or all-unchanged).
    Skipped,
}

/// Per-wave progress counter used by the wave-level + resource-level bars.
#[derive(Debug, Clone, Default)]
struct WaveProgress {
    /// Apply count for this wave — learned from `WaveStart.apply_count`
    /// (zero until the wave has started, which is fine: the wave bar just
    /// renders Pending waves as empty anyway).
    total: usize,
    /// Resources fully done in this wave: either immediate kinds whose
    /// apply succeeded, or non-immediate kinds that reached ReadinessReady.
    done: usize,
    /// Resources that reached a terminal failure state in this wave.
    failed: usize,
    status: WaveLifecycle,
}

struct DeployState {
    cluster_name: String,
    total_waves: usize,
    /// Per-wave progress, indexed by wave_index. Length = `total_waves`.
    waves: Vec<WaveProgress>,
    /// Global failed count for the header strip. Sum of `waves[*].failed`
    /// but cached here so the header doesn't have to re-sum on every tick.
    failed: usize,

    current_wave: Option<usize>,

    in_flight: Vec<InFlight>,
    last_status: Option<String>,
    started_at: Instant,
    finalized: bool,
}

impl DeployState {
    fn new(cluster_name: String, total_waves: usize) -> Self {
        Self {
            cluster_name,
            total_waves,
            waves: vec![WaveProgress::default(); total_waves],
            failed: 0,
            current_wave: None,
            in_flight: Vec::new(),
            last_status: None,
            started_at: Instant::now(),
            finalized: false,
        }
    }

    /// Convenience: mutable access to the currently-active wave, if any.
    fn current_wave_mut(&mut self) -> Option<&mut WaveProgress> {
        let idx = self.current_wave?;
        self.waves.get_mut(idx)
    }

    fn find_mut(&mut self, rid: &ResourceId) -> Option<&mut InFlight> {
        self.in_flight.iter_mut().find(|e| e.rid == *rid)
    }

    fn remove(&mut self, rid: &ResourceId) -> Option<InFlight> {
        let idx = self.in_flight.iter().position(|e| e.rid == *rid)?;
        Some(self.in_flight.remove(idx))
    }

    fn upsert(&mut self, rid: ResourceId, label: String, state: ResourceState) {
        if let Some(entry) = self.find_mut(&rid) {
            entry.state = state;
            entry.label = label;
            // don't reset started_at — we want the total time on the resource
        } else {
            self.in_flight.push(InFlight {
                rid,
                label,
                state,
                started_at: Instant::now(),
                detail: None,
            });
        }
    }
}

// ── Event → state + scrollback log lines ────────────────────────────────────

/// Result of consuming a single event: state mutations have already been
/// applied; the returned lines should be inserted into scrollback (above the
/// viewport) as historical records.
fn apply_event(state: &mut DeployState, ev: ReconcileEvent) -> Vec<Line<'static>> {
    let mut out = Vec::new();
    match ev {
        ReconcileEvent::WaveStart {
            wave_index,
            apply_count,
            ..
        } => {
            state.current_wave = Some(wave_index);
            if let Some(w) = state.waves.get_mut(wave_index) {
                w.total = apply_count;
                w.status = WaveLifecycle::Active;
            }
            state.in_flight.clear();
            out.push(Line::from(vec![
                Span::raw(""),
                Span::styled(
                    format!("Wave {}:", wave_index + 1),
                    Style::default().add_modifier(Modifier::BOLD),
                ),
                Span::raw(format!(" applying {} resources...", apply_count)),
            ]));
        }
        ReconcileEvent::WaveSkipped {
            wave_index,
            count,
            reason,
        } => {
            state.current_wave = Some(wave_index);
            if let Some(w) = state.waves.get_mut(wave_index) {
                w.total = count;
                w.done = count;
                w.status = WaveLifecycle::Skipped;
            }
            out.push(Line::from(vec![
                Span::styled(
                    format!("Wave {}:", wave_index + 1),
                    Style::default().add_modifier(Modifier::BOLD),
                ),
                Span::raw(format!(
                    " {} resources (already complete, skipping: {})",
                    count, reason
                )),
            ]));
        }
        ReconcileEvent::WaveUnchanged { wave_index, count } => {
            state.current_wave = Some(wave_index);
            if let Some(w) = state.waves.get_mut(wave_index) {
                w.total = count;
                w.done = count;
                w.status = WaveLifecycle::Complete;
            }
            out.push(Line::from(vec![
                Span::styled(
                    format!("Wave {}:", wave_index + 1),
                    Style::default().add_modifier(Modifier::BOLD),
                ),
                Span::raw(format!(" {} resources unchanged", count)),
            ]));
        }
        ReconcileEvent::WaveComplete { wave_index, .. } => {
            if let Some(w) = state.waves.get_mut(wave_index) {
                w.status = WaveLifecycle::Complete;
                // Engine has confirmed the wave is done — snap done to total
                // so the bar reads 100% even if some events raced the
                // WaveComplete arrival.
                w.done = w.total.max(w.done);
            }
            state.in_flight.clear();
        }
        ReconcileEvent::CrdRediscovery => {
            state.last_status = Some("Re-running API discovery after CRD apply...".into());
        }
        ReconcileEvent::ResourceApplied {
            rid,
            action,
            import_target,
            package: _,
        } => {
            let (symbol, symbol_style, label) = match action {
                ApplyAction::Created => ("+", style_fg(Color::Green), "created"),
                ApplyAction::Configured => ("~", style_fg(Color::Yellow), "configured"),
                ApplyAction::Unchanged => ("=", style_dim(), "unchanged"),
                ApplyAction::Skipped => ("-", style_dim(), "skipped"),
            };

            // Progress accounting:
            //   - Immediate kinds (ConfigMap, Secret, …) are "done" the
            //     moment apply succeeds — the engine never emits a readiness
            //     event for them, so this is our only chance to count them.
            //   - Non-immediate kinds (Deployment, StatefulSet, …) are only
            //     applied here; a ReadinessReady event will arrive later and
            //     move them into `done`. Until then they belong in
            //     `in_flight` so the bar shows them as "active" not "done".
            //   - Import markers always go through the readiness path.
            //   - Unchanged/Skipped are bar-invisible (they're not part of
            //     the wave's apply_count, so including them would inflate
            //     the numerator past the total).
            let counts_against_progress =
                matches!(action, ApplyAction::Created | ApplyAction::Configured);
            let is_immediate = import_target.is_none() && readiness::is_immediate_kind(&rid.kind);

            if counts_against_progress {
                if is_immediate {
                    if let Some(w) = state.current_wave_mut() {
                        w.done = w.done.saturating_add(1);
                    }
                    state.remove(&rid);
                } else {
                    // Non-immediate: pre-populate in_flight as WaitingReady
                    // so the bar shows it as "active" immediately, even
                    // though the real ReadinessWaiting event arrives one
                    // render tick later. This removes the visual flicker
                    // where resources briefly appeared as "pending".
                    let label_text = readiness_label(&rid, import_target.as_ref());
                    state.upsert(rid.clone(), label_text, ResourceState::WaitingReady);
                }
            } else {
                // Unchanged / Skipped — never was in flight.
                state.remove(&rid);
            }

            let rid_text = match &import_target {
                Some(t) => format!("↪ import {}/{}", t.kind, t.name),
                None => rid.to_string(),
            };
            out.push(Line::from(vec![
                Span::raw("  "),
                Span::styled(symbol.to_string(), symbol_style),
                Span::raw(" "),
                Span::raw(rid_text),
                Span::raw(" "),
                Span::styled(label.to_string(), style_dim()),
            ]));
        }
        ReconcileEvent::ResourceFailed { rid, error } => {
            state.failed = state.failed.saturating_add(1);
            if let Some(w) = state.current_wave_mut() {
                w.failed = w.failed.saturating_add(1);
            }
            if let Some(entry) = state.find_mut(&rid) {
                entry.state = ResourceState::Failed;
                entry.detail = Some(error.clone());
            } else {
                state.in_flight.push(InFlight {
                    rid: rid.clone(),
                    label: rid.to_string(),
                    state: ResourceState::Failed,
                    started_at: Instant::now(),
                    detail: Some(error.clone()),
                });
            }
            out.push(Line::from(vec![
                Span::raw("  "),
                Span::styled("!", style_fg(Color::Red)),
                Span::raw(" "),
                Span::raw(rid.to_string()),
                Span::raw(" "),
                Span::styled(error, style_fg(Color::Red)),
            ]));
        }
        ReconcileEvent::ResourceRecreated { rid, reason } => {
            out.push(Line::from(vec![
                Span::raw("  "),
                Span::styled("↻", style_fg(Color::Yellow)),
                Span::raw(" "),
                Span::raw(rid.to_string()),
                Span::raw(" "),
                Span::styled(
                    "recreated (immutable-field conflict) ",
                    style_fg(Color::Yellow),
                ),
                Span::styled(reason, style_dim()),
            ]));
        }
        ReconcileEvent::ReadinessWaiting { rid, import_target } => {
            let label = readiness_label(&rid, import_target.as_ref());
            state.upsert(rid, label, ResourceState::WaitingReady);
        }
        ReconcileEvent::ReadinessProgress {
            rid,
            import_target,
            message,
        } => {
            let label = readiness_label(&rid, import_target.as_ref());
            state.upsert(rid.clone(), label, ResourceState::WaitingReady);
            if let Some(entry) = state.find_mut(&rid) {
                entry.detail = Some(message);
            }
        }
        ReconcileEvent::ReadinessReady { rid, import_target } => {
            let label = readiness_label(&rid, import_target.as_ref());
            state.remove(&rid);
            if let Some(w) = state.current_wave_mut() {
                w.done = w.done.saturating_add(1);
            }
            out.push(Line::from(vec![
                Span::raw("  "),
                Span::styled("✓", style_fg(Color::Green)),
                Span::raw(" "),
                Span::styled(label, style_dim()),
                Span::raw(" "),
                Span::styled("ready", style_fg(Color::Green)),
            ]));
        }
        ReconcileEvent::ReadinessTimeout {
            rid,
            import_target,
            elapsed,
            message,
        } => {
            let label = readiness_label(&rid, import_target.as_ref());
            state.remove(&rid);
            state.failed = state.failed.saturating_add(1);
            if let Some(w) = state.current_wave_mut() {
                w.failed = w.failed.saturating_add(1);
            }
            out.push(Line::from(vec![
                Span::raw("  "),
                Span::styled("⏱", style_fg(Color::Yellow)),
                Span::raw(" "),
                Span::styled(label, style_dim()),
                Span::raw(" "),
                Span::styled(
                    format!("timed out ({}s): {}", elapsed.as_secs(), message),
                    style_fg(Color::Yellow),
                ),
            ]));
        }
        ReconcileEvent::ReadinessFailed {
            rid,
            import_target,
            message,
            missing_keys,
        } => {
            state.failed = state.failed.saturating_add(1);
            if let Some(w) = state.current_wave_mut() {
                w.failed = w.failed.saturating_add(1);
            }
            let label = readiness_label(&rid, import_target.as_ref());
            state.remove(&rid);
            out.push(Line::from(vec![
                Span::raw("  "),
                Span::styled("✗", style_fg(Color::Red)),
                Span::raw(" "),
                Span::styled(label, style_dim()),
                Span::raw(" "),
                Span::styled(format!("failed: {}", message), style_fg(Color::Red)),
            ]));
            if !missing_keys.is_empty() {
                out.push(Line::from(vec![
                    Span::raw("    "),
                    Span::styled(
                        format!("↳ missing key(s): {}", missing_keys.join(", ")),
                        style_fg(Color::Red),
                    ),
                ]));
            }
        }
        ReconcileEvent::SecretHydrated { rid, keys } => {
            out.push(Line::from(vec![
                Span::raw("  "),
                Span::styled("🔓", style_fg(Color::Green)),
                Span::raw(" "),
                Span::raw(rid.to_string()),
                Span::raw(format!(" hydrated ({} keys from SOPS)", keys)),
            ]));
        }
        ReconcileEvent::SecretHydrationFailed { rid, error } => {
            out.push(Line::from(vec![
                Span::raw("  "),
                Span::styled("!", style_fg(Color::Red)),
                Span::raw(" "),
                Span::raw(rid.to_string()),
                Span::raw(" secret hydration failed: "),
                Span::styled(error, style_fg(Color::Red)),
            ]));
        }
        ReconcileEvent::PruneStart { count } => {
            state.last_status = Some(format!("Pruning {} orphaned resources...", count));
            out.push(Line::from(vec![Span::styled(
                format!("Prune: pruning {} orphaned resources...", count),
                Style::default().add_modifier(Modifier::BOLD),
            )]));
        }
        ReconcileEvent::PruneSkipped { rid, reason } => {
            out.push(Line::from(vec![
                Span::raw("  "),
                Span::styled("!", style_fg(Color::Yellow)),
                Span::raw(" "),
                Span::raw(rid.to_string()),
                Span::raw(" — "),
                Span::raw(reason),
            ]));
        }
        ReconcileEvent::PruneOk { rid } => {
            out.push(Line::from(vec![
                Span::raw("  "),
                Span::styled("-", style_fg(Color::Red)),
                Span::raw(format!(
                    " pruned {}/{}@{}",
                    rid.kind, rid.name, rid.namespace
                )),
            ]));
        }
        ReconcileEvent::PruneFailed { rid, error } => {
            out.push(Line::from(vec![
                Span::raw("  "),
                Span::styled("!", style_fg(Color::Red)),
                Span::raw(" "),
                Span::raw(rid.to_string()),
                Span::raw(": "),
                Span::styled(error, style_fg(Color::Red)),
            ]));
        }
        ReconcileEvent::Finalized { activation, old } => {
            state.finalized = true;
            if let Some(old) = old {
                out.push(Line::from(vec![
                    Span::raw("  "),
                    Span::styled("•", style_dim()),
                    Span::raw(format!(" Activation '{}' → Superseded", old)),
                ]));
            }
            out.push(Line::from(vec![
                Span::raw("  "),
                Span::styled("•", style_fg(Color::Green)),
                Span::raw(format!(" Activation '{}' → Active", activation)),
            ]));
        }
        ReconcileEvent::Cancelled { at } => {
            out.push(Line::from(vec![
                Span::styled("✗", style_fg(Color::Red)),
                Span::raw(format!(" deploy cancelled at {}", at)),
            ]));
        }
        ReconcileEvent::Stopped { reason } => {
            out.push(Line::from(vec![Span::styled(reason, style_fg(Color::Red))]));
        }
    }
    out
}

fn readiness_label(rid: &ResourceId, import_target: Option<&ImportTarget>) -> String {
    if let Some(t) = import_target {
        format!("↪ import {}/{}", t.kind, t.name)
    } else {
        rid.to_string()
    }
}

fn style_fg(c: Color) -> Style {
    Style::default().fg(c)
}
fn style_dim() -> Style {
    Style::default().add_modifier(Modifier::DIM)
}

// ── Render loop ─────────────────────────────────────────────────────────────

fn run_ui(
    mut terminal: Terminal<CrosstermBackend<Stdout>>,
    mut state: DeployState,
    rx: mpsc::Receiver<Msg>,
) {
    // Initial paint so the viewport is visible before any events arrive.
    let _ = terminal.draw(|f| render(f.area(), f.buffer_mut(), &state));

    loop {
        match rx.recv_timeout(TICK) {
            Ok(Msg::Event(ev)) => {
                let lines = apply_event(&mut state, *ev);
                for line in lines {
                    // insert_before writes `height` rows above the viewport.
                    // We render a single line at a time so the stream looks
                    // identical to the non-TUI path's println! cadence.
                    let _ = terminal.insert_before(1, |buf| {
                        Paragraph::new(line).render(buf.area, buf);
                    });
                }
                let _ = terminal.draw(|f| render(f.area(), f.buffer_mut(), &state));
            }
            Ok(Msg::Shutdown) => break,
            Err(RecvTimeoutError::Timeout) => {
                // Tick redraw for elapsed timers.
                let _ = terminal.draw(|f| render(f.area(), f.buffer_mut(), &state));
            }
            Err(RecvTimeoutError::Disconnected) => break,
        }
    }

    // Clear the sticky viewport so the final scrollback is clean.
    let _ = terminal.clear();
    let _ = terminal.show_cursor();
}

// ── Widgets ─────────────────────────────────────────────────────────────────

fn render(area: Rect, buf: &mut Buffer, state: &DeployState) {
    // Full viewport layout:
    //   row 0:     header line (cluster, wave, elapsed, failed count)
    //   row 1:     wave-level bar (one segment per wave)
    //   row 2:     resource-level bar (current wave's done/active/pending)
    //   row 3:     spacer
    //   row 4..N-2 in-flight list
    //   row N-1:   footer / queued summary
    let chunks = Layout::vertical([
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Min(1),
        Constraint::Length(1),
    ])
    .split(area);

    render_header(chunks[0], buf, state);
    render_wave_bar(chunks[1], buf, state);
    render_resource_bar(chunks[2], buf, state);
    // chunks[3] is a spacer row — leave blank.
    render_in_flight(chunks[4], buf, state);
    render_footer(chunks[5], buf, state);
}

fn render_header(area: Rect, buf: &mut Buffer, state: &DeployState) {
    let wave_str = match state.current_wave {
        Some(i) => format!("Wave {}/{}", i + 1, state.total_waves),
        None => format!("Wave -/{}", state.total_waves),
    };
    let elapsed = format_elapsed(state.started_at.elapsed());
    let failed_span = if state.failed > 0 {
        Span::styled(format!("  ✗ {} failed", state.failed), style_fg(Color::Red))
    } else {
        Span::raw("")
    };
    let line = Line::from(vec![
        Span::styled(
            format!("kix deploy {}", state.cluster_name),
            Style::default().add_modifier(Modifier::BOLD),
        ),
        Span::raw("  "),
        Span::styled(wave_str, style_fg(Color::Cyan)),
        Span::raw("  "),
        Span::styled(elapsed, style_dim()),
        failed_span,
    ]);
    Paragraph::new(line).render(area, buf);
}

// ── Progress bars ───────────────────────────────────────────────────────────
//
// Both bars use the same `draw_segmented_bar` primitive that paints a single
// row of cells left-to-right. Labels are rendered OUTSIDE the bar (to the
// left) so we never have the old "white-on-white / white-on-light-grey"
// contrast problem — the bar itself is pure block characters, the label
// text lives on default-background cells.
//
// Colour semantics (shared across both bars):
//   White       █   fully done (ready / applied for immediate kinds)
//   DarkGray    █   in-flight (applied, waiting readiness) — clearly
//                   distinguishable from done but not as dark as "empty"
//   Red         █   failed in this wave
//   Dim "░"         pending / not yet started
//
// The two "filled" colours (White + DarkGray) are deliberately far apart
// in luminance — the old Gauge-based design used light grey which had
// terrible contrast against the fg text.

/// Left-pad a label with space, then draw it at the start of `area`, and
/// return the sub-rect that remains to the right of the label (for bar
/// painting).
fn draw_label_left(area: Rect, buf: &mut Buffer, label: &str, style: Style) -> Rect {
    let label_w = label.chars().count() as u16;
    buf.set_string(area.x, area.y, label, style);
    if area.width <= label_w + 1 {
        // Not enough space for a bar; return an empty rect.
        return Rect {
            x: area.x + area.width,
            y: area.y,
            width: 0,
            height: 1,
        };
    }
    // +1 for a single space between label and bar.
    Rect {
        x: area.x + label_w + 1,
        y: area.y,
        width: area.width - label_w - 1,
        height: 1,
    }
}

/// Paint a row of cells left-to-right with the given segments, then fill
/// the remainder with dim pending cells. Segments are `(count, color)`
/// pairs expressed in **cells** (not ratios) so the caller can allocate
/// them from an already-computed total width without rounding drift.
fn draw_segmented_bar_cells(area: Rect, buf: &mut Buffer, segments: &[(u16, Color)]) {
    if area.width == 0 || area.height == 0 {
        return;
    }
    let mut col: u16 = 0;
    for (n, color) in segments {
        let end = (col + n).min(area.width);
        while col < end {
            buf.set_string(area.x + col, area.y, "█", Style::default().fg(*color));
            col += 1;
        }
        if col >= area.width {
            break;
        }
    }
    while col < area.width {
        buf.set_string(
            area.x + col,
            area.y,
            "░",
            Style::default().fg(Color::DarkGray),
        );
        col += 1;
    }
}

/// Convert a (numerator, denominator) into a cell count that fills the
/// bar proportionally. Rounds half-up; guarantees 0 when num==0 and a
/// full bar when num>=den.
fn cells_for(num: usize, den: usize, width: u16) -> u16 {
    if den == 0 || num == 0 || width == 0 {
        return 0;
    }
    if num >= den {
        return width;
    }
    ((num as f64 / den as f64) * width as f64).round() as u16
}

fn render_wave_bar(area: Rect, buf: &mut Buffer, state: &DeployState) {
    let completed = state
        .waves
        .iter()
        .filter(|w| matches!(w.status, WaveLifecycle::Complete | WaveLifecycle::Skipped))
        .count();
    let label = format!("Waves {}/{}", completed, state.total_waves);
    let bar_area = draw_label_left(
        area,
        buf,
        &label,
        Style::default().add_modifier(Modifier::BOLD),
    );
    if bar_area.width == 0 || state.total_waves == 0 {
        return;
    }

    // Each wave gets an equal-width slot. Remainder cells at the end of
    // the bar are left as pending so wave boundaries stay stable.
    let slot_w = bar_area.width / state.total_waves as u16;
    if slot_w == 0 {
        // More waves than columns — fall back to a single fill.
        let done_cells = cells_for(completed, state.total_waves, bar_area.width);
        draw_segmented_bar_cells(bar_area, buf, &[(done_cells, Color::White)]);
        return;
    }

    for (i, wave) in state.waves.iter().enumerate() {
        let seg_x = bar_area.x + (i as u16) * slot_w;
        let seg_area = Rect {
            x: seg_x,
            y: bar_area.y,
            width: slot_w,
            height: 1,
        };
        match wave.status {
            WaveLifecycle::Complete | WaveLifecycle::Skipped => {
                draw_segmented_bar_cells(seg_area, buf, &[(slot_w, Color::White)]);
            }
            WaveLifecycle::Pending => {
                draw_segmented_bar_cells(seg_area, buf, &[]);
            }
            WaveLifecycle::Active => {
                // Sub-fill the active wave's slot so the wave-bar hints
                // at how far the current wave is through its resources.
                let done_cells = cells_for(wave.done, wave.total.max(1), slot_w);
                let active_cells = cells_for(state.in_flight.len(), wave.total.max(1), slot_w)
                    .min(slot_w - done_cells);
                draw_segmented_bar_cells(
                    seg_area,
                    buf,
                    &[(done_cells, Color::White), (active_cells, Color::DarkGray)],
                );
            }
        }
    }
}

fn render_resource_bar(area: Rect, buf: &mut Buffer, state: &DeployState) {
    let wave = state.current_wave.and_then(|i| state.waves.get(i));
    let (done, failed, total) = match wave {
        Some(w) => (w.done, w.failed, w.total),
        None => (0, 0, 0),
    };
    let active = state.in_flight.len();

    let label = if let Some(i) = state.current_wave {
        format!(
            "Wave {} {}/{}{}",
            i + 1,
            done,
            total,
            if active > 0 {
                format!(" (+{} waiting)", active)
            } else {
                String::new()
            },
        )
    } else {
        "Wave - 0/0".to_string()
    };
    let bar_area = draw_label_left(area, buf, &label, Style::default());
    if bar_area.width == 0 {
        return;
    }
    if total == 0 {
        // Nothing known yet — render a fully dim pending bar.
        draw_segmented_bar_cells(bar_area, buf, &[]);
        return;
    }

    // Allocate cells in priority order, then clamp so we never overflow
    // the bar. Done takes precedence over active which takes precedence
    // over failed — this ordering keeps the visual stable as counters
    // tick up during a wave.
    let width = bar_area.width;
    let done_cells = cells_for(done, total, width);
    let failed_cells = cells_for(failed, total, width).min(width - done_cells);
    let active_cells = cells_for(active, total, width).min(width - done_cells - failed_cells);

    draw_segmented_bar_cells(
        bar_area,
        buf,
        &[
            (done_cells, Color::White),
            (active_cells, Color::DarkGray),
            (failed_cells, Color::Red),
        ],
    );
}

fn render_in_flight(area: Rect, buf: &mut Buffer, state: &DeployState) {
    if state.in_flight.is_empty() {
        let msg = if state.finalized {
            "✓ deploy complete"
        } else if state.current_wave.is_none() {
            "waiting for first wave..."
        } else {
            "wave idle (all resources applied; waiting for next wave)"
        };
        Paragraph::new(Line::from(Span::styled(msg, style_dim()))).render(area, buf);
        return;
    }

    // One row per in-flight resource; truncate to fit the viewport.
    let max_rows = area.height as usize;
    let lines: Vec<Line> = state
        .in_flight
        .iter()
        .take(max_rows.saturating_sub(1))
        .map(|e| in_flight_line(e))
        .collect();

    let mut paragraph_lines = lines;
    if state.in_flight.len() > paragraph_lines.len() {
        let hidden = state.in_flight.len() - paragraph_lines.len();
        paragraph_lines.push(Line::from(Span::styled(
            format!("  … {} more", hidden),
            style_dim(),
        )));
    }
    Paragraph::new(paragraph_lines).render(area, buf);
}

fn in_flight_line(e: &InFlight) -> Line<'static> {
    let (symbol, symbol_style, status_text, status_style) = match e.state {
        ResourceState::WaitingReady => (
            "⏳",
            style_fg(Color::Blue),
            "waiting ready",
            style_fg(Color::Blue),
        ),
        ResourceState::Failed => ("✗", style_fg(Color::Red), "failed", style_fg(Color::Red)),
    };
    let elapsed = format_elapsed(e.started_at.elapsed());
    let mut spans = vec![
        Span::raw("  "),
        Span::styled(symbol.to_string(), symbol_style),
        Span::raw(" "),
        Span::raw(e.label.clone()),
        Span::raw("  "),
        Span::styled(status_text.to_string(), status_style),
        Span::raw("  "),
        Span::styled(elapsed, style_dim()),
    ];
    if let Some(detail) = &e.detail {
        spans.push(Span::raw("  "));
        spans.push(Span::styled(detail.clone(), style_dim()));
    }
    Line::from(spans)
}

fn render_footer(area: Rect, buf: &mut Buffer, state: &DeployState) {
    let remaining_waves = match state.current_wave {
        Some(i) if i + 1 < state.total_waves => state.total_waves - (i + 1),
        Some(_) => 0,
        None => state.total_waves,
    };
    // Queue accounting: resources not yet started = everything in waves
    // whose status is Pending (we don't know their totals yet, so we just
    // count waves) plus what's left in the current wave.
    let current_remaining = match state.current_wave.and_then(|i| state.waves.get(i)) {
        Some(w) => w
            .total
            .saturating_sub(w.done + state.in_flight.len() + w.failed),
        None => 0,
    };
    let text = if let Some(status) = &state.last_status {
        status.clone()
    } else if remaining_waves == 0 && current_remaining == 0 {
        "no work queued".to_string()
    } else if remaining_waves == 0 {
        format!("⏭ queued: {} resources in current wave", current_remaining)
    } else {
        format!(
            "⏭ queued: {} in current wave, {} more wave(s) after",
            current_remaining, remaining_waves,
        )
    };
    Paragraph::new(Line::from(Span::styled(text, style_dim()))).render(area, buf);
}

fn format_elapsed(d: Duration) -> String {
    let total = d.as_secs();
    let m = total / 60;
    let s = total % 60;
    format!("{:02}:{:02}", m, s)
}

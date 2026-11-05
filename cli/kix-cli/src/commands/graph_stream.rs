//! Interactive renderer for graph-streaming deploys.
//!
//! Consumes the [`DeployEvent`] stream from the scheduler and renders a live
//! tree grouped by Kix package (default) or namespace. Fold rules collapse
//! completed subtrees; a failure keeps its subtree expanded and pins a failure
//! frame at the top of the viewport.
//!
//! [`GraphStreamObserver`] forwards events over an mpsc channel without
//! drawing or blocking. A dedicated thread owns the terminal, updates
//! [`ViewState`], and redraws the inline viewport. Folded rows move into
//! terminal scrollback so completed work remains visible.

use std::collections::{HashMap, HashSet};
use std::io::{self, Stdout};
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
use kix::cluster::stream::{
    DeployEvent, DeployObserver, NodeDetail, NodeId, NodeMeta, TransitionKind, Verdict,
};

/// Poll cadence for elapsed-timer redraws even when no events arrive.
const TICK: Duration = Duration::from_millis(200);

/// Default fraction of terminal rows available to the inline viewport.
const DEFAULT_FOLD_FRACTION: f32 = 0.75;

/// Grouping axis for the tree view.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GroupAxis {
    /// Group resources by their `kix.run/package` label.
    Package,
    /// Group resources by Kubernetes namespace; cluster-scoped resources
    /// land under a synthetic `<cluster>` group.
    Namespace,
}

/// Glyph capabilities derived from NO_COLOR and terminal type.
#[derive(Debug, Clone, Copy)]
pub struct GlyphStyle {
    pub ascii: bool,
    pub color: bool,
}

impl GlyphStyle {
    pub fn detect() -> Self {
        let no_color = std::env::var_os("NO_COLOR").is_some();
        let dumb = std::env::var("TERM").map(|t| t == "dumb").unwrap_or(false);
        GlyphStyle {
            ascii: dumb,
            color: !no_color && !dumb,
        }
    }
}

#[allow(dead_code)]
pub fn is_supported() -> bool {
    crate::output::is_interactive()
}

#[derive(Clone)]
pub struct GraphStreamObserver {
    tx: Sender<Msg>,
}

impl DeployObserver for GraphStreamObserver {
    fn on_event(&self, event: &DeployEvent) {
        // The render thread owning the channel might have panicked during
        // teardown; an observer must not panic the scheduler when that happens.
        let _ = self.tx.send(Msg::Event(Box::new(event.clone())));
    }
}

/// Owns the render thread + input thread. Drop to shut down cleanly.
pub struct GraphStreamDriver {
    tx: Sender<Msg>,
    thread: Option<JoinHandle<()>>,
    input_thread: Option<JoinHandle<()>>,
    input_shutdown: Arc<AtomicBool>,
    trace_log_path: Option<std::path::PathBuf>,
}

impl GraphStreamDriver {
    pub fn spawn(
        cluster_name: String,
        cancel: CancelToken,
        fold_height: Option<u16>,
        axis: GroupAxis,
        glyph_style: GlyphStyle,
    ) -> io::Result<Self> {
        // Redirect tracing before taking over the screen because any
        // stderr write under the live viewport tears the ratatui rendering.
        let trace_log_path = {
            let path = std::env::temp_dir().join(format!("kix-tui-{}.log", std::process::id()));
            crate::trace_sink::redirect_to_file(&path)
                .ok()
                .map(|_| path)
        };

        enable_raw_mode()?;
        let mut stdout = io::stdout();
        execute!(stdout, cursor::Hide)?;

        let backend = CrosstermBackend::new(stdout);
        let viewport_height = fold_height
            .unwrap_or_else(initial_viewport_height)
            .saturating_add(1);
        let terminal = Terminal::with_options(
            backend,
            TerminalOptions {
                viewport: Viewport::Inline(viewport_height),
            },
        )?;

        let (tx, rx) = mpsc::channel::<Msg>();
        let state = ViewState::new(cluster_name, axis, glyph_style);

        let thread = thread::Builder::new()
            .name("kix-graph-stream".into())
            .spawn(move || run_ui(terminal, state, rx))?;

        let input_shutdown = Arc::new(AtomicBool::new(false));
        let input_shutdown_worker = input_shutdown.clone();
        let input_thread = thread::Builder::new()
            .name("kix-graph-stream-input".into())
            .spawn(move || input_loop(input_shutdown_worker, cancel))?;

        Ok(Self {
            tx,
            thread: Some(thread),
            input_thread: Some(input_thread),
            input_shutdown,
            trace_log_path,
        })
    }

    pub fn observer(&self) -> Arc<dyn DeployObserver> {
        Arc::new(GraphStreamObserver {
            tx: self.tx.clone(),
        })
    }
}

impl Drop for GraphStreamDriver {
    fn drop(&mut self) {
        let _ = self.tx.send(Msg::Shutdown);
        self.input_shutdown.store(true, Ordering::Release);
        if let Some(h) = self.thread.take() {
            let _ = h.join();
        }
        if let Some(h) = self.input_thread.take() {
            let _ = h.join();
        }
        let _ = disable_raw_mode();
        let _ = execute!(io::stdout(), cursor::Show);
        crate::trace_sink::restore_stderr();
        if let Some(path) = self.trace_log_path.take() {
            eprintln!("tui trace log: {}", path.display());
        }
    }
}

fn initial_viewport_height() -> u16 {
    let terminal_rows = crossterm::terminal::size().map(|(_, h)| h).unwrap_or(24);
    let fold = (terminal_rows as f32 * DEFAULT_FOLD_FRACTION).round() as u16;
    fold.clamp(10, 40)
}

enum Msg {
    Event(Box<DeployEvent>),
    Shutdown,
}

struct ViewState {
    cluster_name: String,
    axis: GroupAxis,
    glyph: GlyphStyle,
    started_at: Instant,
    finished: bool,
    stop_reason: Option<String>,
    finalized: Option<(String, Option<String>)>,
    /// The watchdog's latest "no progress" line, shown under the tree while
    /// the stall lasts; cleared by the next node event.
    stall: Option<String>,
    /// Best-effort writes that failed, listed in the footer at the end.
    warnings: Vec<String>,
    /// All nodes we know about, keyed by NodeId.
    nodes: HashMap<NodeId, NodeView>,
    /// Plan-time ordering, so the tree renders deterministically even before
    /// any nodes execute.
    plan_order: Vec<NodeId>,
    /// Reverse adjacency from predecessor to dependents for rendering cross-
    /// package references.
    dependents: HashMap<NodeId, Vec<NodeId>>,
    /// Forward adjacency from dependent to predecessors for cross-package ref
    /// discovery.
    predecessors: HashMap<NodeId, Vec<NodeId>>,
    /// Active grouping map (derived from axis). `groups` is the ordered list
    /// of group names; `group_nodes` maps each name to its member nodes.
    groups: Vec<String>,
    group_nodes: HashMap<String, Vec<NodeId>>,
    /// Nodes that land under the synthetic `<cluster>` (package axis:
    /// unowned; namespace axis: cluster-scoped).
    unowned: Vec<NodeId>,
    /// Running counts, computed incrementally.
    count_ready: usize,
    count_running: usize,
    count_pending: usize,
    count_failed: usize,
    count_cancelled: usize,
    /// The home group where each node anchors in the tree. Used to
    /// compute cross-group reference arrows.
    home_group: HashMap<NodeId, String>,
    /// Spanning-tree render order: `(node, depth)` pairs produced by DFS
    /// from DAG roots so each child appears directly under its parent at
    /// `parent.depth + 1`. Computed once at `PlanComputed`; every
    /// subsequent tick just iterates this list, filtering flushed rows.
    render_tree: Vec<(NodeId, usize)>,
}

struct NodeView {
    kind: TransitionKind,
    verdict: Verdict,
    meta: NodeMeta,
    /// Latest detail carried from mid-flight Running events (readiness
    /// progress, apply outcome) to the terminal event so the renderer can
    /// display a current status line.
    detail: Option<NodeDetail>,
    started_at: Instant,
    last_update: Instant,
    last_msg: Option<String>,
    /// Sticky record of the apply outcome. `detail` gets overwritten by
    /// subsequent ReadinessProgress events, so we copy the action out the
    /// first time Applied arrives and keep it for the scrollback emitter.
    applied_action: Option<ApplyAction>,
}

impl ViewState {
    fn new(cluster_name: String, axis: GroupAxis, glyph: GlyphStyle) -> Self {
        Self {
            cluster_name,
            axis,
            glyph,
            started_at: Instant::now(),
            finished: false,
            stop_reason: None,
            finalized: None,
            stall: None,
            warnings: Vec::new(),
            nodes: HashMap::new(),
            plan_order: Vec::new(),
            dependents: HashMap::new(),
            predecessors: HashMap::new(),
            groups: Vec::new(),
            group_nodes: HashMap::new(),
            unowned: Vec::new(),
            count_ready: 0,
            count_running: 0,
            count_pending: 0,
            count_failed: 0,
            count_cancelled: 0,
            home_group: HashMap::new(),
            render_tree: Vec::new(),
        }
    }

    /// Pick a node's home group based on the axis.
    fn group_of(axis: GroupAxis, meta: &NodeMeta) -> Option<String> {
        match axis {
            GroupAxis::Package => meta.package.clone(),
            GroupAxis::Namespace => meta.namespace.clone(),
        }
    }

    fn apply(&mut self, ev: DeployEvent) {
        match ev {
            DeployEvent::PlanComputed { nodes, edges } => {
                for plan_node in &nodes {
                    let home = Self::group_of(self.axis, &plan_node.meta)
                        .unwrap_or_else(|| "<cluster>".to_string());
                    self.home_group.insert(plan_node.id.clone(), home.clone());
                    self.plan_order.push(plan_node.id.clone());
                    self.nodes.insert(
                        plan_node.id.clone(),
                        NodeView {
                            kind: plan_node.kind,
                            verdict: Verdict::Pending,
                            meta: plan_node.meta.clone(),
                            detail: None,
                            started_at: Instant::now(),
                            last_update: Instant::now(),
                            last_msg: None,
                            applied_action: None,
                        },
                    );
                    self.count_pending += 1;

                    if let Some(grp) = Self::group_of(self.axis, &plan_node.meta) {
                        if !self.group_nodes.contains_key(&grp) {
                            self.groups.push(grp.clone());
                        }
                        self.group_nodes
                            .entry(grp)
                            .or_default()
                            .push(plan_node.id.clone());
                    } else {
                        self.unowned.push(plan_node.id.clone());
                    }
                }
                for (dep, pred) in edges {
                    self.dependents
                        .entry(pred.clone())
                        .or_default()
                        .push(dep.clone());
                    self.predecessors.entry(dep).or_default().push(pred);
                }
                // Build a spanning-tree render order by DFS from DAG roots.
                // plan_order is insertion order (not topological), so a
                // naive single-pass depth computation is wrong. Instead,
                // walk `dependents` edges downward so each node is emitted
                // directly under its parent. Nodes with multiple parents
                // anchor under whichever root reaches them first; the rest
                // of their predecessors surface as `└┄►` tails on the row.
                self.render_tree =
                    // Walk from sinks toward deps: roots are nodes that
                    // nothing else depends on (PackageInstances, top-level
                    // consumers); children are what they depend on.
                    compute_render_tree(&self.plan_order, &self.dependents, &self.predecessors);
            }
            DeployEvent::NodeStateChanged {
                node,
                kind,
                verdict,
                detail,
            } => {
                // Progress resumed; the watchdog stops repeating and so do we.
                self.stall = None;
                // For prune-phase synthetic Delete events, the node might not
                // be in plan_order. Insert it on demand so the renderer can
                // show it.
                let is_new = !self.nodes.contains_key(&node);
                if is_new {
                    self.plan_order.push(node.clone());
                    self.home_group.insert(node.clone(), "<prune>".to_string());
                    self.unowned.push(node.clone());
                    self.nodes.insert(
                        node.clone(),
                        NodeView {
                            kind,
                            verdict: Verdict::Pending,
                            meta: NodeMeta {
                                package: None,
                                namespace: None,
                                import_target: None,
                            },
                            detail: None,
                            started_at: Instant::now(),
                            last_update: Instant::now(),
                            last_msg: None,
                            applied_action: None,
                        },
                    );
                    self.count_pending += 1;
                }
                let entry = self.nodes.get_mut(&node).expect("node inserted above");

                let old = std::mem::replace(&mut entry.verdict, verdict.clone());
                entry.kind = kind;
                entry.last_update = Instant::now();
                // Reset the node's clock when it moves from Pending to Running
                // edge so the timer in the tree measures "time applying this
                // resource", not "time since deploy start".
                if matches!(old, Verdict::Pending) && matches!(verdict, Verdict::Running) {
                    entry.started_at = Instant::now();
                }
                // Apply detail (carried through mid-flight running events).
                if detail.is_some() {
                    entry.detail = detail.clone();
                    if let Some(msg) = detail_message(&detail) {
                        entry.last_msg = Some(msg);
                    }
                    if let Some(NodeDetail::Applied(action)) = &detail {
                        entry.applied_action = Some(action.clone());
                    }
                }

                // Update the aggregate counts reflecting the transition.
                adjust_counts(
                    &old,
                    &entry.verdict,
                    &mut self.count_ready,
                    &mut self.count_running,
                    &mut self.count_pending,
                    &mut self.count_failed,
                    &mut self.count_cancelled,
                );
            }
            DeployEvent::CrdRediscovery => {}
            DeployEvent::PruneStart { .. } => {}
            DeployEvent::PruneKept { reason, .. } => {
                self.warnings.push(format!("prune: {reason}"));
            }
            DeployEvent::Finalized {
                activation,
                previous,
            } => {
                self.finalized = Some((activation, previous));
            }
            DeployEvent::Stopped { reason } => {
                self.finished = true;
                self.stop_reason = Some(reason);
            }
            DeployEvent::Stalled {
                idle,
                in_flight,
                aborting,
            } => {
                let line = kix::cluster::watchdog::describe(idle, &in_flight);
                self.stall = Some(if aborting {
                    format!("{line}; giving up")
                } else {
                    line
                });
            }
            // The row of a running node already shows its timer and last
            // readiness message.
            DeployEvent::Waiting { .. } => {}
            DeployEvent::BestEffortFailed { what, message } => {
                self.warnings.push(format!("{what} failed: {message}"));
            }
            DeployEvent::FieldsNotKept { resource, fields } => {
                self.warnings.push(kix::cluster::kept::describe(
                    &resource.display_id(),
                    &fields,
                ));
            }
        }
    }
}

fn adjust_counts(
    from: &Verdict,
    to: &Verdict,
    ready: &mut usize,
    running: &mut usize,
    pending: &mut usize,
    failed: &mut usize,
    cancelled: &mut usize,
) {
    let bucket = |v: &Verdict| -> Bucket {
        match v {
            Verdict::Pending => Bucket::Pending,
            Verdict::Running => Bucket::Running,
            Verdict::Ready | Verdict::DriftDetected { .. } => Bucket::Ready,
            Verdict::Failed { .. } => Bucket::Failed,
            Verdict::Cancelled { .. } => Bucket::Cancelled,
            Verdict::AwaitingInput { .. } => Bucket::Running,
        }
    };
    let dec = |b: Bucket, c: &mut usize| {
        if *c > 0 {
            *c -= 1;
        }
        let _ = b;
    };
    match bucket(from) {
        Bucket::Pending => dec(Bucket::Pending, pending),
        Bucket::Running => dec(Bucket::Running, running),
        Bucket::Ready => dec(Bucket::Ready, ready),
        Bucket::Failed => dec(Bucket::Failed, failed),
        Bucket::Cancelled => dec(Bucket::Cancelled, cancelled),
    }
    match bucket(to) {
        Bucket::Pending => *pending += 1,
        Bucket::Running => *running += 1,
        Bucket::Ready => *ready += 1,
        Bucket::Failed => *failed += 1,
        Bucket::Cancelled => *cancelled += 1,
    }
}

#[derive(Copy, Clone)]
enum Bucket {
    Pending,
    Running,
    Ready,
    Failed,
    Cancelled,
}

fn detail_message(detail: &Option<NodeDetail>) -> Option<String> {
    match detail.as_ref()? {
        NodeDetail::Applied(action) => Some(apply_label(action).to_string()),
        NodeDetail::ReadinessProgress(msg) => Some(msg.clone()),
        NodeDetail::ApplyFailed(msg) => Some(msg.clone()),
        NodeDetail::ReadinessTimeout { message, .. } => Some(message.clone()),
        NodeDetail::ReadinessFailed { message, .. } => Some(message.clone()),
        NodeDetail::SecretHydrated { keys } => Some(format!("hydrated {keys} keys")),
        NodeDetail::SecretHydrationFailed(msg) => Some(msg.clone()),
        NodeDetail::RecreatedInPlace { .. } => {
            Some("recreated (immutable-field conflict)".to_string())
        }
        NodeDetail::Rerun { reason } => Some(format!("ran again ({reason})")),
        NodeDetail::PendingRestart { stale, .. } => {
            Some(format!("{stale} pods pending manual restart (OnDelete)"))
        }
    }
}

fn apply_label(action: &ApplyAction) -> &'static str {
    match action {
        ApplyAction::Created => "created",
        ApplyAction::Configured => "configured",
        ApplyAction::Unchanged => "unchanged",
        ApplyAction::Skipped => "skipped",
    }
}

fn run_ui(
    mut terminal: Terminal<CrosstermBackend<Stdout>>,
    mut state: ViewState,
    rx: mpsc::Receiver<Msg>,
) {
    // Rows already flushed to scrollback are never drawn in
    // the viewport again.
    let mut flushed: HashSet<NodeId> = HashSet::new();
    // Apply-phase scrollback tracking: ensures each node emits exactly one
    // `+ created` / `~ configured` line to history.
    let mut apply_flushed: HashSet<NodeId> = HashSet::new();
    let mut last_tick = Instant::now();

    loop {
        let now = Instant::now();
        let budget = TICK.saturating_sub(now.saturating_duration_since(last_tick));
        let msg = if budget.is_zero() {
            None
        } else {
            match rx.recv_timeout(budget) {
                Ok(m) => Some(m),
                Err(RecvTimeoutError::Timeout) => None,
                Err(RecvTimeoutError::Disconnected) => break,
            }
        };

        match msg {
            Some(Msg::Event(ev)) => {
                state.apply(*ev);
            }
            Some(Msg::Shutdown) => break,
            None => {}
        }

        // Drain any queued messages without blocking.
        while let Ok(m) = rx.try_recv() {
            match m {
                Msg::Event(ev) => state.apply(*ev),
                Msg::Shutdown => {
                    render_once(&mut terminal, &state, &mut flushed, &mut apply_flushed);
                    return;
                }
            }
        }

        if last_tick.elapsed() >= TICK {
            last_tick = Instant::now();
        }

        render_once(&mut terminal, &state, &mut flushed, &mut apply_flushed);
    }

    // Final repaint before exit.
    render_once(&mut terminal, &state, &mut flushed, &mut apply_flushed);
}

fn render_once(
    terminal: &mut Terminal<CrosstermBackend<Stdout>>,
    state: &ViewState,
    flushed: &mut HashSet<NodeId>,
    apply_flushed: &mut HashSet<NodeId>,
) {
    // Decide which completed rows to flush to scrollback so they become
    // terminal history above the live viewport. Two classes: apply-phase
    // events (created/configured) and Ready terminal events.
    let flush_lines = build_flush_lines(state, flushed, apply_flushed);
    if !flush_lines.is_empty() {
        let count = flush_lines.len() as u16;
        let _ = terminal.insert_before(count, |buf| {
            for (i, line) in flush_lines.into_iter().enumerate() {
                let area = Rect::new(buf.area.x, buf.area.y + i as u16, buf.area.width, 1);
                Paragraph::new(line).render(area, buf);
            }
        });
    }

    let _ = terminal.draw(|frame| {
        let area = frame.area();
        let outer = Layout::default()
            .direction(ratatui::layout::Direction::Vertical)
            .constraints([
                Constraint::Length(1),
                Constraint::Length(1),
                Constraint::Min(0),
            ])
            .split(area);
        render_divider(outer[0], frame.buffer_mut());
        render_header(outer[1], frame.buffer_mut(), state);
        render_tree(outer[2], frame.buffer_mut(), state, flushed);
    });
}

fn render_divider(area: Rect, buf: &mut Buffer) {
    let rule: String = "─".repeat(area.width as usize);
    Paragraph::new(Line::from(Span::styled(
        rule,
        Style::default().fg(Color::DarkGray),
    )))
    .render(area, buf);
}

fn render_header(area: Rect, buf: &mut Buffer, state: &ViewState) {
    let elapsed = state.started_at.elapsed();
    let status = if state.finished {
        if state.count_failed > 0 {
            Span::styled(
                "FAILED",
                Style::default().fg(Color::Red).add_modifier(Modifier::BOLD),
            )
        } else {
            Span::styled("done", Style::default().fg(Color::Green))
        }
    } else {
        Span::styled("Deploying", Style::default().fg(Color::Yellow))
    };
    let spans = vec![
        Span::styled(
            format!("Activation: {} ", state.cluster_name),
            Style::default().add_modifier(Modifier::BOLD),
        ),
        status,
        Span::raw("   "),
        Span::styled(
            format!("{} ✔ · ", state.count_ready),
            Style::default().fg(Color::Green),
        ),
        Span::styled(
            format!("{} ⏵ · ", state.count_running),
            Style::default().fg(Color::Yellow),
        ),
        Span::styled(
            format!("{} ⏸ · ", state.count_pending),
            Style::default().fg(Color::Blue),
        ),
        Span::styled(
            format!("{} ⚠ · ", state.count_failed),
            Style::default().fg(if state.count_failed > 0 {
                Color::Red
            } else {
                Color::DarkGray
            }),
        ),
        Span::styled(
            format!("{} ⊘", state.count_cancelled),
            Style::default().fg(Color::DarkGray),
        ),
        Span::raw("   "),
        Span::styled(
            format!("elapsed {}", format_elapsed(elapsed)),
            Style::default().fg(Color::DarkGray),
        ),
    ];
    Paragraph::new(Line::from(spans)).render(area, buf);
}

fn render_tree(area: Rect, buf: &mut Buffer, state: &ViewState, flushed: &HashSet<NodeId>) {
    let lines = build_tree_lines(state, flushed);
    Paragraph::new(lines).render(area, buf);
}

/// Compute the tree lines for the live viewport. Skip nodes already flushed
/// to scrollback, fold completed all-Ready packages, keep failed subtrees
/// expanded.
fn build_tree_lines(state: &ViewState, flushed: &HashSet<NodeId>) -> Vec<Line<'static>> {
    let mut lines: Vec<Line<'static>> = Vec::new();

    // Pin failures at the top of the viewport.
    if state.count_failed > 0 {
        let mut frame: Vec<Line<'static>> = Vec::new();
        frame.push(Line::from(vec![Span::styled(
            "⚠ failures",
            Style::default().fg(Color::Red).add_modifier(Modifier::BOLD),
        )]));
        for id in &state.plan_order {
            if flushed.contains(id) {
                continue;
            }
            let Some(node) = state.nodes.get(id) else {
                continue;
            };
            if !matches!(
                node.verdict,
                Verdict::Failed { .. } | Verdict::Cancelled { .. }
            ) {
                continue;
            }
            frame.push(node_line(id, node, state, 1));
        }
        if frame.len() > 1 {
            lines.extend(frame);
            lines.push(Line::from(""));
        }
    }

    // StoreGraph rendering: iterate the precomputed spanning-tree order so
    // each child renders immediately under its parent at depth+1.
    //
    // Visibility rules:
    //   - Ready rows are hidden (they're in scrollback already).
    //   - Failed / Cancelled rows render here too; the failure frame above
    //     is a duplicated pin, not a replacement.
    //   - Pending parents whose entire subtree is also pending collapse
    //     with a `(+N pending)` tail; their children are not drawn.
    //   - When a pending parent has active descendants it renders with a
    //     marker to show that active work exists below it.
    //   - Under every expanded parent, any direct child whose own subtree
    //     has no active work (pending leaves + all-pending branches) is
    //     aggregated into a single synthetic `⏸ (+N pending)` sibling line
    //     instead of being drawn individually. Keeps the viewport focused
    //     on what's actually moving.
    let subtree_info = compute_subtree_info(&state.render_tree, &state.nodes, flushed);
    let mut i = 0;
    while i < state.render_tree.len() {
        i = render_tree_node(&mut lines, i, state, flushed, &subtree_info);
    }

    // Render deploy-wide status below the tree.
    if let Some(stall) = &state.stall {
        lines.push(Line::from(""));
        lines.push(Line::from(vec![Span::styled(
            format!("⚠ {stall}"),
            Style::default().fg(Color::Yellow),
        )]));
    }
    if state.finished {
        lines.push(Line::from(""));
        for warning in &state.warnings {
            lines.push(Line::from(vec![Span::styled(
                format!("⚠ {warning}"),
                Style::default().fg(Color::Yellow),
            )]));
        }
        if let Some(reason) = &state.stop_reason {
            lines.push(Line::from(vec![Span::styled(
                format!("✗ {reason}"),
                Style::default().fg(Color::Red),
            )]));
        }
        if let Some((new, prev)) = &state.finalized {
            if let Some(p) = prev {
                lines.push(Line::from(vec![
                    Span::styled("• ", Style::default().add_modifier(Modifier::DIM)),
                    Span::raw(format!("activation '{p}' → Superseded")),
                ]));
            }
            lines.push(Line::from(vec![
                Span::styled("• ", Style::default().fg(Color::Green)),
                Span::raw(format!("activation '{new}' → Active")),
            ]));
        }
    }

    lines
}

/// Render a single node row with indent, glyph, tag, label, and status tail.
fn node_line(id: &NodeId, node: &NodeView, state: &ViewState, depth: usize) -> Line<'static> {
    node_line_with_tail(id, node, state, depth, None, None)
}

/// Recursively render a subtree rooted at `i` into `lines`, applying the
/// viewport's collapse rules. Returns the index of the next-to-process node
/// (i.e. the end of this subtree), so the top-level loop can just iterate.
fn render_tree_node(
    lines: &mut Vec<Line<'static>>,
    i: usize,
    state: &ViewState,
    flushed: &HashSet<NodeId>,
    subtree_info: &[SubtreeInfo],
) -> usize {
    let (id, depth) = &state.render_tree[i];
    let info = &subtree_info[i];
    let end = info.subtree_end;

    if flushed.contains(id) {
        return end;
    }
    let Some(node) = state.nodes.get(id) else {
        return end;
    };

    let indent = 1 + (*depth).min(12);
    let is_pending = matches!(node.verdict, Verdict::Pending);
    let has_visible_desc = info.visible_descendants > 0;

    // Whole-subtree collapse: a pending node whose subtree carries no
    // active work either. Render one line with a `(+N pending)` tail and
    // skip every descendant.
    if is_pending && !info.has_active && has_visible_desc {
        lines.push(node_line_with_tail(
            id,
            node,
            state,
            indent,
            None,
            Some(format!("(+{} pending)", info.visible_descendants)),
        ));
        return end;
    }

    // Otherwise render the parent row. Paint ▼ in place of ⏸ when we're
    // drilling through a pending node because real work lives below.
    let glyph_override = if is_pending && info.has_active {
        Some(("▼", "v"))
    } else {
        None
    };
    lines.push(node_line_with_tail(
        id,
        node,
        state,
        indent,
        glyph_override,
        None,
    ));

    // Walk direct children. Aggregate any "idle" ones (pending self and no
    // active descendants) into a single rollup line emitted after the real
    // children. Children with any active work recurse normally so their
    // own subtrees get the same treatment.
    let mut pending_rollup: usize = 0;
    let mut j = i + 1;
    while j < end {
        let (cid, _) = &state.render_tree[j];
        let cinfo = &subtree_info[j];
        if flushed.contains(cid) {
            j = cinfo.subtree_end;
            continue;
        }
        let cnode = state.nodes.get(cid);
        let child_self_active = cnode
            .map(|n| !matches!(n.verdict, Verdict::Pending | Verdict::Ready))
            .unwrap_or(false);
        let child_has_active = child_self_active || cinfo.has_active;

        if !child_has_active {
            // Roll the child + its visible descendants into the counter.
            pending_rollup += 1 + cinfo.visible_descendants;
            j = cinfo.subtree_end;
        } else {
            j = render_tree_node(lines, j, state, flushed, subtree_info);
        }
    }

    if pending_rollup > 0 {
        let child_indent = 1 + (*depth + 1).min(12);
        let (glyph, _) = glyph_for(&Verdict::Pending, state.glyph);
        lines.push(Line::from(vec![
            Span::raw(" ".repeat(child_indent * 2)),
            Span::styled(format!("{glyph} "), Style::default().fg(Color::Blue)),
            Span::styled(
                format!("(+{pending_rollup} pending)"),
                Style::default().add_modifier(Modifier::DIM),
            ),
        ]));
    }

    end
}

/// Render a single node row with optional glyph override and suffix tail.
///
/// The glyph override paints `▼` on a pending parent that wraps active
/// descendants, and the suffix appends `(+N pending)` on a collapsed
/// pending-only subtree.
fn node_line_with_tail(
    id: &NodeId,
    node: &NodeView,
    state: &ViewState,
    depth: usize,
    glyph_override: Option<(&'static str, &'static str)>,
    extra_tail: Option<String>,
) -> Line<'static> {
    let indent = " ".repeat(depth * 2);
    let (glyph, glyph_style) = match glyph_override {
        Some((unicode, ascii)) => {
            let g = if state.glyph.ascii { ascii } else { unicode };
            // Mute the pending parent marker so active descendants own the color.
            let style = Style::default().add_modifier(Modifier::DIM);
            (g, style)
        }
        None => glyph_for(&node.verdict, state.glyph),
    };
    let tag = node.kind.tag().map(|t| format!("{t} ")).unwrap_or_default();

    // Tree rows use short labels because the parent PackageInstance
    // already provides that context. Scrollback keeps the qualified form.
    let label = node_label_short(id, &node.meta);
    let elapsed = node.last_update.saturating_duration_since(node.started_at);
    let timer = match node.verdict {
        Verdict::Running => format!("  ⏱ {}", format_elapsed(node.started_at.elapsed())),
        Verdict::Ready if elapsed.as_millis() > 100 => {
            format!("  {}", format_elapsed(elapsed))
        }
        _ => String::new(),
    };
    // Strip the readiness-progress prefix when it duplicates the row label.
    // Pollers include the resource name in messages; the
    // leading "Kind/name:" is redundant with the row itself.
    let msg = node
        .last_msg
        .as_deref()
        .map(|m| strip_resource_prefix(m, id))
        .filter(|m| !m.is_empty())
        .map(|m| format!("  {}", m))
        .unwrap_or_default();

    let mut spans = vec![
        Span::raw(indent),
        Span::styled(format!("{glyph} "), glyph_style),
    ];
    if !tag.is_empty() {
        spans.push(Span::styled(tag, Style::default().fg(Color::Magenta)));
    }
    spans.push(Span::raw(label));
    if !timer.is_empty() {
        spans.push(Span::styled(
            timer,
            Style::default().add_modifier(Modifier::DIM),
        ));
    }
    if !msg.is_empty() {
        spans.push(Span::styled(
            msg,
            Style::default().add_modifier(Modifier::DIM),
        ));
    }
    if let Some(tail) = extra_tail {
        spans.push(Span::styled(
            format!("  {tail}"),
            Style::default().add_modifier(Modifier::DIM),
        ));
    }
    Line::from(spans)
}

/// Per-node subtree metadata derived from the flat DFS `render_tree`. For
/// each index `i`, `subtree_end` is the exclusive end of i's subtree in
/// tree order (children are `(i+1)..subtree_end`); `has_active` flags any
/// non-flushed, non-pending descendant so we know whether to collapse the
/// subtree when the parent is pending; `visible_descendants` counts the
/// non-flushed pending descendants that would be hidden by a collapse, so
/// we can surface `(+N)` on the parent row.
struct SubtreeInfo {
    subtree_end: usize,
    has_active: bool,
    visible_descendants: usize,
}

fn compute_subtree_info(
    render_tree: &[(NodeId, usize)],
    nodes: &HashMap<NodeId, NodeView>,
    flushed: &HashSet<NodeId>,
) -> Vec<SubtreeInfo> {
    let n = render_tree.len();
    // Two single-pass sweeps: one forward to close subtree bounds via a
    // monotonic depth stack, one backward to fold child flags upward.
    let mut subtree_end = vec![n; n];
    let mut stack: Vec<usize> = Vec::new();
    for i in 0..n {
        let d = render_tree[i].1;
        while let Some(&top) = stack.last() {
            if render_tree[top].1 >= d {
                subtree_end[top] = i;
                stack.pop();
            } else {
                break;
            }
        }
        stack.push(i);
    }

    let mut info: Vec<SubtreeInfo> = (0..n)
        .map(|_| SubtreeInfo {
            subtree_end: n,
            has_active: false,
            visible_descendants: 0,
        })
        .collect();
    for i in 0..n {
        info[i].subtree_end = subtree_end[i];
    }

    // Scan the full descendant range per parent. O(sum of subtree depths),
    // which in practice is well under a millisecond for deploys under a
    // few thousand nodes, within the 200ms tick cadence.
    for (i, entry) in info.iter_mut().enumerate() {
        let end = entry.subtree_end;
        let mut any_active = false;
        let mut visible = 0usize;
        for (cid, _) in &render_tree[(i + 1)..end] {
            if flushed.contains(cid) {
                continue;
            }
            visible += 1;
            if let Some(node) = nodes.get(cid)
                && !matches!(node.verdict, Verdict::Pending | Verdict::Ready)
            {
                any_active = true;
            }
        }
        entry.has_active = any_active;
        entry.visible_descendants = visible;
    }

    info
}

/// Produce a DFS spanning-tree over the deploy DAG for display.
///
/// Roots are nodes with no `incoming_for_roots` entries, typically
/// `PackageInstance` resources that nothing else consumes. Walks `walk_edges`
/// downward, emitting each node once at its DFS depth. Nodes reachable through
/// multiple paths anchor under whichever root reached them first.
///
/// Uses an explicit stack so deep DAGs do not overflow the call stack. Edges
/// are popped in stored order for deterministic output across runs.
fn compute_render_tree(
    plan_order: &[NodeId],
    incoming_for_roots: &HashMap<NodeId, Vec<NodeId>>,
    walk_edges: &HashMap<NodeId, Vec<NodeId>>,
) -> Vec<(NodeId, usize)> {
    let mut out = Vec::with_capacity(plan_order.len());
    let mut visited: HashSet<NodeId> = HashSet::new();

    for id in plan_order {
        let is_root = incoming_for_roots
            .get(id)
            .map(|v| v.is_empty())
            .unwrap_or(true);
        if !is_root || visited.contains(id) {
            continue;
        }
        dfs_emit(id, walk_edges, &mut visited, &mut out);
    }

    // Defensive sweep: any node not reached from a root (cycle / partial
    // plan). Emit leftovers at depth 0 so nothing vanishes.
    for id in plan_order {
        if visited.contains(id) {
            continue;
        }
        dfs_emit(id, walk_edges, &mut visited, &mut out);
    }

    out
}

fn dfs_emit(
    root: &NodeId,
    walk_edges: &HashMap<NodeId, Vec<NodeId>>,
    visited: &mut HashSet<NodeId>,
    out: &mut Vec<(NodeId, usize)>,
) {
    let mut stack: Vec<(NodeId, usize)> = vec![(root.clone(), 0)];
    while let Some((id, depth)) = stack.pop() {
        if !visited.insert(id.clone()) {
            continue;
        }
        out.push((id.clone(), depth));
        if let Some(next) = walk_edges.get(&id) {
            // Push in reverse so siblings pop in their stored order.
            for child in next.iter().rev() {
                if !visited.contains(child) {
                    stack.push((child.clone(), depth + 1));
                }
            }
        }
    }
}

fn node_label(id: &NodeId, meta: &NodeMeta) -> String {
    match id {
        NodeId::Resource(rid) => {
            if let Some(target) = &meta.import_target {
                format!("↪ import {}/{}", target.kind, target.name)
            } else {
                rid.to_string()
            }
        }
        NodeId::Synthetic(s) => format!("⟦{s}⟧"),
    }
}

/// Format a shorter node label for the live tree.
///
/// Drops the `@namespace` suffix because the parent `PackageInstance` row
/// already carries that context. Scrollback history uses [`node_label`]
/// instead.
fn node_label_short(id: &NodeId, meta: &NodeMeta) -> String {
    match id {
        NodeId::Resource(rid) => {
            if let Some(target) = &meta.import_target {
                format!("↪ import {}/{}", target.kind, target.name)
            } else {
                format!("{}/{}", rid.kind, rid.name)
            }
        }
        NodeId::Synthetic(s) => format!("⟦{s}⟧"),
    }
}

/// Drop a leading `Kind/name:` or `Kind/name@ns:` prefix from readiness
/// messages so we don't duplicate the row's own label. Leaves other
/// messages untouched.
fn strip_resource_prefix(msg: &str, id: &NodeId) -> String {
    let NodeId::Resource(rid) = id else {
        return msg.to_string();
    };
    let candidates = [
        format!("{}/{}@{}: ", rid.kind, rid.name, rid.namespace),
        format!("{}/{}: ", rid.kind, rid.name),
    ];
    for prefix in &candidates {
        if let Some(stripped) = msg.strip_prefix(prefix.as_str()) {
            return stripped.to_string();
        }
    }
    msg.to_string()
}

/// Build the rows to flush into terminal scrollback on this tick.
///
/// Every `Ready` resource is flushed as soon as it completes, so the live
/// viewport shows only in-flight, pending, or failed work. Failed subtrees are
/// never flushed and remain pinned in the viewport until the deploy ends.
fn build_flush_lines(
    state: &ViewState,
    flushed: &mut HashSet<NodeId>,
    apply_flushed: &mut HashSet<NodeId>,
) -> Vec<Line<'static>> {
    let mut out = Vec::new();

    // Emit an apply-phase history line on the first tick after a node's apply
    // phase completes. `applied_action` is sticky, so each resource produces
    // at most one apply line even when `detail` is later overwritten by
    // `ReadinessProgress` events.
    for id in &state.plan_order {
        if apply_flushed.contains(id) {
            continue;
        }
        let Some(node) = state.nodes.get(id) else {
            continue;
        };
        let Some(action) = node.applied_action.as_ref() else {
            continue;
        };
        if matches!(action, ApplyAction::Unchanged | ApplyAction::Skipped) {
            apply_flushed.insert(id.clone());
            continue;
        }
        out.push(apply_history_line(id, node, action, state));
        apply_flushed.insert(id.clone());
    }

    // Flush every newly Ready node in `plan_order` so history stays deterministic.
    let mut newly_flushed: Vec<NodeId> = Vec::new();
    for id in &state.plan_order {
        if flushed.contains(id) {
            continue;
        }
        let Some(node) = state.nodes.get(id) else {
            continue;
        };
        // Cancelled, Failed, and DriftDetected nodes stay visible in the viewport.
        if !matches!(node.verdict, Verdict::Ready) {
            continue;
        }
        if matches!(node.kind, TransitionKind::Skip) {
            newly_flushed.push(id.clone());
            continue;
        }
        out.push(resource_history_line(id, node, state));
        newly_flushed.push(id.clone());
    }
    for id in newly_flushed {
        flushed.insert(id);
    }

    out
}

/// Format the scrollback line emitted when a resource finishes its apply phase.
///
/// Uses the same apply glyphs as `StreamCliObserver` so TUI scrollback matches
/// plain-log output.
fn apply_history_line(
    id: &NodeId,
    node: &NodeView,
    action: &ApplyAction,
    state: &ViewState,
) -> Line<'static> {
    let (glyph, label_str, style) = match action {
        ApplyAction::Created => ("+", "created", Style::default()),
        ApplyAction::Configured => ("~", "configured", Style::default().fg(Color::Yellow)),
        ApplyAction::Unchanged => (
            "=",
            "unchanged",
            Style::default().add_modifier(Modifier::DIM),
        ),
        ApplyAction::Skipped => ("-", "skipped", Style::default().add_modifier(Modifier::DIM)),
    };
    let pkg_prefix = state
        .home_group
        .get(id)
        .filter(|g| g.as_str() != "<cluster>" && g.as_str() != "<prune>")
        .map(|g| format!("{g}/"))
        .unwrap_or_default();
    let label = node_label(id, &node.meta);
    Line::from(vec![
        Span::styled(format!("{glyph} "), style),
        Span::raw(format!("{pkg_prefix}{label}  ")),
        Span::styled(
            label_str.to_string(),
            Style::default().add_modifier(Modifier::DIM),
        ),
    ])
}

/// Format a one-line scrollback summary for a completed resource.
fn resource_history_line(id: &NodeId, node: &NodeView, state: &ViewState) -> Line<'static> {
    let (glyph, glyph_style) = glyph_for(&node.verdict, state.glyph);
    let pkg_prefix = state
        .home_group
        .get(id)
        .filter(|g| g.as_str() != "<cluster>" && g.as_str() != "<prune>")
        .map(|g| format!("{g}/"))
        .unwrap_or_default();
    let label = node_label(id, &node.meta);
    let elapsed = node.last_update.saturating_duration_since(node.started_at);
    let timer = if elapsed.as_millis() > 100 {
        format!("  {}", format_elapsed(elapsed))
    } else {
        String::new()
    };
    let mut spans = vec![
        Span::styled(format!("{glyph} "), glyph_style),
        Span::raw(format!("{pkg_prefix}{label}")),
    ];
    if !timer.is_empty() {
        spans.push(Span::styled(
            timer,
            Style::default().add_modifier(Modifier::DIM),
        ));
    }
    Line::from(spans)
}

fn glyph_for(v: &Verdict, style: GlyphStyle) -> (&'static str, Style) {
    // Palette intent: color only when the state is actively interesting
    // (Running, Failed, Awaiting, Drift, Ready). Pending and Cancelled
    // render dim-grey so the eye is drawn to in-flight / finished work.
    let (unicode, ascii, color_style) = match v {
        Verdict::Pending => ("⏸", ".", Style::default().add_modifier(Modifier::DIM)),
        Verdict::Running => ("⏵", ">", Style::default().fg(Color::Yellow)),
        Verdict::Ready => ("✔", "v", Style::default().fg(Color::Green)),
        Verdict::Failed { .. } => ("⚠", "!", Style::default().fg(Color::Red)),
        Verdict::Cancelled { .. } => ("⊘", "x", Style::default().add_modifier(Modifier::DIM)),
        Verdict::AwaitingInput { .. } => ("⏯", "?", Style::default().fg(Color::Cyan)),
        Verdict::DriftDetected { .. } => ("↻", "~", Style::default().fg(Color::Yellow)),
    };
    let glyph = if style.ascii { ascii } else { unicode };
    let base = if style.color {
        color_style
    } else {
        Style::default().add_modifier(Modifier::BOLD)
    };
    (glyph, base)
}

fn input_loop(shutdown: Arc<AtomicBool>, cancel: CancelToken) {
    while !shutdown.load(Ordering::Acquire) {
        if let Ok(true) = event::poll(Duration::from_millis(100))
            && let Ok(Event::Key(k)) = event::read()
            && k.kind == KeyEventKind::Press
        {
            let is_ctrl_c = k.code == KeyCode::Char('c') && k.modifiers == KeyModifiers::CONTROL;
            let is_esc = k.code == KeyCode::Esc;
            if is_ctrl_c || is_esc {
                cancel.cancel();
            }
        }
    }
}

fn format_elapsed(d: Duration) -> String {
    let secs = d.as_secs();
    if secs < 60 {
        format!("{secs}s")
    } else {
        let m = secs / 60;
        let s = secs % 60;
        format!("{m}m{s:02}s")
    }
}

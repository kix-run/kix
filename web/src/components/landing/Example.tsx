import { useState } from "react";
import type { ReactNode } from "react";
import { Tabs } from "radix-ui";
import { ShieldCheck } from "lucide-react";
import { AgentToggle } from "@/components/landing/Hero";
import {
  Container,
  Reveal,
  SectionHeading,
} from "@/components/landing/primitives";

// Hand-tokenized nix, expressed as data. Token classes mirror the hero
// card: keys, values, punctuation, comments, references.
type Tok = { t: string; c?: "k" | "v" | "p" | "c" | "r" };
// A line is its tokens plus an optional `dim` flag. Dimmed lines are code
// carried over unchanged from an earlier tab; they render knocked back so
// the new/changed lines in this tab stand out.
type CodeLine = { toks: Tok[]; dim?: boolean };

// One line of the "coding agent" view. `action` lines (the agent doing
// something) render italic so they read as narration, not real output.
type AgentLine = { t: string; tone: "prompt" | "action" | "bad" | "good" };

const tokClass: Record<NonNullable<Tok["c"]>, string> = {
  k: "text-zinc-300",
  v: "text-(--brand-on-dark)",
  p: "text-zinc-500",
  c: "text-zinc-500 italic",
  r: "text-[#86bbd8]",
};

// Shorthand constructors keep the line data readable.
const k = (t: string): Tok => ({ t, c: "k" });
const v = (t: string): Tok => ({ t, c: "v" });
const p = (t: string): Tok => ({ t, c: "p" });
const c = (t: string): Tok => ({ t, c: "c" });
const r = (t: string): Tok => ({ t, c: "r" });

// Line constructors: `line` is new/changed code (full emphasis), `dim` is
// code carried over unchanged from a previous tab (knocked into the back).
const line = (...toks: Tok[]): CodeLine => ({ toks });
const dim = (...toks: Tok[]): CodeLine => ({ toks, dim: true });

const stackLines: CodeLine[] = [
  line(k("instances.app"), p(" = {")),
  line(k("  api"), p(" = {")),
  line(k("    package"), p(" = "), r("packages.app"), p(";")),
  line(k("    config"), p(" = {")),
  line(k("      image"), p(" = "), v('"ghcr.io/acme-co/api:v2.1.0"'), p(";")),
  line(k("      env.DATABASE_HOST"), p(" = "), r("postgres.out.fqdn"), p(";")),
  line(k("      env.CACHE_HOST"), p("    = "), r("cache.out.fqdn"), p(";")),
  line(k("      ingress.host"), p("      = "), v('"api.acme.co"'), p(";")),
  line(p("    };")),
  line(p("  };")),
  line(),
  line(k("  worker"), p(" = {")),
  line(k("    package"), p(" = "), r("packages.app"), p(";")),
  line(
    k("    config.image"),
    p(" = "),
    v('"ghcr.io/acme-co/worker:v2.1.0"'),
    p(";"),
  ),
  line(
    k("    config.env.DATABASE_HOST"),
    p(" = "),
    r("postgres.out.fqdn"),
    p(";"),
  ),
  line(p("  };")),
  line(),
  line(k("  postgres"), p(" = {")),
  line(k("    package"), p(" = "), r("packages.postgres"), p(";")),
  line(
    k("    config.extensions"),
    p(" = [ "),
    v('"vector"'),
    p(" ];"),
    c("  # the api's embeddings"),
  ),
  line(k("    config.backup.enabled"), p(" = "), v("true"), p(";")),
  line(p("  };")),
  line(),
  line(
    k("  cache"),
    p(" = { "),
    k("package"),
    p(" = "),
    r("packages.redis"),
    p("; };"),
  ),
  line(p("};")),
];

const controlLines: CodeLine[] = [
  line(c("# The same cluster.nix, a few months on: the defaults are now")),
  line(c("# decisions, made where production demanded them.")),
  dim(k("instances.app"), p(" = {")),
  dim(k("  api"), p(" = {")),
  dim(k("    package"), p(" = "), r("packages.app"), p(";")),
  dim(k("    config"), p(" = {")),
  line(
    k("      image"),
    p(" = "),
    v('"ghcr.io/acme-co/api:v2.4.1"'),
    p(";"),
    c("  # was v2.1.0"),
  ),
  line(
    k("      replicas"),
    p(" = "),
    v("6"),
    p(";"),
    c("  # was the default: 2"),
  ),
  line(
    k("      resources.requests"),
    p(" = { "),
    k("cpu"),
    p(" = "),
    v('"500m"'),
    p("; "),
    k("memory"),
    p(" = "),
    v('"1Gi"'),
    p("; };"),
  ),
  dim(k("      env.DATABASE_HOST"), p(" = "), r("postgres.out.fqdn"), p(";")),
  dim(k("      env.CACHE_HOST"), p("    = "), r("cache.out.fqdn"), p(";")),
  dim(k("      ingress.host"), p("      = "), v('"api.acme.co"'), p(";")),
  dim(p("    };")),
  dim(p("  };")),
  line(),
  dim(k("  worker"), p(" = {")),
  dim(k("    package"), p(" = "), r("packages.app"), p(";")),
  dim(
    k("    config.image"),
    p(" = "),
    v('"ghcr.io/acme-co/worker:v2.1.0"'),
    p(";"),
  ),
  dim(
    k("    config.env.DATABASE_HOST"),
    p(" = "),
    r("postgres.out.fqdn"),
    p(";"),
  ),
  dim(p("  };")),
  line(),
  dim(k("  postgres"), p(" = {")),
  dim(k("    package"), p(" = "), r("packages.postgres"), p(";")),
  dim(
    k("    config.extensions"),
    p(" = [ "),
    v('"vector"'),
    p(" ];"),
    c("  # the api's embeddings"),
  ),
  line(
    k("    config.postgres.version"),
    p(" = "),
    v('"18"'),
    p(";"),
    c("  # pin the major; opt in to upgrades"),
  ),
  line(k("    config.instances"), p(" = "), v("2"), p(";"), c("  # HA pair")),
  line(
    k("    config.storage.size"),
    p(" = "),
    v('"200Gi"'),
    p(";"),
    c("  # was 20Gi"),
  ),
  line(
    k("    config.instanceProfile"),
    p(" = { "),
    k("cpu"),
    p(" = "),
    v('"4"'),
    p("; "),
    k("memory"),
    p(" = "),
    v('"8Gi"'),
    p("; };"),
  ),
  dim(k("    config.backup.enabled"), p(" = "), v("true"), p(";")),
  line(k("    config.backup.schedule"), p(" = "), v('"0 3 * * *"'), p(";")),
  dim(p("  };")),
  line(),
  dim(k("  cache"), p(" = {")),
  dim(k("    package"), p(" = "), r("packages.redis"), p(";")),
  line(
    k("    config.auth.secretSource"),
    p(" = "),
    v("./secrets/redis.yaml"),
    p(";"),
    c("  # encrypted"),
  ),
  dim(p("  };")),
  dim(p("};")),
];

const manifestLines: CodeLine[] = [
  line(c("# Still the same stack. The team wants tracing, and Kix has no")),
  line(c("# tracing package: so they bring a Helm chart and patch what it")),
  line(c("# generates, in the same file as everything else.")),
  dim(k("instances.app"), p(" = {")),
  dim(k("  api"), p(" = {")),
  dim(k("    package"), p(" = "), r("packages.app"), p(";")),
  dim(k("    config"), p(" = {")),
  dim(k("      image"), p(" = "), v('"ghcr.io/acme-co/api:v2.4.1"'), p(";")),
  dim(k("      replicas"), p(" = "), v("6"), p(";")),
  dim(
    k("      resources.requests"),
    p(" = { "),
    k("cpu"),
    p(" = "),
    v('"500m"'),
    p("; "),
    k("memory"),
    p(" = "),
    v('"1Gi"'),
    p("; };"),
  ),
  dim(k("      env.DATABASE_HOST"), p(" = "), r("postgres.out.fqdn"), p(";")),
  dim(k("      env.CACHE_HOST"), p("    = "), r("cache.out.fqdn"), p(";")),
  dim(k("      ingress.host"), p("      = "), v('"api.acme.co"'), p(";")),
  dim(p("    };")),
  dim(p("  };")),
  line(),
  dim(k("  worker"), p(" = {")),
  dim(k("    package"), p(" = "), r("packages.app"), p(";")),
  dim(
    k("    config.image"),
    p(" = "),
    v('"ghcr.io/acme-co/worker:v2.1.0"'),
    p(";"),
  ),
  dim(
    k("    config.env.DATABASE_HOST"),
    p(" = "),
    r("postgres.out.fqdn"),
    p(";"),
  ),
  dim(p("  };")),
  line(),
  dim(k("  postgres"), p(" = {")),
  dim(k("    package"), p(" = "), r("packages.postgres"), p(";")),
  dim(k("    config.extensions"), p(" = [ "), v('"vector"'), p(" ];")),
  dim(k("    config.postgres.version"), p(" = "), v('"18"'), p(";")),
  dim(k("    config.instances"), p(" = "), v("2"), p(";")),
  dim(k("    config.storage.size"), p(" = "), v('"200Gi"'), p(";")),
  dim(
    k("    config.instanceProfile"),
    p(" = { "),
    k("cpu"),
    p(" = "),
    v('"4"'),
    p("; "),
    k("memory"),
    p(" = "),
    v('"8Gi"'),
    p("; };"),
  ),
  dim(k("    config.backup.enabled"), p(" = "), v("true"), p(";")),
  dim(k("    config.backup.schedule"), p(" = "), v('"0 3 * * *"'), p(";")),
  dim(p("  };")),
  line(),
  dim(k("  cache"), p(" = {")),
  dim(k("    package"), p(" = "), r("packages.redis"), p(";")),
  dim(
    k("    config.auth.secretSource"),
    p(" = "),
    v("./secrets/redis.yaml"),
    p(";"),
  ),
  dim(p("  };")),
  line(),
  line(k("  tracing"), p(" = {")),
  line(k("    package"), p(" = "), r("kix.helmChart"), p(" {")),
  line(
    k("      repo"),
    p("    = "),
    v('"https://grafana.github.io/helm-charts"'),
    p(";"),
  ),
  line(k("      name"), p("    = "), v('"tempo"'), p(";")),
  line(k("      version"), p(" = "), v('"1.10.1"'), p(";")),
  line(),
  line(c("      # Rewrite the chart's generated resources before they ship:")),
  line(k("      patchResources"), p(" = map (r:")),
  line(p("        if "), k("r.kind"), p(" == "), v('"StatefulSet"')),
  line(p("        then r // { "), k("spec"), p(" = r.spec // {")),
  line(k("          persistentVolumeClaimRetentionPolicy"), p(" = {")),
  line(
    k("            whenDeleted"),
    p(" = "),
    v('"Delete"'),
    p("; "),
    k("whenScaled"),
    p(" = "),
    v('"Retain"'),
    p(";"),
  ),
  line(p("          };")),
  line(p("        }; }")),
  line(p("        else r);")),
  line(p("    };")),
  line(p("  };")),
  dim(p("};")),
  line(),
  line(c("# Every resource Kix produces is plain Kubernetes. Inspect it,")),
  line(c("# patch it, or set fields no package exposes.")),
];

// Per-tab "coding agent" narratives. The prompt is the human ask; action
// lines are the agent editing/checking (italic); the last line is real
// output from `kix check`.
const stackAgent: AgentLine[] = [
  {
    tone: "prompt",
    t: '"Using kix.run, deploy the api and worker images, and a shared Postgres.\n  See current directory for project information."',
  },
  { tone: "action", t: "agent adds instances.app.worker" },
  { tone: "action", t: "agent wires env.DATABASE_HOST to postgres.out.fqdn" },
  { tone: "action", t: "agent runs kix check" },
  { tone: "good", t: "✓ 0 errors · 14 manifests evaluated" },
];

const controlAgent: AgentLine[] = [
  { tone: "prompt", t: '"Make Postgres an HA pair and pin it to 18"' },
  { tone: "action", t: "agent sets config.instances = 2, version = 18" },
  { tone: "action", t: "agent runs kix check" },
  { tone: "bad", t: "✗ HA change needs a backup schedule" },
  { tone: "action", t: "agent adds config.backup.schedule, checks again" },
  { tone: "good", t: "✓ 0 errors · safe to preview" },
];

const manifestAgent: AgentLine[] = [
  { tone: "prompt", t: '"Add Tempo tracing, retain its PVCs upon scale-down"' },
  { tone: "action", t: "agent brings the chart in as kix.helmChart" },
  { tone: "action", t: "agent patches the StatefulSet PVC retention" },
  { tone: "action", t: "agent runs kix check" },
  { tone: "good", t: "✓ 0 errors · no schema violations" },
];

const tabs: {
  value: string;
  label: string;
  lines: CodeLine[];
  agent: AgentLine[];
  caption: ReactNode;
}[] = [
  {
    value: "stack",
    label: "1 · The whole stack",
    lines: stackLines,
    agent: stackAgent,
    caption: (
      <>
        <strong className="text-foreground">
          Four instances, wired by reference.
        </strong>{" "}
        Services, network policies, storage, backups, and certificates are{" "}
        <strong className="text-foreground">derived from this</strong>; there is
        no hand-rolled glue to forget about.
      </>
    ),
  },
  {
    value: "control",
    label: "2 · Take control",
    lines: controlLines,
    agent: controlAgent,
    caption: (
      <>
        The same four instances after production{" "}
        <strong className="text-foreground">
          turned the defaults into decisions
        </strong>
        : pinned versions, an HA pair, resource limits, encrypted secrets. The
        rest of the stack is{" "}
        <strong className="text-foreground">unchanged, and dimmed</strong>.
      </>
    ),
  },
  {
    value: "manifests",
    label: "3 · Down to the manifests",
    lines: manifestLines,
    agent: manifestAgent,
    caption: (
      <>
        The same stack gains a{" "}
        <strong className="text-foreground">
          fifth instance from a Helm chart
        </strong>
        , its{" "}
        <strong className="text-foreground">
          generated resources rewritten in place
        </strong>
        .{" "}
        <strong className="text-foreground">
          If you would set it by hand in Kubernetes, you can set it in your
          definition.
        </strong>
      </>
    ),
  },
];

function AgentPane({ lines }: { lines: AgentLine[] }) {
  return (
    <pre className="overflow-x-auto px-4 py-3 font-mono text-[0.74rem] leading-relaxed sm:px-5 sm:py-4 sm:text-[0.82rem]">
      <code>
        {lines.map((l, i) =>
          l.tone === "prompt" ? (
            <span key={i} className="block">
              <span className="text-zinc-500">❱ </span>
              <span className="text-zinc-100">{l.t}</span>
            </span>
          ) : (
            <span
              key={i}
              className={
                l.tone === "good"
                  ? "block text-emerald-400"
                  : l.tone === "bad"
                    ? "block text-rose-400"
                    : "block italic text-zinc-400"
              }
            >
              {"  " + l.t}
            </span>
          ),
        )}
      </code>
    </pre>
  );
}

function CodePane({
  lines,
  agent,
  view,
  onToggle,
}: {
  lines: CodeLine[];
  agent: AgentLine[];
  view: "code" | "agent";
  onToggle: () => void;
}) {
  return (
    <div className="overflow-hidden rounded-xl border border-zinc-800 bg-[#0b0f1a] text-left shadow-2xl shadow-emerald-950/25 ring-1 ring-white/10 dark:ring-white/20">
      <div className="flex items-center gap-2 border-b border-zinc-800 bg-zinc-900/60 px-4 py-2.5">
        <span className="size-3 rounded-full bg-zinc-700" />
        <span className="size-3 rounded-full bg-zinc-700" />
        <span className="size-3 rounded-full bg-zinc-700" />
        <span className="ml-2 font-mono text-xs text-zinc-500">
          {view === "code" ? "cluster.nix" : "kix + your agent"}
        </span>
        <AgentToggle active={view === "agent"} onClick={onToggle} />
      </div>
      {view === "agent" ? (
        <AgentPane lines={agent} />
      ) : (
        <pre className="overflow-x-auto px-4 py-3 font-mono text-[0.74rem] leading-relaxed sm:px-5 sm:py-4 sm:text-[0.82rem]">
          <code>
            {lines.map((l, i) => (
              <span
                key={i}
                className={
                  l.dim ? "block opacity-40 transition-opacity" : "block"
                }
              >
                {l.toks.length === 0
                  ? " "
                  : l.toks.map((tok, j) => (
                      <span
                        key={j}
                        className={tok.c ? tokClass[tok.c] : undefined}
                      >
                        {tok.t}
                      </span>
                    ))}
              </span>
            ))}
          </code>
        </pre>
      )}
    </div>
  );
}

export default function Example() {
  // Shared across all tabs so flipping code <-> agent persists when the
  // reader switches tabs.
  const [view, setView] = useState<"code" | "agent">("code");
  return (
    <section
      id="example"
      className="scroll-mt-16 bg-(--surface-tint) py-24 sm:py-28"
    >
      <Container>
        <SectionHeading
          kicker="A real stack"
          title="A real architecture, with every layer still yours"
          lede="The hero shows the short version. Here is a fuller one: an API and its worker, Postgres with a vector store, and a cache, wired together by reference so the whole graph hangs together at compile time. When you need more than the defaults, every layer opens, down to the generated manifests."
        />

        <Reveal delay={1} className="mt-12">
          <Tabs.Root defaultValue="stack" className="mx-auto max-w-3xl">
            <Tabs.List className="mb-5 flex flex-wrap justify-center gap-2">
              {tabs.map((tab) => (
                <Tabs.Trigger
                  key={tab.value}
                  value={tab.value}
                  className="cursor-pointer rounded-full border border-border bg-card px-4 py-1.5 text-sm font-medium text-muted-foreground transition-colors hover:text-foreground data-[state=active]:border-brand data-[state=active]:bg-brand data-[state=active]:text-primary-foreground"
                >
                  {tab.label}
                </Tabs.Trigger>
              ))}
            </Tabs.List>
            {tabs.map((tab) => (
              <Tabs.Content
                key={tab.value}
                value={tab.value}
                className="-mx-2 sm:mx-0"
              >
                <p className="mx-auto mb-4 max-w-2xl text-center text-sm leading-relaxed text-muted-foreground">
                  {tab.caption}
                </p>
                <CodePane
                  lines={tab.lines}
                  agent={tab.agent}
                  view={view}
                  onToggle={() =>
                    setView(view === "code" ? "agent" : "code")
                  }
                />
              </Tabs.Content>
            ))}
          </Tabs.Root>
        </Reveal>

        <Reveal delay={1}>
          <div className="mx-auto mt-14 max-w-3xl rounded-2xl border border-border bg-card p-7 sm:p-8">
            <div className="flex size-9 items-center justify-center rounded-lg bg-brand-soft text-brand">
              <ShieldCheck className="size-4.5" />
            </div>
            <h3 className="mt-4 font-semibold text-foreground">
              Standard Kubernetes underneath.
            </h3>
            <p className="mt-2 leading-relaxed text-muted-foreground">
              Kix compiles to plain Kubernetes resources on a plain Kubernetes
              cluster, yours or your customer's. You can inspect every line it
              produces, and if you ever leave, you keep a working cluster and
              standard manifests. Leaving Kix means losing the tooling, not your
              infrastructure.
            </p>
          </div>
        </Reveal>
      </Container>
    </section>
  );
}

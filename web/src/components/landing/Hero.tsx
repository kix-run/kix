import { useState } from "react";
import { ArrowDown, ArrowRight, Bot, Check } from "lucide-react";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Container, Eyebrow, Reveal } from "@/components/landing/primitives";

// Token color shorthands for the hand-tokenized nix snippet.
// The hero card is terminal-dark in both color schemes, so these are fixed.
const K = "text-zinc-300"; // keys
const P = "text-zinc-500"; // punctuation

type HeroView = "code" | "agent";

/**
 * Pane-header pill that flips the code example into its agent view.
 * Loud (brand fill + ping dot) until activated, quiet afterwards.
 */
export function AgentToggle({
  active,
  onClick,
  activeLabel = "Show the code",
}: {
  active: boolean;
  onClick: () => void;
  activeLabel?: string;
}) {
  return (
    <button
      type="button"
      aria-pressed={active}
      onClick={onClick}
      className={cn(
        "relative ml-auto inline-flex cursor-pointer items-center gap-1.5 rounded-full px-3 py-1 text-xs font-semibold transition-all",
        active
          ? "bg-white/10 text-zinc-400 hover:text-zinc-200"
          : "bg-(--brand-on-dark) text-(--band) shadow-md shadow-emerald-950/40 hover:scale-[1.04]",
      )}
    >
      {!active && (
        <span className="absolute -right-0.5 -top-0.5 flex size-2.5">
          <span className="absolute inline-flex h-full w-full animate-[agent-ripple_2.6s_ease-out_infinite] rounded-full bg-(--brand-on-dark)" />
          <span className="relative inline-flex size-2.5 rounded-full bg-(--brand-on-dark) ring-2 ring-zinc-900" />
        </span>
      )}
      <Bot className="size-3.5" />
      {active ? activeLabel : "Using a coding agent?"}
    </button>
  );
}

const agentFacilities = [
  "MCP server for checks, schemas, and package discovery",
  "Docs available as markdown and via MCP",
  "Errors an agent can read and act on",
  "Compact, typed definitions agents write well",
];

function AgentPane() {
  return (
    <div className="px-4 py-3 sm:px-5 sm:py-4">
      <pre className="overflow-x-auto font-mono text-[0.78rem] leading-normal sm:text-[0.875rem]">
        <code>
          <span className="block">
            <span className="text-zinc-500">❱ </span>
            <span className="text-zinc-100">"Upgrade Postgres to 18"</span>
          </span>
          <span className="block italic text-zinc-400">
            {"  agent bumps postgres.config.version to 18"}
          </span>
          <span className="block italic text-zinc-400">
            {"  agent runs kix check"}
          </span>
          <span className="block text-rose-400">
            {"  ✗ major upgrade requires a fresh pre-upgrade backup"}
          </span>
          <span className="block italic text-zinc-400">
            {"  agent schedules the backup, checks again"}
          </span>
          <span className="block text-emerald-400">
            {"  ✓ 0 errors, safe to preview"}
          </span>
        </code>
      </pre>
      <div className="mt-4 border-t border-white/10 pt-4">
        <p className="font-mono text-[0.68rem] font-medium uppercase tracking-[0.12em] text-zinc-500">
          What agents get
        </p>
        <ul className="mt-2.5 space-y-2 text-sm text-zinc-400">
          {agentFacilities.map((item, i) => (
            <li key={i} className="flex items-start gap-2.5">
              <Check className="mt-0.5 size-4 shrink-0 text-(--brand-on-dark)" />
              <span>{item}</span>
            </li>
          ))}
        </ul>
      </div>
    </div>
  );
}

function CodeCard() {
  const [view, setView] = useState<HeroView>("code");
  return (
    <div className="relative -mx-2 sm:mx-0">
      <div className="overflow-hidden rounded-xl border border-zinc-800 bg-[#0b0f1a] text-left shadow-2xl shadow-emerald-950/25 ring-1 ring-white/10 dark:ring-white/20">
        <div className="flex items-center gap-2 border-b border-zinc-800 bg-zinc-900/60 px-4 py-2">
          <span className="size-3 rounded-full bg-zinc-700" />
          <span className="size-3 rounded-full bg-zinc-700" />
          <span className="size-3 rounded-full bg-zinc-700" />
          <span className="ml-2 font-mono text-xs text-zinc-500">
            {view === "code" ? "kix check + deploy" : "kix + your agent"}
          </span>
          <AgentToggle
            active={view === "agent"}
            onClick={() => setView(view === "code" ? "agent" : "code")}
            activeLabel="Kix CLI"
          />
        </div>
        {view === "agent" ? (
          <AgentPane />
        ) : (
          <>
            <pre className="overflow-x-auto px-4 py-3 font-mono text-[0.78rem] leading-normal sm:px-5 sm:py-3.5 sm:text-[0.875rem]">
              <code>
                <span className="block">
                  <span className="text-zinc-500">❱ </span>
                  <span className="text-zinc-100">kix check acme</span>
                </span>
                <span className="block">
                  <span className={K}>{"  eval         "}</span>
                  <span className="text-emerald-400">pass</span>
                  <span className={P}>{"   47 manifests evaluated"}</span>
                </span>
                <span className="block">
                  <span className={K}>{"  kubeconform  "}</span>
                  <span className="text-emerald-400">pass</span>
                  <span className={P}>{"   no schema errors"}</span>
                </span>
                <span className="block">
                  <span className={K}>{"  scorecard    "}</span>
                  <span className="text-emerald-400">pass</span>
                  <span className={P}>{"   0 errors, 0 warnings"}</span>
                </span>
                <span className="block">
                  <span className="text-emerald-400">{"  ✓ ready to deploy"}</span>
                </span>
                <span className="block"> </span>
                <span className="block">
                  <span className="text-zinc-500">❱ </span>
                  <span className="text-zinc-100">kix deploy acme</span>
                </span>
                <span className="block">
                  <span className={P}>{"  Plan: "}</span>
                  <span className="text-emerald-400">47 added</span>
                  <span className={P}>{", 4 instances"}</span>
                </span>
                <span className="block">
                  <span className="text-emerald-400">{"  ✔ "}</span>
                  <span className={K}>{"Namespace/app"}</span>
                  <span className={P}>{"              ready"}</span>
                </span>
                <span className="block">
                  <span className="text-emerald-400">{"  ✔ "}</span>
                  <span className={K}>{"Deployment/api@app"}</span>
                  <span className={P}>{"         ready"}</span>
                </span>
                <span className="block">
                  <span className="text-emerald-400">{"  ✔ "}</span>
                  <span className={K}>{"Service/api@app"}</span>
                  <span className={P}>{"            ready"}</span>
                </span>
                <span className="block">
                  <span className="text-emerald-400">{"  ✔ "}</span>
                  <span className={K}>{"StatefulSet/postgres@app"}</span>
                  <span className={P}>{"   ready"}</span>
                </span>
                <span className="block">
                  <span className="text-emerald-400">{"  • "}</span>
                  <span className={P}>{"activation 'acme-vp4b2qcq' → Active"}</span>
                </span>
                <span className="block">
                  <span className="text-emerald-400">
                    {"  ✓ Deploy complete: 47 created, 0 failed"}
                  </span>
                </span>
              </code>
            </pre>
          </>
        )}
      </div>
    </div>
  );
}

export default function Hero() {
  return (
    <section className="relative overflow-hidden pt-14 pb-24">
      <div className="absolute inset-0 -z-10 bg-[linear-gradient(to_bottom,var(--background),var(--background)_55%,var(--hero-fade)_100%)]" />
      <div className="absolute inset-0 -z-10 h-[640px] w-full bg-[linear-gradient(to_right,var(--hero-grid)_1px,transparent_1px),linear-gradient(to_bottom,var(--hero-grid)_1px,transparent_1px)] bg-[size:6rem_5rem] opacity-70 [mask-image:radial-gradient(ellipse_80%_50%_at_50%_0%,#000_70%,transparent_110%)]" />
      <Container className="text-center">
        {/* Compiler-fact H1 with the get-shit-done claim as qualifier,
            restructured per CLAUDE.hero-design.md: eyebrow → H1 →
            one sub-block → CTA row → code card. Steps strip moved to
            the How-it-works section. */}
        <Reveal>
          <Eyebrow>Private beta · early access for startups</Eyebrow>
        </Reveal>
        <Reveal delay={1}>
          <h1 className="mt-6 bg-gradient-to-br from-foreground from-40% to-foreground/50 bg-clip-text pb-1 text-balance text-5xl font-semibold leading-[1.02] tracking-tighter text-transparent sm:text-6xl md:text-7xl">
            Kix is a Kubernetes compiler.
          </h1>
        </Reveal>
        <Reveal delay={2}>
          <p className="mx-auto mt-6 max-w-2xl text-balance text-lg text-muted-foreground sm:text-xl">
            Compile your whole cluster from one definition
            <br />
            If it compiles, it will deploy safely.
          </p>
        </Reveal>
        <Reveal delay={3}>
          <div className="mt-8 flex flex-wrap items-center justify-center gap-3">
            <Button size="lg" asChild>
              <a href="#early-access">
                Get early access
                <ArrowRight className="size-4" />
              </a>
            </Button>
            <Button size="lg" variant="ghost" asChild>
              <a href="#how-it-works">
                See how it works
                <ArrowDown className="size-4" />
              </a>
            </Button>
          </div>
        </Reveal>
        <div className="relative mt-14">
          <div className="pointer-events-none absolute left-1/2 top-2 -z-10 h-[380px] w-[min(900px,96vw)] -translate-x-1/2 rounded-[50%] bg-[radial-gradient(ellipse_at_center,color-mix(in_srgb,var(--brand)_22%,transparent)_10%,transparent_60%)]" />
          <Reveal delay={4}>
            <div
              id="stack-definition"
              className="mx-auto max-w-2xl scroll-mt-24"
            >
              <CodeCard />
              <p className="mt-4 text-sm text-muted-foreground">
                This is the short version.{" "}
                <a
                  href="#example"
                  className="font-medium text-brand underline-offset-4 hover:underline"
                >
                  See a real architecture, three levels deep ↓
                </a>
              </p>
            </div>
          </Reveal>
        </div>
      </Container>
    </section>
  );
}

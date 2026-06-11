import {
  ArrowRight,
  BadgeCheck,
  Bot,
  ChevronRight,
  FileCode2,
  RefreshCcw,
  Rocket,
  type LucideIcon,
} from "lucide-react"
import { Button } from "@/components/ui/button"
import { Container, Reveal } from "@/components/landing/primitives"

// Token color shorthands for the hand-tokenized nix snippet.
// The hero card is terminal-dark in both color schemes, so these are fixed.
const K = "text-zinc-300" // keys
const V = "text-(--brand-on-dark)" // values / strings
const P = "text-zinc-500" // punctuation
const C = "text-zinc-500 italic" // comments
const R = "text-[#86bbd8]" // references

const heroSteps: { label: string; icon: LucideIcon }[] = [
  { label: "Define your stack", icon: FileCode2 },
  { label: "Compile & check", icon: BadgeCheck },
  { label: "Deploy verified", icon: Rocket },
]

function StepConnector({ dashed = false }: { dashed?: boolean }) {
  return (
    <span className="hidden items-center sm:inline-flex" aria-hidden>
      <span
        className={
          dashed
            ? "w-5 border-t border-dashed border-brand/50"
            : "h-px w-5 bg-brand/40"
        }
      />
      <ChevronRight className="-ml-1.5 size-3.5 text-brand/70" />
    </span>
  )
}

function StepsStrip() {
  return (
    <div className="flex flex-wrap items-center justify-center gap-x-1.5 gap-y-3">
      {heroSteps.map((step, i) => (
        <span key={step.label} className="inline-flex items-center gap-x-1.5">
          {i > 0 && <StepConnector />}
          <span className="inline-flex items-center gap-2.5 rounded-full border border-border bg-card py-1.5 pl-2 pr-4 text-sm font-medium text-foreground shadow-sm ring-1 ring-foreground/5">
            <span className="flex size-6.5 items-center justify-center rounded-full bg-brand-soft text-brand">
              <step.icon className="size-3.5" />
            </span>
            {step.label}
          </span>
        </span>
      ))}
      <span className="inline-flex items-center gap-x-1.5">
        <StepConnector dashed />
        <span className="inline-flex items-center gap-2.5 rounded-full border border-dashed border-brand/40 bg-brand-soft/40 py-1.5 pl-2 pr-4 text-sm font-medium text-foreground">
          <span className="flex size-6.5 items-center justify-center rounded-full bg-brand-soft text-brand">
            <RefreshCcw className="size-3.5" />
          </span>
          Managed over time
        </span>
      </span>
    </div>
  )
}

function CodeCard() {
  return (
    <div className="relative">
      <a
        href="#agents"
        className="absolute -top-3 right-4 z-10 inline-flex items-center gap-1.5 rounded-full bg-brand px-3 py-1.5 text-xs font-semibold text-primary-foreground shadow-md shadow-brand/40 transition-transform hover:scale-[1.04]"
      >
        <span className="absolute -right-0.5 -top-0.5 flex size-2.5">
          <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-brand opacity-70" />
          <span className="relative inline-flex size-2.5 rounded-full bg-brand ring-2 ring-card" />
        </span>
        <Bot className="size-3.5" />
        Agent compatible
      </a>
      <div className="overflow-hidden rounded-xl border border-zinc-800 bg-[#0b0f1a] text-left shadow-2xl shadow-emerald-950/25 ring-1 ring-white/10 dark:ring-white/20">
        <div className="flex items-center gap-2 border-b border-zinc-800 bg-zinc-900/60 px-4 py-2.5">
          <span className="size-3 rounded-full bg-zinc-700" />
          <span className="size-3 rounded-full bg-zinc-700" />
          <span className="size-3 rounded-full bg-zinc-700" />
          <span className="ml-2 font-mono text-xs text-zinc-500">
            stack.nix
          </span>
        </div>
        <pre className="overflow-x-auto px-5 py-3.5 font-mono text-[0.875rem] leading-normal">
        <code>
          <span className="block">
            <span className={K}>instances.app.api</span>
            <span className={P}>{" = {"}</span>
          </span>
          <span className="block">
            <span className={K}>{"  package"}</span>
            <span className={P}>{" = "}</span>
            <span className={R}>packages.app</span>
            <span className={P}>;</span>
          </span>
          <span className="block">
            <span className={K}>{"  config"}</span>
            <span className={P}>{" = {"}</span>
          </span>
          <span className="block">
            <span className={K}>{"    image"}</span>
            <span className={P}>{"    = "}</span>
            <span className={V}>{'"ghcr.io/acme-co/api:v1.5.0"'}</span>
            <span className={P}>;</span>
          </span>
          <span className="block">
            <span className={K}>{"    replicas"}</span>
            <span className={P}>{" = "}</span>
            <span className={V}>3</span>
            <span className={P}>;</span>
          </span>
          <span className="block">
            <span className={K}>{"    env.DATABASE_HOST"}</span>
            <span className={P}>{" = "}</span>
            <span className={R}>postgres.out.fqdn</span>
            <span className={P}>;</span>
          </span>
          <span className="block">
            <span className={K}>{"    ingress.host"}</span>
            <span className={P}>{"      = "}</span>
            <span className={V}>{'"api.acme.co"'}</span>
            <span className={P}>;</span>
            <span className={C}>{"  # TLS handled"}</span>
          </span>
          <span className="block">
            <span className={P}>{"  };"}</span>
          </span>
          <span className="block">
            <span className={P}>{"};"}</span>
          </span>
          <span className="block"> </span>
          <span className="block">
            <span className={K}>instances.app.postgres</span>
            <span className={P}>{" = {"}</span>
          </span>
          <span className="block">
            <span className={K}>{"  package"}</span>
            <span className={P}>{" = "}</span>
            <span className={R}>packages.postgres</span>
            <span className={P}>;</span>
          </span>
          <span className="block">
            <span className={K}>{"  config.storage.size"}</span>
            <span className={P}>{"   = "}</span>
            <span className={V}>{'"20Gi"'}</span>
            <span className={P}>;</span>
          </span>
          <span className="block">
            <span className={K}>{"  config.backup.enabled"}</span>
            <span className={P}>{" = "}</span>
            <span className={V}>true</span>
            <span className={P}>;</span>
          </span>
          <span className="block">
            <span className={P}>{"};"}</span>
          </span>
        </code>
      </pre>
        <div className="flex flex-wrap items-center gap-x-4 gap-y-1 border-t border-white/10 bg-white/[0.03] px-5 py-2.5 font-mono text-[0.72rem]">
          <span className="text-zinc-500">$ kix check</span>
          <span className="text-emerald-400">✓ compiled: 47 resources</span>
          <span className="text-emerald-400">✓ 0 errors</span>
          <span className="text-zinc-400">ready to deploy</span>
        </div>
      </div>
    </div>
  )
}

export default function Hero() {
  return (
    <section className="relative overflow-hidden pt-14 pb-24">
      <div className="absolute inset-0 -z-10 bg-[linear-gradient(to_bottom,var(--background),var(--background)_55%,var(--hero-fade)_100%)]" />
      <div className="absolute inset-0 -z-10 h-[640px] w-full bg-[linear-gradient(to_right,var(--hero-grid)_1px,transparent_1px),linear-gradient(to_bottom,var(--hero-grid)_1px,transparent_1px)] bg-[size:6rem_5rem] opacity-70 [mask-image:radial-gradient(ellipse_80%_50%_at_50%_0%,#000_70%,transparent_110%)]" />
      <Container className="text-center">
        <Reveal>
          {/* H1 per 2026-06-11 meeting with Luca & Sebi. Prior H1s, kept
              for later testing:
              "Kubernetes any developer can run."
              "Run Kubernetes without becoming the expert."
              "Kubernetes, no expert required." */}
          <h1 className="bg-gradient-to-br from-foreground from-40% to-foreground/70 bg-clip-text pb-1 text-balance text-5xl font-semibold leading-[1.02] tracking-tighter text-transparent sm:text-6xl md:text-7xl">
            Getting shit done with Kubernetes.
          </h1>
        </Reveal>
        <Reveal delay={1}>
          <p className="mt-5 text-xl font-medium text-foreground sm:text-2xl">
            Kix is a Kubernetes compiler.
          </p>
          <p className="mx-auto mt-3 max-w-2xl text-balance text-lg text-muted-foreground sm:text-xl">
            Describe your whole stack in one definition. Kix compiles it
            into a running cluster that matches what you wrote, change
            after change.
          </p>
        </Reveal>
        <Reveal delay={2} className="mt-10">
          <StepsStrip />
        </Reveal>
        <div className="relative mt-12">
          <div className="pointer-events-none absolute left-1/2 top-2 -z-10 h-[380px] w-[min(900px,96vw)] -translate-x-1/2 rounded-[50%] bg-[radial-gradient(ellipse_at_center,color-mix(in_srgb,var(--brand)_22%,transparent)_10%,transparent_60%)]" />
          <Reveal delay={3}>
            <div className="mx-auto max-w-2xl">
              <p className="mb-4 text-[0.95rem] font-medium text-foreground">
                Everything it takes to run this stack, short enough to
                review:
              </p>
              <CodeCard />
            </div>
          </Reveal>
        </div>
        <Reveal delay={4}>
          <div className="mt-9">
            <Button size="lg" asChild>
              <a href="#early-access">
                Get early access
                <ArrowRight className="size-4" />
              </a>
            </Button>
          </div>
        </Reveal>
      </Container>
    </section>
  )
}

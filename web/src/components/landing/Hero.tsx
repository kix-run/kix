import { ArrowRight, Bot, RefreshCcw } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Container, Reveal } from "@/components/landing/primitives"

// Token color shorthands for the hand-tokenized nix snippet.
const K = "text-foreground/75" // keys
const V = "text-brand" // values / strings
const P = "text-muted-foreground/70" // punctuation
const C = "text-muted-foreground/70 italic" // comments
const R = "text-(--code-ref)" // references

const heroSteps = ["Define your stack", "Compile & check", "Deploy, verified"]

function StepsStrip() {
  return (
    <div>
      <div className="flex flex-wrap items-center justify-center gap-x-3 gap-y-2 text-[0.95rem] font-medium text-foreground/90">
        {heroSteps.map((step, i) => (
          <span key={step} className="inline-flex items-center gap-3">
            {i > 0 && <ArrowRight className="size-4 text-brand" />}
            {step}
          </span>
        ))}
        <span className="inline-flex items-center gap-3 text-muted-foreground">
          <RefreshCcw className="size-4 text-brand" />
          Managed over time
        </span>
      </div>
      <p className="mx-auto mt-3 max-w-xl text-sm leading-relaxed text-muted-foreground">
        Kix generates the parts you'd otherwise learn tool by tool:
        deployments, network policies, security policies, storage, backups,
        certificates.
      </p>
    </div>
  )
}

function CodeCard() {
  return (
    <div className="overflow-hidden rounded-xl border border-border bg-card text-left shadow-xl shadow-zinc-950/5 ring-1 ring-foreground/5">
      <div className="flex items-center gap-2 border-b border-border bg-muted/50 px-4 py-2">
        <span className="size-3 rounded-full bg-border" />
        <span className="size-3 rounded-full bg-border" />
        <span className="size-3 rounded-full bg-border" />
        <span className="ml-2 font-mono text-xs text-muted-foreground">
          stack.nix
        </span>
        <a
          href="#agents"
          className="ml-auto inline-flex items-center gap-1.5 rounded-full border border-brand/30 bg-brand-soft/70 px-2.5 py-1 text-xs font-semibold text-brand transition-colors hover:bg-brand-soft"
        >
          <Bot className="size-3.5" />
          Agent compatible
        </a>
      </div>
      <pre className="overflow-x-auto px-5 py-4 font-mono text-[0.8rem] leading-relaxed">
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
            <span className={V}>{'"registry.io/api:v1.5.0"'}</span>
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
            <span className={V}>{'"api.example.com"'}</span>
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
    </div>
  )
}

export default function Hero() {
  return (
    <section className="relative overflow-hidden pt-16 pb-20 sm:pt-20">
      <div className="absolute inset-0 -z-10 bg-[linear-gradient(to_bottom,var(--background),var(--background)_55%,var(--hero-fade)_100%)]" />
      <div className="absolute inset-0 -z-10 h-[640px] w-full bg-[linear-gradient(to_right,var(--hero-grid)_1px,transparent_1px),linear-gradient(to_bottom,var(--hero-grid)_1px,transparent_1px)] bg-[size:6rem_5rem] opacity-70 [mask-image:radial-gradient(ellipse_80%_50%_at_50%_0%,#000_70%,transparent_110%)]" />
      <Container className="text-center">
        <Reveal>
          {/* H1 per 2026-06-11 meeting with Luca & Sebi. Prior H1s, kept
              for later testing:
              "Kubernetes any developer can run."
              "Run Kubernetes without becoming the expert."
              "Kubernetes, no expert required." */}
          <h1 className="bg-gradient-to-br from-foreground from-40% to-foreground/50 bg-clip-text pb-2 text-balance text-5xl font-semibold leading-[1.02] tracking-tighter text-transparent sm:text-6xl md:text-7xl">
            Getting shit done with Kubernetes.
          </h1>
        </Reveal>
        <Reveal delay={1}>
          <p className="mt-5 text-xl font-medium text-foreground sm:text-2xl">
            Kix is a Kubernetes compiler.
          </p>
          <p className="mx-auto mt-3 max-w-2xl text-balance text-lg text-muted-foreground sm:text-xl">
            Define your whole stack in one file. Kix compiles it into a
            running cluster, and keeps the cluster matching what you wrote.
          </p>
        </Reveal>
        <Reveal delay={2} className="mt-9">
          <StepsStrip />
        </Reveal>
        <div className="relative mx-auto mt-12 max-w-xl">
          <div className="pointer-events-none absolute left-1/2 -z-10 h-[300px] w-[90%] -translate-x-1/2 scale-y-75 rounded-[50%] bg-[radial-gradient(ellipse_at_center,color-mix(in_srgb,var(--brand)_16%,transparent)_10%,transparent_60%)]" />
          <Reveal delay={3}>
            <p className="mb-4 text-[0.95rem] font-medium text-foreground">
              Everything it takes to deploy and run your whole stack:
            </p>
            <CodeCard />
            <p className="mt-3 text-center text-xs text-muted-foreground">
              App, database, ingress, TLS, backups. One reviewable file.
            </p>
          </Reveal>
        </div>
        <Reveal delay={4}>
          <div className="mt-10">
            <Button size="lg" asChild>
              <a href="#early-access">
                Get in touch
                <ArrowRight className="size-4" />
              </a>
            </Button>
          </div>
        </Reveal>
      </Container>
    </section>
  )
}

import { ArrowDown, ArrowRight } from "lucide-react"
import { Button } from "@/components/ui/button"
import {
  Container,
  Eyebrow,
  Reveal,
  Terminal,
} from "@/components/landing/primitives"

type Line = {
  tokens: { t: string; c?: "p" | "ok" | "err" | "wn" | "cm" | "str" }[]
}

const previewLines: Line[] = [
  { tokens: [{ t: "$ kix diff production", c: "p" }] },
  {
    tokens: [
      { t: "  " },
      { t: "✓", c: "ok" },
      { t: " evaluated 47 resources across 12 packages" },
    ],
  },
  {
    tokens: [
      { t: "  " },
      { t: "✓", c: "ok" },
      { t: " all selectors resolve, all references exist" },
    ],
  },
  { tokens: [{ t: "  " }, { t: "✓ 0 errors", c: "ok" }] },
  { tokens: [] },
  { tokens: [{ t: "  " }, { t: "~", c: "wn" }, { t: " Deployment api" }] },
  {
    tokens: [
      { t: "      image: registry.io/api:v1.4.2 → " },
      { t: "v1.5.0", c: "str" },
    ],
  },
  { tokens: [{ t: "  " }, { t: "+", c: "ok" }, { t: " Secret stripe-keys" }] },
  { tokens: [] },
  { tokens: [{ t: "  2 changes, 45 resources unchanged." }] },
  { tokens: [{ t: "$ kix deploy production", c: "p" }] },
  {
    tokens: [
      { t: "  " },
      { t: "✓ deployed: cluster matches your definition", c: "ok" },
    ],
  },
]

// Token color shorthands for the hand-tokenized nix snippet.
const K = "text-foreground/75" // keys
const V = "text-brand" // values / strings
const P = "text-muted-foreground/70" // punctuation
const C = "text-muted-foreground/70 italic" // comments
const R = "text-(--code-ref)" // references

function CodeCard() {
  return (
    <div className="flex grow flex-col overflow-hidden rounded-xl border border-border bg-card shadow-xl shadow-zinc-950/5 ring-1 ring-foreground/5">
      <div className="flex items-center gap-2 border-b border-border bg-muted/50 px-4 py-3">
        <span className="size-3 rounded-full bg-border" />
        <span className="size-3 rounded-full bg-border" />
        <span className="size-3 rounded-full bg-border" />
        <span className="ml-2 font-mono text-xs text-muted-foreground">
          stack.nix
        </span>
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
    <section className="relative overflow-hidden pt-20 pb-24 sm:pt-28">
      <div className="absolute inset-0 -z-10 bg-[linear-gradient(to_bottom,var(--background),var(--background)_55%,var(--hero-fade)_100%)]" />
      <div className="absolute inset-0 -z-10 h-[640px] w-full bg-[linear-gradient(to_right,var(--hero-grid)_1px,transparent_1px),linear-gradient(to_bottom,var(--hero-grid)_1px,transparent_1px)] bg-[size:6rem_5rem] opacity-70 [mask-image:radial-gradient(ellipse_80%_50%_at_50%_0%,#000_70%,transparent_110%)]" />
      <Container className="text-center">
        <Reveal>
          <Eyebrow>Early access: now onboarding startup teams</Eyebrow>
        </Reveal>
        <Reveal delay={1}>
          <h1 className="mt-6 bg-gradient-to-br from-foreground from-40% to-foreground/50 bg-clip-text pb-2 text-balance text-5xl font-semibold leading-[1.02] tracking-tighter text-transparent sm:text-6xl md:text-7xl">
            Kubernetes, minus the platform team.
          </h1>
        </Reveal>
        <Reveal delay={2}>
          <p className="mx-auto mt-6 max-w-2xl text-balance text-lg text-muted-foreground sm:text-xl">
            Kix gives your startup the control, portability, and lower costs of
            Kubernetes, without the foot-guns, the specialist hires, or the
            months of setup. Define your stack once; Kix checks it, previews
            every change, and deploys it to your cloud or your customer's.
            Broken configs don't ship.
          </p>
        </Reveal>
        <Reveal delay={3}>
          <div className="mt-9 flex flex-wrap items-center justify-center gap-3">
            <Button size="lg" asChild>
              <a href="#early-access">Get early access</a>
            </Button>
            <Button size="lg" variant="outline" asChild>
              <a href="#how-it-works">
                See how it works
                <ArrowDown className="size-4" />
              </a>
            </Button>
          </div>
        </Reveal>
        <Reveal delay={4}>
          <p className="mt-5 text-sm text-muted-foreground/80">
            Standard Kubernetes underneath. Plain manifests you can read,
            audit, and keep.
          </p>
          <p className="mt-2 text-sm">
            <a
              href="#customer-infra"
              className="inline-flex items-center gap-1 font-medium text-brand hover:underline"
            >
              Asked to run in your customer's cloud? Start here
              <ArrowRight className="size-3.5" />
            </a>
          </p>
        </Reveal>
        <div className="relative mt-16">
          <div className="pointer-events-none absolute left-1/2 -z-10 h-[300px] w-[70%] -translate-x-1/2 scale-y-75 rounded-[50%] bg-[radial-gradient(ellipse_at_center,color-mix(in_srgb,var(--brand)_16%,transparent)_10%,transparent_60%)]" />
          <div className="grid items-stretch gap-5 text-left lg:grid-cols-[5fr_6fr]">
            <Reveal delay={5} className="flex flex-col">
              <CodeCard />
              <p className="mt-3 text-center text-xs text-muted-foreground">
                Your whole stack in one reviewable definition: app, database,
                ingress, TLS, backups.
              </p>
            </Reveal>
            <Reveal delay={6} className="flex flex-col">
              <Terminal title="kix diff" lines={previewLines} />
              <p className="mt-3 text-center text-xs text-muted-foreground">
                Preview the exact changes before they happen. What you
                previewed is what runs.
              </p>
            </Reveal>
          </div>
        </div>
      </Container>
    </section>
  )
}

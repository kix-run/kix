import { type ReactNode } from "react"
import { motion } from "motion/react"
import {
  ArrowRight,
  Coins,
  Handshake,
  Activity,
  Globe,
  ShieldCheck,
  Sparkles,
  FileCheck2,
  Boxes,
  Check,
  X,
  Terminal as TerminalIcon,
} from "lucide-react"
import { Container, Reveal, Eyebrow, SectionHeading, Terminal } from "./primitives"
import { cn } from "@/lib/utils"

/* ------------------------------------------------------------------ */
/*  Background flourish — soft green mesh + dot grid                    */
/* ------------------------------------------------------------------ */
function MeshBackdrop() {
  return (
    <div aria-hidden className="pointer-events-none absolute inset-0 -z-10 overflow-hidden">
      {/* dot grid, fading out toward edges */}
      <div
        className="absolute inset-0 opacity-[0.5]"
        style={{
          backgroundImage:
            "radial-gradient(circle at 1px 1px, rgba(17,57,42,0.13) 1px, transparent 0)",
          backgroundSize: "26px 26px",
          maskImage:
            "radial-gradient(ellipse 80% 55% at 50% 0%, #000 35%, transparent 75%)",
        }}
      />
      {/* green glow blobs */}
      <div className="absolute -right-32 -top-40 size-[34rem] rounded-full bg-emerald-300/25 blur-[120px]" />
      <div className="absolute -left-40 top-24 size-[30rem] rounded-full bg-teal-200/30 blur-[130px]" />
    </div>
  )
}

/* ------------------------------------------------------------------ */
/*  Buttons                                                            */
/* ------------------------------------------------------------------ */
function PrimaryButton({
  children,
  href = "#cta",
  className,
}: {
  children: ReactNode
  href?: string
  className?: string
}) {
  return (
    <a
      href={href}
      className={cn(
        "group inline-flex items-center gap-2 rounded-lg bg-brand px-5 py-3 text-sm font-semibold text-white shadow-lg shadow-brand/25 transition-all hover:-translate-y-0.5 hover:bg-brand-ink hover:shadow-xl hover:shadow-brand/30",
        className,
      )}
    >
      {children}
      <ArrowRight className="size-4 transition-transform group-hover:translate-x-0.5" />
    </a>
  )
}

function GhostButton({ children, href = "#how" }: { children: ReactNode; href?: string }) {
  return (
    <a
      href={href}
      className="inline-flex items-center gap-2 rounded-lg border border-border bg-white/70 px-5 py-3 text-sm font-semibold text-foreground backdrop-blur transition-colors hover:border-brand/40 hover:text-brand"
    >
      {children}
    </a>
  )
}

/* ------------------------------------------------------------------ */
/*  Nav                                                                */
/* ------------------------------------------------------------------ */
function Nav() {
  return (
    <header className="sticky top-0 z-50 border-b border-border/60 bg-background/70 backdrop-blur-xl">
      <Container className="flex h-16 items-center justify-between">
        <div className="flex items-center gap-2 font-mono text-lg font-bold tracking-tight">
          kix<span className="text-brand">_</span>
        </div>
        <nav className="hidden items-center gap-8 text-sm font-medium text-muted-foreground md:flex">
          <a href="#why-k8s" className="transition-colors hover:text-foreground">Why Kubernetes</a>
          <a href="#why-kix" className="transition-colors hover:text-foreground">Why kix</a>
          <a href="#how" className="transition-colors hover:text-foreground">How it works</a>
        </nav>
        <a
          href="#cta"
          className="inline-flex items-center gap-1.5 rounded-lg bg-brand px-4 py-2 text-sm font-semibold text-white shadow-sm transition-all hover:-translate-y-0.5 hover:bg-brand-ink"
        >
          Get early access
        </a>
      </Container>
    </header>
  )
}

/* ------------------------------------------------------------------ */
/*  Hero                                                               */
/* ------------------------------------------------------------------ */
function Hero() {
  return (
    <section className="relative overflow-hidden">
      <MeshBackdrop />
      <Container className="grid items-center gap-14 py-20 lg:grid-cols-[1.05fr_0.95fr] lg:py-28">
        <div className="min-w-0">
          <motion.div
            initial={{ opacity: 0, y: 12 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.5 }}
          >
            <Eyebrow>Kubernetes for startups</Eyebrow>
          </motion.div>

          <motion.h1
            initial={{ opacity: 0, y: 18 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.6, delay: 0.08 }}
            className="mt-6 text-balance text-4xl font-semibold tracking-tight text-foreground sm:text-6xl sm:leading-[1.02]"
          >
            Taking the complexity{" "}
            <span className="bg-gradient-to-br from-brand to-emerald-500 bg-clip-text text-transparent">
              out of Kubernetes
            </span>
          </motion.h1>

          <motion.p
            initial={{ opacity: 0, y: 18 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.6, delay: 0.16 }}
            className="mt-6 max-w-xl text-lg leading-relaxed text-muted-foreground"
          >
            kix gives your startup the{" "}
            <strong className="font-semibold text-foreground">control, portability, and scalability</strong>{" "}
            of Kubernetes — without hiring a platform team. Define your stack once,
            check it before it ships, and run it anywhere: your cloud, bare metal,
            or your customer&rsquo;s infrastructure.
          </motion.p>

          <motion.div
            initial={{ opacity: 0, y: 18 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.6, delay: 0.24 }}
            className="mt-9 flex flex-wrap gap-3"
          >
            <PrimaryButton href="#cta">Get early access</PrimaryButton>
            <GhostButton href="#how">See how it works</GhostButton>
          </motion.div>
        </div>

        <motion.div
          initial={{ opacity: 0, y: 24, scale: 0.98 }}
          animate={{ opacity: 1, y: 0, scale: 1 }}
          transition={{ duration: 0.7, delay: 0.2 }}
          className="relative min-w-0"
        >
          <div className="absolute -inset-6 -z-10 rounded-3xl bg-gradient-to-tr from-brand/10 via-emerald-400/10 to-transparent blur-2xl" />
          <Terminal
            title="kix check · production"
            lines={[
              { tokens: [{ t: "$ ", c: "p" }, { t: "kix check" }] },
              { tokens: [{ t: "error: ", c: "err" }, { t: "api → postgres: service selector matches 0 pods" }] },
              { tokens: [{ t: "        app.kubernetes.io/name: postgres-15  (did you mean postgres?)", c: "cm" }] },
              { tokens: [] },
              { tokens: [{ t: "$ ", c: "p" }, { t: "kix check" }] },
              { tokens: [{ t: "✓ ", c: "ok" }, { t: "142 resources · selectors wired · network policy derived" }] },
              { tokens: [{ t: "✓ ", c: "ok" }, { t: "deploy order resolved · RBAC scoped · 0 warnings" }] },
              { tokens: [] },
              { tokens: [{ t: "$ ", c: "p" }, { t: "kix preview production" }] },
              { tokens: [{ t: "~ ", c: "wn" }, { t: "Deployment/api        image: v1.41 → v1.42" }] },
              { tokens: [{ t: "~ ", c: "wn" }, { t: "ConfigMap/api-env     2 keys changed" }] },
              { tokens: [{ t: "  nothing else will change.", c: "cm" }] },
            ]}
          />
        </motion.div>
      </Container>
    </section>
  )
}

/* ------------------------------------------------------------------ */
/*  Why Kubernetes — feature cards                                     */
/* ------------------------------------------------------------------ */
const k8sCards = [
  {
    icon: Coins,
    tag: "cost",
    title: "Cut your infrastructure bill",
    body: "Run on raw cloud instances or bare metal at a fraction of PaaS pricing. Teams spending five figures a month on a hosted platform routinely save the cost of an engineer's salary by moving onto their own compute.",
  },
  {
    icon: Handshake,
    tag: "deals",
    title: "Ship into customer infrastructure",
    body: "Enterprise and regulated buyers increasingly demand self-hosted or in-their-VPC deployment. On Kubernetes, “we deploy into your environment” becomes a sales answer, not an engineering project.",
  },
  {
    icon: Activity,
    tag: "robustness",
    title: "Scalability and self-healing as table stakes",
    body: "Rolling deploys, automatic restarts, horizontal scaling, and zero-downtime releases are built into the platform — not features you bolt on or pay extra tiers for.",
  },
  {
    icon: Globe,
    tag: "freedom",
    title: "No vendor's roadmap is your ceiling",
    body: "Kubernetes is a standard, not a product. Your workloads are portable across every major cloud, European providers, and on-prem hardware. When pricing changes or sovereignty requirements appear — you move; you don't rewrite.",
  },
]

function WhyKubernetes() {
  return (
    <section id="why-k8s" className="border-t border-border/60 py-24">
      <Container>
        <SectionHeading
          kicker="Why Kubernetes at all?"
          title="The platform your hosting bill is paying someone else to run"
          lede={
            <>
              You don&rsquo;t need to care about Kubernetes itself. You need what it buys you — and
              at a certain point, a hosted platform stops buying it for you.{" "}
              <strong className="text-foreground">Most PaaS pricing is a 2–5× markup on the compute underneath it</strong>,
              and the ceiling shows up exactly when you start winning bigger customers.
            </>
          }
        />
        <div className="mt-14 grid gap-5 sm:grid-cols-2">
          {k8sCards.map((c, i) => (
            <Reveal as="article" key={c.tag} delay={i % 2}>
              <div className="group h-full rounded-2xl border border-border bg-white p-7 shadow-[0_1px_3px_rgba(16,40,30,0.04),0_12px_32px_-12px_rgba(16,40,30,0.10)] transition-all duration-300 hover:-translate-y-1 hover:border-brand/30 hover:shadow-[0_1px_3px_rgba(16,40,30,0.06),0_24px_48px_-16px_rgba(16,40,30,0.18)]">
                <div className="flex size-11 items-center justify-center rounded-xl bg-brand-soft text-brand ring-1 ring-brand/10 transition-colors group-hover:bg-brand group-hover:text-white">
                  <c.icon className="size-5" />
                </div>
                <span className="mt-5 inline-block font-mono text-[0.7rem] uppercase tracking-wider text-brand">
                  {c.tag}
                </span>
                <h3 className="mt-2 text-lg font-semibold text-foreground">{c.title}</h3>
                <p className="mt-2 text-[0.95rem] leading-relaxed text-muted-foreground">{c.body}</p>
              </div>
            </Reveal>
          ))}
        </div>
      </Container>
    </section>
  )
}

/* ------------------------------------------------------------------ */
/*  Why kix — comparison                                               */
/* ------------------------------------------------------------------ */
const badPoints = [
  "A typo'd label ships to production and your service quietly routes to nothing",
  "Thousands of lines of YAML, stitched together with Helm templating and hope",
  "Network policy and RBAC written by hand — or, more often, not written at all",
  "Deploy ordering discovered at 2am, one CrashLoopBackOff at a time",
  "“We need to hire a platform engineer” — then two, then a team",
]
const goodPoints = [
  "Mismatched selectors, missing dependencies, and broken wiring are errors before deploy — not incidents after",
  "You declare what your app needs; kix derives the configuration that makes it true",
  "Network policy, RBAC, and monitoring generated from how your services actually connect",
  "Deploy order computed from real dependencies, every time",
  "One engineer runs it alongside their actual job",
]

function WhyKix() {
  return (
    <section id="why-kix" className="relative overflow-hidden border-t border-border/60 bg-gradient-to-b from-brand-soft/40 to-background py-24">
      <Container>
        <SectionHeading
          kicker="So why doesn't every startup run it?"
          title="Because raw Kubernetes is a part-time job for three people"
          lede={
            <>
              Everything above is true, and yet teams stall on adoption — because stock
              Kubernetes is famously full of foot-guns, and the standard fix is to hire a
              platform team. kix is the product that removes that trade-off.
            </>
          }
        />
        <div className="mt-14 grid gap-5 lg:grid-cols-2">
          <Reveal>
            <div className="h-full rounded-2xl border border-border bg-white/60 p-8 backdrop-blur">
              <h3 className="text-base font-semibold text-foreground">Kubernetes the usual way</h3>
              <ul className="mt-5 space-y-px">
                {badPoints.map((p) => (
                  <li key={p} className="flex gap-3 border-t border-border/70 py-3.5 text-[0.95rem] text-muted-foreground first:border-t-0">
                    <X className="mt-0.5 size-4 shrink-0 text-rose-400" />
                    <span>{p}</span>
                  </li>
                ))}
              </ul>
            </div>
          </Reveal>
          <Reveal delay={1}>
            <div className="relative h-full rounded-2xl border border-brand/30 bg-white p-8 shadow-[0_24px_60px_-24px_rgba(29,122,77,0.35)]">
              <div className="absolute -inset-px -z-10 rounded-2xl bg-gradient-to-b from-brand/15 to-transparent" />
              <h3 className="text-base font-semibold text-brand">Kubernetes with kix</h3>
              <ul className="mt-5 space-y-px">
                {goodPoints.map((p) => (
                  <li key={p} className="flex gap-3 border-t border-brand/10 py-3.5 text-[0.95rem] text-foreground first:border-t-0">
                    <span className="mt-0.5 flex size-4 shrink-0 items-center justify-center rounded-full bg-brand/12 text-brand">
                      <Check className="size-3" strokeWidth={3} />
                    </span>
                    <span>{p}</span>
                  </li>
                ))}
              </ul>
            </div>
          </Reveal>
        </div>
        <Reveal delay={2}>
          <p className="mx-auto mt-12 max-w-2xl text-center text-2xl font-semibold tracking-tight text-foreground">
            With kix, Kubernetes becomes a{" "}
            <span className="bg-gradient-to-r from-brand to-emerald-500 bg-clip-text text-transparent">
              one-person show
            </span>
            .
          </p>
        </Reveal>
      </Container>
    </section>
  )
}

/* ------------------------------------------------------------------ */
/*  Adoption paths                                                     */
/* ------------------------------------------------------------------ */
function Adoption() {
  return (
    <section id="adopt" className="border-t border-border/60 py-24">
      <Container>
        <SectionHeading
          kicker="Getting started"
          title="Self-service first. Help if you want it."
          lede="kix is a product you adopt, not a project you commission. Most teams start on their own; some bring in a partner for the migration. Either way, what you end up running is the same thing: kix."
        />
        <div className="mt-14 grid gap-5 lg:grid-cols-[1.15fr_0.85fr]">
          <Reveal>
            <div className="relative h-full overflow-hidden rounded-2xl border border-brand/30 bg-white p-8 shadow-[0_24px_60px_-28px_rgba(29,122,77,0.30)]">
              <div className="absolute right-0 top-0 size-40 rounded-full bg-brand/10 blur-3xl" />
              <span className="font-mono text-[0.7rem] uppercase tracking-wider text-brand">Default path</span>
              <h3 className="mt-3 text-xl font-semibold text-foreground">Self-service</h3>
              <p className="mt-3 leading-relaxed text-muted-foreground">
                Point kix at your apps, define your stack, and bring up a cluster on the
                infrastructure of your choice. Everything is checked locally before anything
                touches a cluster, so you can learn by doing without learning by outage.
              </p>
              <p className="mt-3 leading-relaxed text-muted-foreground">
                Works the same on a laptop, a cloud provider, or a rack of your own machines.
              </p>
            </div>
          </Reveal>
          <Reveal delay={1}>
            <div className="h-full rounded-2xl border border-border bg-white/60 p-8 backdrop-blur">
              <span className="font-mono text-[0.7rem] uppercase tracking-wider text-muted-foreground">Optional</span>
              <h3 className="mt-3 text-xl font-semibold text-foreground">Partner-guided migration</h3>
              <p className="mt-3 leading-relaxed text-muted-foreground">
                Moving off a PaaS with real traffic and a real database? Accredited integration
                partners can plan and run the migration with you — the way HubSpot or Shopify
                partners do — and hand you the keys when it&rsquo;s done.
              </p>
              <p className="mt-3 font-medium text-foreground">The partner leaves. The product stays.</p>
            </div>
          </Reveal>
        </div>
      </Container>
    </section>
  )
}

/* ------------------------------------------------------------------ */
/*  How it works                                                       */
/* ------------------------------------------------------------------ */
const flowSteps = ["define", "check", "preview", "deploy"]
const mechItems = [
  {
    icon: ShieldCheck,
    title: "Compile-time safety",
    body: "The dependency graph between your services is the source of truth. A selector that matches nothing, a service nobody provides, a secret that doesn't exist — these fail the build, on your machine, before commit.",
  },
  {
    icon: Sparkles,
    title: "Safe defaults, derived — not hand-written",
    body: "Network policies, RBAC scopes, monitoring, and deploy ordering are generated from the same graph. The security posture most teams never get around to writing is the output kix produces by default.",
  },
  {
    icon: FileCheck2,
    title: "A verifiable cluster artifact",
    body: "Same inputs, same artifact, same cluster — byte for byte. Preview a change and see exactly which resources move before anything is applied. You know what will happen before you change Kubernetes.",
  },
  {
    icon: Boxes,
    title: "Standard Kubernetes, all the way down",
    body: "kix emits plain Kubernetes resources and runs on any conformant cluster. No proprietary control plane, no agent phoning home, no custom spec to migrate off later. If you ever drop kix, you keep a working cluster.",
  },
]

function HowItWorks() {
  return (
    <section id="how" className="border-t border-border/60 bg-zinc-50/60 py-24">
      <Container>
        <SectionHeading
          kicker="Under the hood"
          title={<>How can it promise that? kix is a Kubernetes compiler.</>}
          lede={
            <>
              This is the part for the skeptics. kix doesn&rsquo;t put a dashboard in front of
              Kubernetes or run an abstraction layer between you and your cluster. It{" "}
              <strong className="text-foreground">compiles</strong> your whole cluster — apps,
              databases, ingress, policies — into a single verifiable cluster artifact, the way a
              compiler turns source code into a binary. That&rsquo;s why errors surface on your
              laptop instead of in production.
            </>
          }
        />

        <Reveal>
          <div className="mt-10 flex flex-wrap items-center gap-2.5 font-mono text-sm">
            {flowSteps.map((s, i) => (
              <div key={s} className="flex items-center gap-2.5">
                <span className="rounded-lg border border-border bg-white px-3.5 py-1.5 font-medium text-foreground shadow-sm">
                  {s}
                </span>
                {i < flowSteps.length - 1 && <ArrowRight className="size-4 text-brand/50" />}
              </div>
            ))}
          </div>
        </Reveal>

        <div className="mt-14 grid gap-12 lg:grid-cols-2 lg:items-start">
          <ul className="min-w-0 space-y-px">
            {mechItems.map((m, i) => (
              <Reveal as="li" key={m.title} delay={i}>
                <div className="flex gap-4 border-t border-border py-6 first:border-t-0 first:pt-0">
                  <div className="flex size-10 shrink-0 items-center justify-center rounded-lg bg-brand-soft text-brand ring-1 ring-brand/10">
                    <m.icon className="size-5" />
                  </div>
                  <div>
                    <h4 className="font-semibold text-foreground">{m.title}</h4>
                    <p className="mt-1.5 text-[0.95rem] leading-relaxed text-muted-foreground">{m.body}</p>
                  </div>
                </div>
              </Reveal>
            ))}
          </ul>

          <Reveal delay={1}>
            <div className="min-w-0 lg:sticky lg:top-24">
              <Terminal
                title="api.kix"
                lines={[
                  { tokens: [{ t: "# your app, declared once", c: "cm" }] },
                  { tokens: [{ t: "api = service {", c: "p" }] },
                  { tokens: [{ t: "  image    = " }, { t: "\"ghcr.io/acme/api:v1.42\"", c: "str" }, { t: ";" }] },
                  { tokens: [{ t: "  needs    = [ postgres redis ];" }] },
                  { tokens: [{ t: "  ingress  = " }, { t: "\"api.acme.dev\"", c: "str" }, { t: ";" }] },
                  { tokens: [{ t: "};", c: "p" }] },
                  { tokens: [] },
                  { tokens: [{ t: "$ ", c: "p" }, { t: "kix check" }] },
                  { tokens: [{ t: "✓ ", c: "ok" }, { t: "graph complete · netpol + RBAC derived" }] },
                  { tokens: [{ t: "$ ", c: "p" }, { t: "kix preview production" }] },
                  { tokens: [{ t: "~ ", c: "wn" }, { t: "3 resources change · 139 unchanged" }] },
                  { tokens: [{ t: "$ ", c: "p" }, { t: "kix deploy production" }] },
                  { tokens: [{ t: "✓ ", c: "ok" }, { t: "applied in dependency order · healthy" }] },
                ]}
              />
            </div>
          </Reveal>
        </div>
      </Container>
    </section>
  )
}

/* ------------------------------------------------------------------ */
/*  CTA                                                                */
/* ------------------------------------------------------------------ */
const usecases = [
  "Move off an expensive PaaS",
  "Ship into customer infrastructure",
  "Adopt Kubernetes without a platform team",
  "Something else",
]

function CTA() {
  return (
    <section id="cta" className="border-t border-border/60 py-24">
      <Container>
        <Reveal>
          <div className="relative mx-auto max-w-2xl overflow-hidden rounded-3xl border border-brand/25 bg-white p-10 text-center shadow-[0_40px_100px_-40px_rgba(29,122,77,0.4)] sm:p-12">
            <div className="absolute -top-24 left-1/2 size-72 -translate-x-1/2 rounded-full bg-brand/15 blur-3xl" />
            <div className="relative">
              <h2 className="text-balance text-3xl font-semibold tracking-tight text-foreground">
                What would you use kix for?
              </h2>
              <p className="mx-auto mt-3 max-w-md text-muted-foreground">
                Tell us where you are, and we&rsquo;ll get you early access.
              </p>

              <form
                action="#"
                method="post"
                className="mt-8"
                onSubmit={(e) => e.preventDefault()}
              >
                <div className="flex flex-wrap justify-center gap-2.5">
                  {usecases.map((u) => (
                    <label key={u} className="cursor-pointer">
                      <input type="radio" name="usecase" value={u} className="peer sr-only" />
                      <span className="inline-block rounded-full border border-border px-4 py-2 text-sm text-muted-foreground transition-colors peer-checked:border-brand peer-checked:bg-brand-soft peer-checked:text-brand hover:border-brand/40">
                        {u}
                      </span>
                    </label>
                  ))}
                </div>

                <div className="mx-auto mt-7 flex max-w-md flex-col gap-2.5 sm:flex-row">
                  <input
                    type="email"
                    required
                    placeholder="you@yourstartup.com"
                    aria-label="Work email"
                    className="flex-1 rounded-lg border border-border bg-background px-4 py-3 text-sm text-foreground outline-none transition-colors focus:border-brand focus:ring-2 focus:ring-brand/15"
                  />
                  <button
                    type="submit"
                    className="inline-flex items-center justify-center gap-2 rounded-lg bg-brand px-5 py-3 text-sm font-semibold text-white shadow-lg shadow-brand/25 transition-all hover:-translate-y-0.5 hover:bg-brand-ink"
                  >
                    Request early access
                  </button>
                </div>
                <p className="mt-4 text-xs text-muted-foreground">
                  No newsletter. We&rsquo;ll reach out about early access, nothing else.
                </p>
              </form>
            </div>
          </div>
        </Reveal>
      </Container>
    </section>
  )
}

/* ------------------------------------------------------------------ */
/*  Footer                                                             */
/* ------------------------------------------------------------------ */
function Footer() {
  return (
    <footer className="border-t border-border/60 py-12">
      <Container className="flex flex-col items-center justify-between gap-4 text-sm text-muted-foreground sm:flex-row">
        <div className="flex items-center gap-2">
          <TerminalIcon className="size-4 text-brand" />
          <span>kix — taking the complexity out of Kubernetes</span>
        </div>
        <div className="flex gap-5">
          <a href="#why-k8s" className="transition-colors hover:text-foreground">Why Kubernetes</a>
          <a href="#why-kix" className="transition-colors hover:text-foreground">Why kix</a>
          <a href="#how" className="transition-colors hover:text-foreground">How it works</a>
        </div>
      </Container>
    </footer>
  )
}

/* ------------------------------------------------------------------ */
/*  Page                                                               */
/* ------------------------------------------------------------------ */
export default function Landing() {
  return (
    <div className="min-h-screen overflow-x-clip bg-background text-foreground">
      <Nav />
      <main>
        <Hero />
        <WhyKubernetes />
        <WhyKix />
        <Adoption />
        <HowItWorks />
        <CTA />
      </main>
      <Footer />
    </div>
  )
}

import { Bot, ShieldCheck } from "lucide-react"
import {
  Container,
  Reveal,
  SectionHeading,
  Terminal,
} from "@/components/landing/primitives"

type TerminalLine = {
  tokens: { t: string; c?: "p" | "ok" | "err" | "wn" | "cm" | "str" }[]
}

const checkLines: TerminalLine[] = [
  { tokens: [{ t: "$ kix check", c: "p" }] },
  {
    tokens: [
      { t: "  ✓ ", c: "ok" },
      { t: "evaluated 47 resources across 12 packages" },
    ],
  },
  {
    tokens: [
      { t: "  ✗ ", c: "err" },
      { t: "Service api-svc: selector matches zero pods" },
    ],
  },
  {
    tokens: [{ t: "      service    api-svc     selects   app=api-server" }],
  },
  {
    tokens: [{ t: "      deployment api-server  labels    app=apiserver" }],
  },
  {
    tokens: [
      { t: "      → likely typo: app=apiserver vs app=api-server", c: "wn" },
    ],
  },
  {
    tokens: [
      { t: "  ✗ ", c: "err" },
      { t: "Deployment worker: secret `stripe-keys` is not defined" },
    ],
  },
  { tokens: [{ t: "  ✗ build failed: 2 errors", c: "err" }] },
  { tokens: [] },
  {
    tokens: [
      { t: "$ kix check        ", c: "p" },
      { t: "# after the fix", c: "cm" },
    ],
  },
  {
    tokens: [
      { t: "  ✓ all selectors resolve, all references exist", c: "ok" },
    ],
  },
  { tokens: [{ t: "  ✓ 0 errors, safe to preview", c: "ok" }] },
]

const steps = [
  {
    title: "Define",
    body: "Describe your whole stack in one declarative definition. Concise, readable, reviewable in a pull request.",
  },
  {
    title: "Check",
    body: "Kix evaluates the entire configuration and catches errors at compile time. Feedback in seconds, locally, before CI and before deploy.",
  },
  {
    title: "Preview",
    body: 'See the exact diff between your definition and the live cluster. No "apply and pray."',
  },
  {
    title: "Deploy",
    body: "Ship the verified artifact, exactly as previewed.",
  },
]

export default function Mechanism() {
  return (
    <section id="how-it-works" className="bg-(--surface-tint) py-24 sm:py-28">
      <Container>
        <SectionHeading
          kicker="How it works"
          title="Under the hood, Kix is a Kubernetes compiler"
          lede="Kix is not a dashboard over the same old YAML. You define your stack declaratively; Kix compiles it into standard Kubernetes resources, and like a compiler, it refuses to build a definition that doesn't hold together. Structural checks and hard-won per-tool sanity checks all run at compile time, on your laptop, not in production."
        />

        <div className="mt-14 grid gap-8 md:grid-cols-4">
          {steps.map((step, i) => (
            <Reveal key={step.title} delay={i} className="relative">
              {i < steps.length - 1 && (
                <div className="absolute top-4.5 left-12 right-0 hidden h-px bg-gradient-to-r from-brand/30 to-transparent md:block" />
              )}
              <div className="flex size-9 items-center justify-center rounded-full border border-brand/30 bg-brand/5 font-mono text-sm font-semibold text-brand">
                {i + 1}
              </div>
              <h3 className="mt-4 font-semibold">{step.title}</h3>
              <p className="mt-1.5 text-sm leading-relaxed text-muted-foreground">
                {step.body}
              </p>
            </Reveal>
          ))}
        </div>

        <Reveal delay={1} className="mt-14">
          <Terminal
            title="kix check"
            lines={checkLines}
            className="mx-auto max-w-3xl"
          />
          <p className="mt-3 text-center text-xs text-muted-foreground">
            The selector typo that raw kubectl ships to production, Kix refuses
            to compile.
          </p>
        </Reveal>

        <Reveal delay={2}>
          <div className="mx-auto mt-14 max-w-3xl rounded-2xl border border-border bg-card p-7 sm:p-8">
            <div className="flex size-9 items-center justify-center rounded-lg bg-brand-soft text-brand">
              <Bot className="size-4.5" />
            </div>
            <h3 className="mt-4 font-semibold text-foreground">
              Bring your coding agent.
            </h3>
            <p className="mt-2 leading-relaxed text-muted-foreground">
              Agents write Kix well: the definition is compact and typed, and
              kix check gives an agent the same fast, local feedback it gives
              you. A hallucinated selector doesn't reach your cluster; it
              fails to compile, the agent reads the error and fixes it before
              you ever see it.
            </p>
          </div>
        </Reveal>

        <Reveal delay={3}>
          <div className="mx-auto mt-4 max-w-3xl rounded-2xl border border-border bg-card p-7 sm:p-8">
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
              standard manifests. Leaving Kix means losing the tooling, not
              your infrastructure.
            </p>
          </div>
        </Reveal>
      </Container>
    </section>
  )
}

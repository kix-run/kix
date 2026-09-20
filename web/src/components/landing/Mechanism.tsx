import {
  Activity,
  ArrowLeftRight,
  BadgeCheck,
  Bot,
  Check,
  Database,
  DatabaseBackup,
  Eye,
  FileCheck,
  FileCode2,
  KeyRound,
  Network,
  Rocket,
  UserCheck,
  type LucideIcon,
} from "lucide-react";
import {
  Container,
  Reveal,
  SectionHeading,
  Terminal,
} from "@/components/landing/primitives";

type TerminalLine = {
  tokens: { t: string; c?: "p" | "ok" | "err" | "wn" | "cm" | "str" }[];
};

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
    tokens: [{ t: "  ✓ all selectors resolve, all references exist", c: "ok" }],
  },
  { tokens: [{ t: "  ✓ 0 errors, safe to preview", c: "ok" }] },
];

const previewLines: TerminalLine[] = [
  { tokens: [{ t: "$ kix diff production", c: "p" }] },
  {
    tokens: [
      { t: "  " },
      { t: "✓", c: "ok" },
      { t: " evaluated 47 resources across 12 packages" },
    ],
  },
  { tokens: [{ t: "  " }, { t: "✓ 0 errors", c: "ok" }] },
  { tokens: [] },
  { tokens: [{ t: "  " }, { t: "~", c: "wn" }, { t: " Deployment api" }] },
  {
    tokens: [
      { t: "      image: ghcr.io/acme-co/api:v1.4.2 → " },
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
];

// Titles and icons carry the hero's former chip-pipeline labels;
// this grid is now the page's single 4-step flow.
const steps: { title: string; body: string; icon: LucideIcon }[] = [
  {
    title: "Define your stack",
    icon: FileCode2,
    body: "Describe your services, databases, and their connections in one definition.",
  },
  {
    title: "Compile & check",
    icon: BadgeCheck,
    body: "Run checks on your laptop before committing. Kix checks your definition and generates resources for networking, storage, backups, and certificates.",
  },
  {
    title: "Preview",
    icon: Eye,
    body: "Review the changes to your cluster before applying them.",
  },
  {
    title: "Deploy",
    icon: Rocket,
    body: "Deploy the verified build you reviewed. Repeat these steps for each update.",
  },
];

const features: { title: string; body: string; icon: LucideIcon }[] = [
  {
    title: "Backups",
    body: "backup.enabled = true: scheduled, stored off-cluster, restorable.",
    icon: DatabaseBackup,
  },
  {
    title: "Integrated secrets",
    body: "Defined once in your stack, injected wherever they're referenced.",
    icon: KeyRound,
  },
  {
    title: "Monitoring & alerting",
    body: "Metrics, dashboards, and alert rules included.",
    icon: Activity,
  },
  {
    title: "Automated migrations",
    body: "Stateful workloads move within the cluster, or to another cluster on another provider.",
    icon: ArrowLeftRight,
  },
  {
    title: "Human-in-the-loop fixes",
    body: "Kix proposes a fix for you to review.",
    icon: UserCheck,
  },
  {
    title: "Managed services in-cluster",
    body: "Production Postgres and Redis on machines you already pay for, operator-run.",
    icon: Database,
  },
  {
    title: "Network & security policies",
    body: "Generated from the connections between services in your definition.",
    icon: Network,
  },
  {
    title: "Compliance evidence",
    body: "Audit evidence as a build output: SBOM, provenance, findings mapped to your framework.",
    icon: FileCheck,
  },
];

const agentFacilities = [
  <>MCP server for checks, schemas, and package discovery</>,
  <>Docs available as markdown and via MCP</>,
  <>Errors an agent can read and act on</>,
  <>Compact, typed definitions agents write well</>,
];

function AgentLoop() {
  return (
    <div className="overflow-hidden rounded-xl border border-zinc-800 bg-[#0b0f1a] shadow-2xl shadow-emerald-950/20 ring-1 ring-white/5">
      <div className="flex items-center gap-2 border-b border-zinc-800 bg-zinc-900/60 px-4 py-3">
        <span className="size-3 rounded-full bg-zinc-700" />
        <span className="size-3 rounded-full bg-zinc-700" />
        <span className="size-3 rounded-full bg-zinc-700" />
        <span className="ml-2 font-mono text-xs text-zinc-500">
          kix + your agent
        </span>
      </div>
      <pre className="overflow-x-auto px-4 py-3 font-mono text-[0.74rem] leading-relaxed sm:px-5 sm:py-4 sm:text-[0.8rem]">
        <code>
          <span className="block">
            <span className="text-zinc-500">❱ </span>
            <span className="text-zinc-100">
              "Add a Redis cache to staging"
            </span>
          </span>
          <span className="block text-zinc-400">
            {"  agent writes instances.app.redis"}
          </span>
          <span className="block text-zinc-400">
            {"  agent runs kix check"}
          </span>
          <span className="block text-rose-400">
            {"  ✗ secret redis-auth is not defined"}
          </span>
          <span className="block text-zinc-400">
            {"  agent securely adds the secret, checks again"}
          </span>
          <span className="block text-emerald-400">
            {"  ✓ 0 errors, safe to preview"}
          </span>
        </code>
      </pre>
    </div>
  );
}

export default function Mechanism() {
  return (
    <section id="how-it-works" className="py-24 sm:py-28">
      <Container>
        <SectionHeading
          kicker="How it works"
          title="The compiler refuses to build a broken stack"
          lede="Kix compiles your definition into standard Kubernetes resources, and refuses to build one that doesn't hold together. Mismatched selectors, missing secrets, or a dependency nothing provides, all will stop the build before anything deploys."
        />

        <div className="mt-14 grid gap-8 md:grid-cols-4">
          {steps.map((step, i) => (
            <Reveal key={step.title} delay={i} className="relative">
              {i < steps.length - 1 && (
                <div className="absolute top-4.5 left-12 right-0 hidden h-px bg-gradient-to-r from-brand/30 to-transparent md:block" />
              )}
              <div className="flex size-9 items-center justify-center rounded-full border border-brand/30 bg-brand/5 text-brand">
                <step.icon className="size-4" />
              </div>
              <h3 className="mt-4 font-semibold">{step.title}</h3>
              <p className="mt-1.5 text-sm leading-relaxed text-muted-foreground">
                {step.body}
              </p>
            </Reveal>
          ))}
        </div>

        <div className="mt-14 grid items-start gap-8 lg:grid-cols-2">
          <Reveal delay={1} className="min-w-0">
            <Terminal title="kix check" lines={checkLines} />
            <p className="mt-3 text-center text-xs text-muted-foreground">
              The selector typo that raw kubectl ships to production, Kix
              refuses to compile.
            </p>
          </Reveal>
          <Reveal delay={2} className="min-w-0">
            <Terminal title="kix diff" lines={previewLines} />
            <p className="mt-3 text-center text-xs text-muted-foreground">
              Preview the exact changes before they happen. What you previewed
              is what runs.
            </p>
          </Reveal>
        </div>

        <Reveal delay={1} className="mt-20">
          <h3 className="text-balance text-2xl font-semibold tracking-tight text-foreground sm:text-3xl">
            Handled for you
          </h3>
        </Reveal>
        <div className="mt-8 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {features.map((feature, i) => (
            <Reveal key={feature.title} delay={i % 3}>
              <div className="h-full rounded-2xl border border-border bg-card p-6">
                <div className="flex size-9 items-center justify-center rounded-lg bg-brand-soft text-brand">
                  <feature.icon className="size-4.5" />
                </div>
                <h4 className="mt-4 font-semibold tracking-tight text-foreground">
                  {feature.title}
                </h4>
                <p className="mt-1.5 text-sm leading-relaxed text-muted-foreground">
                  {feature.body}
                </p>
              </div>
            </Reveal>
          ))}
        </div>

        <div
          id="agents"
          className="mt-20 grid items-center gap-10 scroll-mt-24 lg:grid-cols-2 lg:gap-16"
        >
          <Reveal>
            <div className="flex size-9 items-center justify-center rounded-lg bg-brand-soft text-brand">
              <Bot className="size-4.5" />
            </div>
            <h3 className="mt-4 text-balance text-2xl font-semibold tracking-tight text-foreground sm:text-3xl">
              Bring your coding agent.
            </h3>
            <p className="mt-3 leading-relaxed text-muted-foreground">
              Coding agents can write definitions and run kix check locally.
              The compiler reports errors such as mismatched selectors and
              missing secrets, so the agent can revise the definition. You
              review the changes before deploying.
            </p>
            <ul className="mt-5 space-y-2 text-sm text-muted-foreground">
              {agentFacilities.map((item, i) => (
                <li key={i} className="flex items-start gap-2.5">
                  <Check className="mt-0.5 size-4 shrink-0 text-brand" />
                  <span>{item}</span>
                </li>
              ))}
            </ul>
          </Reveal>
          <Reveal delay={1} className="min-w-0">
            <AgentLoop />
            <p className="mt-3 text-center text-xs text-muted-foreground">
              The agent adds Redis and uses the compiler error to identify
              a missing secret.
            </p>
          </Reveal>
        </div>
      </Container>
    </section>
  );
}

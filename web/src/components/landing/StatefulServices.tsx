import { useState } from "react"
import {
  AgentToggle,
  Container,
  Reveal,
  SectionHeading,
} from "@/components/landing/primitives"

// Token color shorthands matching the hero's hand-tokenized nix snippet.
const K = "text-foreground/75" // keys
const V = "text-brand" // values / strings
const P = "text-muted-foreground/70" // punctuation
const R = "text-(--code-ref)" // references

type PaneView = "code" | "agent"

function AgentPane() {
  return (
    <div className="px-5 py-4">
      <pre className="overflow-x-auto font-mono text-[0.8rem] leading-relaxed">
        <code>
          <span className="block">
            <span className="text-muted-foreground/70">❱ </span>
            <span className="text-foreground/90">
              "Add a production database for the api"
            </span>
          </span>
          <span className="block text-muted-foreground">
            {'  agent: "Postgres or MySQL? For Postgres I'}
          </span>
          <span className="block text-muted-foreground">
            {'          can use CloudNativePG or StackGres"'}
          </span>
          <span className="block">
            <span className="text-muted-foreground/70">❱ </span>
            <span className="text-foreground/90">
              "Postgres 18 on StackGres"
            </span>
          </span>
          <span className="block text-muted-foreground">
            {"  agent writes instances.data.postgres"}
          </span>
          <span className="block text-muted-foreground">
            {"  agent runs kix check"}
          </span>
          <span className="block text-destructive">
            {"  ✗ production stateful service has no backup configured"}
          </span>
          <span className="block text-muted-foreground">
            {"  agent sets backup.enabled = true, checks again"}
          </span>
          <span className="block text-brand">
            {"  ✓ 0 errors, safe to preview"}
          </span>
        </code>
      </pre>
      <div className="mt-4 border-t border-border pt-4">
        <p className="text-sm leading-relaxed text-muted-foreground">
          The agent picks from Kix's package library, so it only offers
          what it can deploy. What it writes passes the same checks as what
          you write: storage, backups, and failover wiring are verified
          before anything touches the cluster.
        </p>
      </div>
    </div>
  )
}

function CodeCard({
  view,
  setView,
}: {
  view: PaneView
  setView: (v: PaneView) => void
}) {
  return (
    <div className="overflow-hidden rounded-xl border border-border bg-card shadow-xl shadow-zinc-950/5 ring-1 ring-foreground/5">
      <div className="flex items-center gap-2 border-b border-border bg-muted/50 px-4 py-2">
        <span className="size-3 rounded-full bg-border" />
        <span className="size-3 rounded-full bg-border" />
        <span className="size-3 rounded-full bg-border" />
        <span className="ml-2 font-mono text-xs text-muted-foreground">
          {view === "code" ? "stack.nix" : "kix + your agent"}
        </span>
        <AgentToggle
          active={view === "agent"}
          onClick={() => setView(view === "code" ? "agent" : "code")}
        />
      </div>
      {view === "agent" ? (
        <AgentPane />
      ) : (
      <pre className="overflow-x-auto px-5 py-4 font-mono text-[0.8rem] leading-relaxed">
        <code>
          <span className="block">
            <span className={K}>instances.data.postgres</span>
            <span className={P}>{" = {"}</span>
          </span>
          <span className="block">
            <span className={K}>{"  package"}</span>
            <span className={P}>{" = "}</span>
            <span className={R}>packages.postgres</span>
            <span className={P}>;</span>
          </span>
          <span className="block">
            <span className={K}>{"  config"}</span>
            <span className={P}>{" = {"}</span>
          </span>
          <span className="block">
            <span className={K}>{"    version"}</span>
            <span className={P}>{"                = "}</span>
            <span className={V}>18</span>
            <span className={P}>;</span>
          </span>
          <span className="block">
            <span className={K}>{"    instanceProfile.cpu"}</span>
            <span className={P}>{"    = "}</span>
            <span className={V}>8</span>
            <span className={P}>;</span>
          </span>
          <span className="block">
            <span className={K}>{"    instanceProfile.memory"}</span>
            <span className={P}>{" = "}</span>
            <span className={V}>{'"32Gi"'}</span>
            <span className={P}>;</span>
          </span>
          <span className="block">
            <span className={K}>{"    storage.size"}</span>
            <span className={P}>{"           = "}</span>
            <span className={V}>{'"200Gi"'}</span>
            <span className={P}>;</span>
          </span>
          <span className="block">
            <span className={K}>{"    backup.enabled"}</span>
            <span className={P}>{"         = "}</span>
            <span className={V}>true</span>
            <span className={P}>;</span>
          </span>
          <span className="block">
            <span className={P}>{"  };"}</span>
          </span>
          <span className="block">
            <span className={P}>{"};"}</span>
          </span>
          <span className="block"> </span>
          <span className="block">
            <span className={K}>instances.data.cache</span>
            <span className={P}>{" = {"}</span>
          </span>
          <span className="block">
            <span className={K}>{"  package"}</span>
            <span className={P}>{" = "}</span>
            <span className={R}>packages.redis</span>
            <span className={P}>;</span>
          </span>
          <span className="block">
            <span className={K}>{"  config.persistence.size"}</span>
            <span className={P}>{" = "}</span>
            <span className={V}>{'"8Gi"'}</span>
            <span className={P}>;</span>
          </span>
          <span className="block">
            <span className={P}>{"};"}</span>
          </span>
        </code>
      </pre>
      )}
    </div>
  )
}

const points = [
  {
    title: "Skip the managed-database markup",
    body: "RDS-class services charge several times the cost of the compute they run on. On your cluster, your database runs on machines you already pay for.",
  },
  {
    title: "No instance tiers",
    body: "Your database isn't pinned to a vendor's instance classes. Give it the cores, memory, and storage your workload needs, and change them by editing a number.",
  },
  {
    title: "Backups are one setting",
    body: "backup.enabled = true gets you scheduled backups to object storage. Failover and recovery come from the same production-grade operators specialists deploy by hand; Kix wires them in for you.",
  },
]

export default function StatefulServices() {
  const [view, setView] = useState<PaneView>("code")
  return (
    <section id="stateful" className="bg-(--surface-tint) py-24 sm:py-28">
      <Container>
        <SectionHeading
          kicker="Stateful services"
          title="Postgres and Redis without the managed-database bill"
          lede="Running stateful services on Kubernetes used to be specialist work: operators, storage, failover, backup jobs. Kix packages that work, so a production Postgres or Redis is a few lines in your stack definition."
        />

        <div className="mt-14 grid items-start gap-10 lg:grid-cols-2 lg:gap-16">
          <Reveal>
            <CodeCard view={view} setView={setView} />
            <p className="mt-3 text-center text-xs text-muted-foreground">
              {view === "code"
                ? "A production database with scheduled backups, in one reviewable block."
                : "Stateful mistakes fail the check, not your database."}
            </p>
          </Reveal>

          <div className="space-y-8">
            {points.map((point, i) => (
              <Reveal key={point.title} delay={i + 1}>
                <h3 className="font-semibold tracking-tight text-foreground">
                  {point.title}
                </h3>
                <p className="mt-2 leading-relaxed text-muted-foreground">
                  {point.body}
                </p>
              </Reveal>
            ))}
            <Reveal delay={4}>
              <p className="text-sm leading-relaxed text-muted-foreground/80">
                Prefer a managed database? Kix connects to RDS or Cloud SQL
                just the same. Running state on the cluster is a choice Kix
                makes safe, not a requirement.
              </p>
            </Reveal>
          </div>
        </div>
      </Container>
    </section>
  )
}

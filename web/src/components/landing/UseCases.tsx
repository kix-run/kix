import { type ReactNode } from "react"
import { Accordion } from "radix-ui"
import { motion } from "motion/react"
import {
  ArrowRight,
  ChevronDown,
  Cloud,
  FileCheck,
  MessageCircle,
  SlidersHorizontal,
  TrendingDown,
  type LucideIcon,
} from "lucide-react"
import { Button } from "@/components/ui/button"
import {
  Container,
  Reveal,
  SectionHeading,
} from "@/components/landing/primitives"
import { cn } from "@/lib/utils"

function preselectUseCase(value: string) {
  window.dispatchEvent(
    new CustomEvent("kix:preselect-usecase", { detail: value }),
  )
}

function UseCaseCta({
  label,
  preselect,
}: {
  label: string
  preselect: string
}) {
  return (
    <Button asChild className="mt-6">
      <a href="#early-access" onClick={() => preselectUseCase(preselect)}>
        {label}
        <ArrowRight className="size-4" />
      </a>
    </Button>
  )
}

// ── Cost bars (folded in from the old CostComparison section) ──────────────

type CostRow = {
  name: string
  providers: string
  price: string
  multiple?: string
  /** Bar width as % of the track; longest bar is 72% so the price fits inline. */
  pct: number
  note: string
  highlight?: boolean
}

const costRows: CostRow[] = [
  {
    name: "Managed PaaS",
    providers: "Heroku, Render, Fly",
    price: "$5,400",
    multiple: "~21x",
    pct: 72,
    note: "Performance-tier instances at published list prices. You are paying for the machines and for not having to think about them.",
  },
  {
    name: "Hyperscaler",
    providers: "AWS, GCP, Azure",
    price: "$3,000",
    multiple: "~12x",
    pct: 40,
    note: "Equivalent on-demand instances. Cheaper machines, but the operating burden is now yours.",
  },
  {
    name: "Bare metal",
    providers: "Hetzner, OVH",
    price: "$260",
    pct: 3.5,
    note: "A single dedicated EPYC machine. The same compute your PaaS rents you, at cost.",
    highlight: true,
  },
]

function CostBars() {
  return (
    <div className="space-y-7">
      {costRows.map((row, index) => (
        <div
          key={row.name}
          className="grid gap-x-6 gap-y-2 sm:grid-cols-[10rem_1fr] sm:items-start"
        >
          <div className="sm:pt-1">
            <h4 className="text-sm font-semibold tracking-tight text-foreground">
              {row.name}
            </h4>
            <p className="mt-0.5 text-xs text-muted-foreground">
              {row.providers}
            </p>
          </div>
          <div>
            <div className="flex items-baseline gap-3">
              <motion.div
                className={cn(
                  "h-7 min-w-1.5 self-center rounded-md",
                  row.highlight ? "bg-brand" : "bg-foreground/[0.18]",
                )}
                style={{ width: `${row.pct}%`, originX: 0 }}
                initial={{ scaleX: 0 }}
                whileInView={{ scaleX: 1 }}
                viewport={{ once: true }}
                transition={{
                  duration: 0.8,
                  delay: 0.1 + index * 0.12,
                  ease: [0.21, 0.5, 0.27, 1],
                }}
              />
              <span
                className={cn(
                  "font-mono text-xl font-semibold tracking-tight",
                  row.highlight ? "text-brand" : "text-foreground",
                )}
              >
                {row.price}
              </span>
              {row.multiple && (
                <span className="font-mono text-xs text-muted-foreground">
                  {row.multiple}
                </span>
              )}
            </div>
            <p className="mt-1.5 max-w-xl text-sm leading-relaxed text-muted-foreground">
              {row.note}
            </p>
          </div>
        </div>
      ))}
    </div>
  )
}

// ── Use cases ───────────────────────────────────────────────────────────────

const items: {
  title: string
  teaser: string
  icon: LucideIcon
  body: ReactNode
}[] = [
  {
    title: "Deploy into your customer's cloud",
    teaser: "The enterprise-deal question, answered with one definition.",
    icon: Cloud,
    body: (
      <>
        <p>
          For B2B startups, "can you deploy into our environment?" is the
          question that stalls enterprise deals. With a PaaS, the answer is
          no. With Kix, your product is a verifiable cluster artifact: the
          same definition that runs your SaaS deploys into a customer's AWS
          account, their data center, or their private cloud, and their
          security team reviews a concrete artifact instead of a black box.
          When the next customer asks, it's the same definition with
          different settings, not another project.
        </p>
        <p className="mt-4 font-medium text-foreground">
          One stack definition. Your cloud, their cloud, their basement.
        </p>
        <UseCaseCta
          label="I need customer-hosted deploys"
          preselect="customer-infra"
        />
      </>
    ),
  },
  {
    title: "Cut the infrastructure bill",
    teaser: "The same hardware, three very different price tags.",
    icon: TrendingDown,
    body: (
      <>
        <p className="mb-7">
          Most startups never see what the hardware underneath them costs.
          Here is roughly the same compute, 96 vCPUs and 256 GB of memory,
          per month at public list prices:
        </p>
        <CostBars />
        <p className="mt-6 max-w-xl text-sm leading-relaxed">
          Managed databases carry the same markup: RDS-class services charge
          several times the cost of the compute they run on. On your
          cluster, Postgres runs on machines you already pay for.
        </p>
        <p className="mt-4 max-w-xl text-sm leading-relaxed">
          And moving off is a migration, not a rewrite. Your containers stay
          your containers; they just land on infrastructure you own.
        </p>
        <p className="mt-5 max-w-xl text-xs leading-relaxed text-muted-foreground/80">
          Raw compute at published list prices, checked June 2026. This is
          the hardware gap, not an all-in bill: redundancy, storage, and
          traffic are extra on every tier, and bare metal support is a paid
          Kix add-on. Kix pricing is settling during early access, with one
          aim fixed: Kix plus your own infrastructure should cost well under
          the PaaS bill it replaces.
        </p>
        <UseCaseCta label="I want off the PaaS bill" preselect="paas" />
      </>
    ),
  },
  {
    title: "Own your stack, and scale it",
    teaser: "No platform limits, and no re-architecture to grow.",
    icon: SlidersHorizontal,
    body: (
      <>
        <p>
          No platform-imposed limits on processes, networking, background
          jobs, or runtime versions. Your architecture is your decision, not
          a tier on someone's pricing page. And the cluster that runs your
          two services today runs two hundred later: autoscaling, rolling
          deploys, and self-healing are built in, so growth is more replicas,
          not a re-architecture.
        </p>
      </>
    ),
  },
  {
    title: "Compliance without the scramble",
    teaser: "SBOM, provenance, and findings from the same build.",
    icon: FileCheck,
    body: (
      <>
        <p>
          Because Kix compiles your whole stack, it knows every image,
          package, and setting in production. One command produces the bundle
          your auditor asked for: a software bill of materials, build
          provenance, and findings mapped to SOC 2, ISO 27001, DORA, or NIS2.
          The evidence is derived from the same build that produced your
          cluster, so it is current by construction: regenerate it on any
          commit and it describes exactly what is running.
        </p>
      </>
    ),
  },
  {
    title: "Don't see your use case?",
    teaser: "We're onboarding early teams one conversation at a time.",
    icon: MessageCircle,
    body: (
      <>
        <p>
          Tell us what you're trying to do. We're onboarding early teams one
          conversation at a time, and the use cases beyond the obvious ones
          are the ones we most want to hear about.
        </p>
        <UseCaseCta label="Tell us about it" preselect="other" />
      </>
    ),
  },
]

export default function UseCases() {
  return (
    <section id="use-cases" className="bg-(--surface-tint) py-24 sm:py-28">
      <Container>
        <SectionHeading
          kicker="Use cases"
          title="Why teams use Kix"
          lede="Sooner or later the starter platforms stop fitting: the bill crosses five figures, a big customer asks to host your product themselves, or the architecture outgrows what a PaaS allows. Growing into proper infrastructure is the hard step. These are the jobs teams bring to Kix."
        />

        <Reveal delay={1} className="mt-12">
          <Accordion.Root type="single" collapsible defaultValue="usecase-1">
            {items.map((item, i) => (
              <Accordion.Item
                key={item.title}
                value={`usecase-${i + 1}`}
                className="border-b border-border"
              >
                <Accordion.Header asChild>
                  <Accordion.Trigger className="group flex w-full cursor-pointer items-center gap-4 py-5 text-left">
                    <span className="flex size-9 shrink-0 items-center justify-center rounded-lg bg-brand-soft text-brand">
                      <item.icon className="size-4.5" />
                    </span>
                    <span className="min-w-0 flex-1">
                      <span className="block text-lg font-medium tracking-tight text-foreground transition-colors group-hover:text-brand">
                        {item.title}
                      </span>
                      <span className="mt-0.5 block text-sm text-muted-foreground">
                        {item.teaser}
                      </span>
                    </span>
                    <ChevronDown className="size-5 shrink-0 text-muted-foreground transition-transform duration-200 group-data-[state=open]:rotate-180" />
                  </Accordion.Trigger>
                </Accordion.Header>
                <Accordion.Content className="overflow-hidden leading-relaxed text-muted-foreground data-[state=open]:animate-accordion-down data-[state=closed]:animate-accordion-up">
                  <div className="max-w-3xl pb-8 pl-[3.25rem] pr-8">
                    {item.body}
                  </div>
                </Accordion.Content>
              </Accordion.Item>
            ))}
          </Accordion.Root>
        </Reveal>
      </Container>
    </section>
  )
}

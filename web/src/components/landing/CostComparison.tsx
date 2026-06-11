import { motion } from "motion/react"
import { Container, Reveal, SectionHeading } from "@/components/landing/primitives"
import { cn } from "@/lib/utils"

type Row = {
  name: string
  providers: string
  price: string
  multiple?: string
  /** Bar width as % of the track; longest bar is 72% so the price fits inline. */
  pct: number
  note: string
  highlight?: boolean
}

const rows: Row[] = [
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

export default function CostComparison() {
  return (
    <section id="cost" className="bg-(--surface-tint) py-24 sm:py-28">
      <Container>
        <SectionHeading
          kicker="What providers charge"
          title="The same servers, three very different bills"
          lede="Most startups never see what they pay for convenience. Here is roughly the same compute, 96 vCPUs and 256 GB of memory, per month at public list prices."
        />

        <div className="mt-14 space-y-10">
          {rows.map((row, index) => (
            <Reveal key={row.name} delay={index}>
              <div className="grid gap-x-6 gap-y-2 sm:grid-cols-[11rem_1fr] sm:items-start">
                <div className="sm:pt-1.5">
                  <h3 className="text-sm font-semibold tracking-tight text-foreground">
                    {row.name}
                  </h3>
                  <p className="mt-0.5 text-xs text-muted-foreground">
                    {row.providers}
                  </p>
                </div>
                <div>
                  <div className="flex items-baseline gap-3">
                    <motion.div
                      className={cn(
                        "h-8 min-w-1.5 self-center rounded-md",
                        row.highlight ? "bg-brand" : "bg-foreground/[0.18]",
                      )}
                      style={{ width: `${row.pct}%`, originX: 0 }}
                      initial={{ scaleX: 0 }}
                      whileInView={{ scaleX: 1 }}
                      viewport={{ once: true, margin: "-80px" }}
                      transition={{
                        duration: 0.8,
                        delay: 0.2 + index * 0.12,
                        ease: [0.21, 0.5, 0.27, 1],
                      }}
                    />
                    <span
                      className={cn(
                        "font-mono text-2xl font-semibold tracking-tight",
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
                  <p className="mt-2 max-w-xl text-sm leading-relaxed text-muted-foreground">
                    {row.note}
                  </p>
                </div>
              </div>
            </Reveal>
          ))}
        </div>

        <Reveal delay={1} className="mt-12">
          <p className="text-xs text-muted-foreground/80">
            Illustrative monthly list prices, checked against published
            pricing in June 2026. Exact costs vary by workload and provider;
            the relative gap between the tiers is consistent.
          </p>
        </Reveal>

      </Container>
    </section>
  )
}

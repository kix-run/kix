import { Container, Reveal, SectionHeading } from "@/components/landing/primitives"
import { cn } from "@/lib/utils"

type Tier = {
  name: string
  providers: string
  price: string
  multiple: string
  body: string
  highlight?: boolean
}

const tiers: Tier[] = [
  {
    name: "Managed PaaS",
    providers: "Heroku, Render, Fly",
    price: "$5,400",
    multiple: "~21x",
    body: "Performance-tier instances at published list prices. You are paying for the machines and for not having to think about them.",
  },
  {
    name: "Hyperscaler",
    providers: "AWS, GCP, Azure",
    price: "$3,000",
    multiple: "~12x",
    body: "Equivalent on-demand instances. Cheaper machines, but the operating burden is now yours.",
  },
  {
    name: "Bare metal",
    providers: "Hetzner, OVH",
    price: "$260",
    multiple: "1x",
    body: "A single dedicated EPYC machine. The same compute your PaaS rents you, at cost.",
    highlight: true,
  },
]

export default function CostComparison() {
  return (
    <section id="cost" className="bg-(--surface-tint) py-24 sm:py-28">
      <Container>
        <SectionHeading
          kicker="What compute actually costs"
          title="The same servers, three very different bills"
          lede="Most startups never see what they pay for convenience. Here is roughly the same compute, 96 vCPUs and 256 GB of memory, at public list prices."
        />

        <div className="mt-14 grid gap-4 md:grid-cols-3">
          {tiers.map((tier, index) => (
            <Reveal key={tier.name} delay={index}>
              <div
                className={cn(
                  "flex h-full flex-col rounded-2xl border p-7",
                  tier.highlight
                    ? "border-brand/40 bg-brand/[0.04] shadow-[0_2px_24px_color-mix(in_srgb,var(--brand)_7%,transparent)]"
                    : "border-border bg-card",
                )}
              >
                <div className="flex items-center justify-between">
                  <h3 className="font-semibold tracking-tight text-foreground">
                    {tier.name}
                  </h3>
                  <span
                    className={cn(
                      "rounded-full px-2.5 py-0.5 font-mono text-xs font-medium",
                      tier.highlight
                        ? "bg-brand-soft text-brand"
                        : "bg-muted text-muted-foreground",
                    )}
                  >
                    {tier.multiple}
                  </span>
                </div>
                <p className="mt-1 text-sm text-muted-foreground">
                  {tier.providers}
                </p>
                <p className="mt-6 text-4xl font-semibold tracking-tight text-foreground">
                  {tier.price}
                  <span className="ml-1 text-sm font-normal text-muted-foreground">
                    /month
                  </span>
                </p>
                <p className="mt-4 text-sm leading-relaxed text-muted-foreground">
                  {tier.body}
                </p>
              </div>
            </Reveal>
          ))}
        </div>

        <Reveal delay={1} className="mt-4">
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

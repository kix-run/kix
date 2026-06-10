import { ArrowUpRight, Building2, Users, type LucideIcon } from "lucide-react"
import { Container, Reveal, SectionHeading } from "@/components/landing/primitives"

type Card = {
  title: string
  body: string
  icon: LucideIcon
}

const cards: Card[] = [
  {
    title: "Shipping into customer infrastructure",
    body: "Your enterprise prospects want your product in their VPC or data center. With Kix, your entire stack is a checked, versioned definition that deploys the same way into any Kubernetes environment, yours or theirs. Customer-hosted stops being a special build.",
    icon: Building2,
  },
  {
    title: "Moving off a PaaS",
    body: "Heroku, Render, or Fly was right at the start. Now the bill is climbing and the platform's limits are shaping your architecture. Kix gets you onto your own Kubernetes, on the cloud or bare metal of your choice, without trading a big bill for a big ops burden.",
    icon: ArrowUpRight,
  },
  {
    title: "Kubernetes without a platform team",
    body: "You know you'll need Kubernetes; you don't want it to consume an engineer. Kix comes with load balancing, TLS, databases, and the deployment pipeline already wired together, with defaults chosen by people who run production clusters. Your team ships product; the platform stays boring.",
    icon: Users,
  },
]

export default function UseCases() {
  return (
    <section id="use-cases" className="py-24 sm:py-28">
      <Container>
        <SectionHeading
          kicker="Who it's for"
          title="Built for the moment your current setup stops being enough"
        />

        <div className="mt-14 grid gap-4 md:grid-cols-3">
          {cards.map((card, index) => (
            <Reveal key={card.title} delay={index}>
              <div className="group relative h-full overflow-hidden rounded-2xl border border-border bg-card p-6 transition-all duration-300 hover:-translate-y-0.5 hover:shadow-[0_2px_16px_rgba(0,0,0,0.05)]">
                <div className="absolute inset-0 opacity-0 transition-opacity duration-300 group-hover:opacity-100">
                  <div className="absolute inset-0 bg-[radial-gradient(circle_at_center,color-mix(in_srgb,var(--foreground)_4%,transparent)_1px,transparent_1px)] bg-[length:4px_4px]" />
                </div>
                <div className="relative">
                  <div className="flex size-9 items-center justify-center rounded-lg bg-brand-soft text-brand">
                    <card.icon className="size-4.5" />
                  </div>
                  <h3 className="mt-4 font-semibold tracking-tight text-foreground">
                    {card.title}
                  </h3>
                  <p className="mt-2 text-sm leading-relaxed text-muted-foreground">
                    {card.body}
                  </p>
                </div>
              </div>
            </Reveal>
          ))}
        </div>
      </Container>
    </section>
  )
}

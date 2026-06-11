import {
  Globe,
  SlidersHorizontal,
  TrendingUp,
  type LucideIcon,
} from "lucide-react"
import { Container, Reveal, SectionHeading } from "@/components/landing/primitives"
import { cn } from "@/lib/utils"

type Card = {
  title: string
  body: string
  icon: LucideIcon
  span: string
}

const cards: Card[] = [
  {
    title: "Run anywhere, including your customer's infrastructure",
    body: 'Kubernetes runs the same on AWS, GCP, Hetzner, and on-prem hardware. When an enterprise customer says "this has to run in our environment," you say yes instead of starting a replatforming project. Switching clouds becomes a migration, not a rewrite.',
    icon: Globe,
    span: "md:col-span-2",
  },
  {
    title: "Own your stack",
    body: "No platform-imposed limits on processes, networking, background jobs, or runtime versions. Your architecture is your decision, not a tier on someone's pricing page.",
    icon: SlidersHorizontal,
    span: "md:col-span-2",
  },
  {
    title: "Scale without re-architecting",
    body: "The platform that runs your two services today runs two hundred later. Autoscaling, rolling deploys, and self-healing are built in.",
    icon: TrendingUp,
    span: "md:col-span-2",
  },
]

export default function WhyKubernetes() {
  return (
    <section id="why-kubernetes" className="py-24 sm:py-28">
      <Container>
        <SectionHeading
          kicker="Why Kubernetes at all?"
          title="Why startups end up on Kubernetes anyway"
          lede="Most startups don't choose Kubernetes because they love infrastructure. They choose it because at some point the alternatives stop working: the PaaS bill crosses five figures, a big customer demands on-prem deployment, or the architecture outgrows what a hosted platform allows. Kubernetes is where those roads converge, and the companies that get there deliberately do better than the ones that get there in a panic."
        />

        <div className="mt-14 grid gap-4 md:grid-cols-6">
          {cards.map((card, index) => (
            <Reveal key={card.title} delay={index} className={card.span}>
              <div
                className={cn(
                  "group relative h-full overflow-hidden rounded-2xl border border-border bg-card p-6 transition-all duration-300 hover:-translate-y-0.5 hover:shadow-[0_2px_16px_rgba(0,0,0,0.05)]",
                )}
              >
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

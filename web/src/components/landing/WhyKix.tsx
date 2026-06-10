import { Check, X } from "lucide-react"
import { Container, Reveal, SectionHeading } from "@/components/landing/primitives"

const rawRows: string[] = [
  "Thousands of lines of hand-maintained YAML",
  "Mistakes surface in production",
  "Helm + Terraform + scripts + tribal knowledge",
  "Platform engineers as gatekeepers",
  "Months to production-ready",
]

const kixRows: string[] = [
  "One concise stack definition",
  "Mistakes surface before deploy, on your machine",
  "One tool, one workflow: define → check → preview → deploy",
  "Any developer on the team can operate it",
  "Production-grade defaults from day one",
]

export default function WhyKix() {
  return (
    <section className="py-24 sm:py-28">
      <Container>
        <SectionHeading
          kicker="Why Kix"
          title="The usual price: a platform team you didn't plan to hire"
        />

        <div className="mt-10 grid gap-x-16 gap-y-6 lg:grid-cols-2">
          <Reveal>
            <p className="text-lg leading-relaxed text-muted-foreground">
              Adopting Kubernetes the normal way hands your team a long list
              of ways to break production with a typo. A mismatched label
              here, a missing dependency there, and you find out after
              deploy. So companies hire platform engineers to stand between
              developers and the cluster, and "we moved to Kubernetes"
              becomes a headcount line. That headcount is what keeps startups
              paying the PaaS prices in the comparison above.
            </p>
          </Reveal>
          <Reveal delay={1}>
            <p className="text-lg leading-relaxed text-muted-foreground">
              Kix removes that price. You describe your stack in one place,
              at a level your whole team can read: services, databases,
              ingress, certificates. Kix checks every selector, reference,
              and dependency before anything touches the cluster, and shows
              you exactly what will change before it changes. The mistakes
              that normally need a specialist to catch don't make it past
              your laptop.
            </p>
          </Reveal>
        </div>

        <div className="mt-14 grid gap-4 lg:grid-cols-2">
          <Reveal delay={0}>
            <div className="h-full rounded-2xl border border-border bg-card/60 p-7">
              <h3 className="text-sm font-semibold text-muted-foreground">
                Raw Kubernetes
              </h3>
              <ul className="mt-5 space-y-3.5">
                {rawRows.map((row) => (
                  <li
                    key={row}
                    className="flex items-start gap-3 text-[0.95rem] leading-relaxed"
                  >
                    <X className="mt-0.5 size-4 shrink-0 text-zinc-400" />
                    <span>{row}</span>
                  </li>
                ))}
              </ul>
            </div>
          </Reveal>
          <Reveal delay={1}>
            <div className="h-full rounded-2xl border border-brand/25 bg-brand/[0.04] p-7 shadow-[0_2px_24px_color-mix(in_srgb,var(--brand)_7%,transparent)]">
              <div className="flex items-center gap-2.5">
                <h3 className="text-sm font-semibold text-foreground">
                  With Kix
                </h3>
                <span className="rounded-full bg-brand-soft px-2.5 py-0.5 text-xs font-medium text-brand">
                  the product
                </span>
              </div>
              <ul className="mt-5 space-y-3.5">
                {kixRows.map((row) => (
                  <li
                    key={row}
                    className="flex items-start gap-3 text-[0.95rem] leading-relaxed"
                  >
                    <Check className="mt-0.5 size-4 shrink-0 text-brand" />
                    <span>{row}</span>
                  </li>
                ))}
              </ul>
            </div>
          </Reveal>
        </div>

        <Reveal className="mt-16">
          <div className="mx-auto max-w-2xl text-center">
            <div className="mx-auto mb-6 h-px w-12 bg-brand" />
            <p className="text-balance text-2xl font-medium tracking-tight text-foreground sm:text-3xl">
              Kubernetes stops being a job, or even part of one: it's just
              where your software runs.
            </p>
          </div>
        </Reveal>
      </Container>
    </section>
  )
}

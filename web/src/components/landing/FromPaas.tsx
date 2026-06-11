import { ArrowRight } from "lucide-react"
import {
  Container,
  Reveal,
  SectionHeading,
} from "@/components/landing/primitives"

const contrasts: { promise: string; need: string }[] = [
  {
    promise: "One-click deploys",
    need: "Deploys you can preview: the exact changes, before they happen, every time.",
  },
  {
    promise: "Never think about infrastructure",
    need: "You're here because a reason to think about it arrived: the bill, a customer, compliance. Kix lets you act on it without becoming a platform team.",
  },
  {
    promise: "Simple, until it isn't",
    need: "Complexity that stays managed. The seventh service and the second environment cost the same attention as the first.",
  },
]

export default function FromPaas() {
  return (
    <section id="from-paas" className="bg-(--surface-tint) py-24 sm:py-28">
      <Container>
        <SectionHeading
          kicker="Coming from a PaaS"
          title="Outgrowing Railway, Vercel, or Supabase?"
          lede="They were the right call when you started; we'd have told you to use them too. They stop being right around the seventh service, the second environment, or the first customer who asks where their data lives."
        />

        <div className="mt-12">
          <div className="mb-3 hidden gap-x-6 px-6 sm:px-7 lg:grid lg:grid-cols-[1fr_auto_2fr]">
            <p className="font-mono text-[0.72rem] font-medium uppercase tracking-[0.12em] text-muted-foreground">
              The PaaS pitch
            </p>
            <span className="w-4" />
            <p className="font-mono text-[0.72rem] font-medium uppercase tracking-[0.12em] text-brand">
              What you need now
            </p>
          </div>
          <div className="space-y-4">
            {contrasts.map((row, i) => (
              <Reveal key={row.promise} delay={i}>
                <div className="grid gap-x-6 gap-y-2 rounded-2xl border border-border bg-card p-6 sm:p-7 lg:grid-cols-[1fr_auto_2fr] lg:items-center">
                  <p className="text-sm italic text-muted-foreground">
                    "{row.promise}"
                  </p>
                  <ArrowRight className="hidden size-4 text-brand lg:block" />
                  <p className="leading-relaxed text-foreground">{row.need}</p>
                </div>
              </Reveal>
            ))}
          </div>
        </div>

        <Reveal delay={3}>
          <p className="mt-10 max-w-3xl text-lg leading-relaxed text-muted-foreground">
            Moving off is a migration, not a rewrite. Your containers stay
            your containers; they just land on infrastructure you own, for a
            fraction of the bill.
          </p>
        </Reveal>
      </Container>
    </section>
  )
}

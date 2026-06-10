import { ArrowRight } from "lucide-react"
import { Button } from "@/components/ui/button"
import {
  Container,
  Reveal,
  SectionHeading,
} from "@/components/landing/primitives"

export default function AdoptionPaths() {
  return (
    <section id="adoption-paths" className="py-24 sm:py-28">
      <Container>
        <SectionHeading
          kicker="Getting started"
          title="Start on your own. Get help if you want it."
        />

        <div className="mt-14 grid gap-4 lg:grid-cols-5">
          <Reveal className="lg:col-span-3">
            <div className="h-full rounded-2xl border border-brand/25 bg-brand/[0.04] p-8 sm:p-10">
              <div className="flex flex-wrap items-center gap-3">
                <h3 className="text-2xl font-semibold tracking-tight">
                  Self-service
                </h3>
                <span className="rounded-full bg-brand-soft px-2.5 py-0.5 text-xs font-medium text-brand">
                  Most teams start here
                </span>
              </div>
              <p className="mt-3 leading-relaxed text-muted-foreground">
                Sign up, define your stack, and deploy to a cluster the same
                week. The docs, defaults, and checks are designed so one
                full-stack developer can get to production without prior
                Kubernetes experience, with templates for the common paths
                off Heroku, Render, Fly, and ECS.
              </p>
              <Button size="lg" asChild className="mt-6">
                <a href="#early-access">Get early access</a>
              </Button>
            </div>
          </Reveal>

          <Reveal delay={1} className="lg:col-span-2">
            <div className="h-full rounded-2xl border border-border bg-card p-8 sm:p-10">
              <h3 className="text-2xl font-semibold tracking-tight">
                Partner-guided migration
              </h3>
              <p className="mt-3 leading-relaxed text-muted-foreground">
                Migrating something gnarly, like years of Heroku history or a
                tangle of half-documented services? Work with a Kix migration
                partner who moves your stack onto Kix with you. The partner's
                job is to leave your team running it, not to stay on
                retainer.
              </p>
              <a
                href="#early-access"
                className="mt-6 inline-flex items-center gap-1.5 text-sm font-medium text-brand hover:underline"
              >
                Talk to us about migration <ArrowRight className="size-3.5" />
              </a>
            </div>
          </Reveal>
        </div>
      </Container>
    </section>
  )
}

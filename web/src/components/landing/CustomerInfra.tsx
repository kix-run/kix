import { ArrowRight } from "lucide-react"
import { Container, Reveal } from "@/components/landing/primitives"
import { Button } from "@/components/ui/button"

export default function CustomerInfra() {
  return (
    <section
      id="customer-infra"
      className="relative overflow-hidden border-y border-white/10 bg-(--band) py-24 text-white sm:py-28"
    >
      <div className="pointer-events-none absolute -top-24 left-1/2 h-64 w-[80%] -translate-x-1/2 bg-[radial-gradient(ellipse_at_center,color-mix(in_srgb,var(--brand)_35%,transparent),transparent_60%)]" />
      <Container>
        <div className="grid gap-x-16 lg:grid-cols-2">
          <div>
            <Reveal>
              <p className="font-mono text-[0.78rem] font-medium uppercase tracking-[0.12em] text-(--brand-on-dark)">
                Customer-hosted deployments
              </p>
            </Reveal>
            <Reveal delay={1}>
              <h2 className="mt-3 text-balance text-3xl font-semibold tracking-tight text-white sm:text-[2.6rem] sm:leading-[1.05]">
                Your biggest deal just asked you to run in their cloud.
              </h2>
            </Reveal>
          </div>
          <Reveal delay={2} className="lg:row-span-2 lg:pt-9">
            <div className="mt-6 space-y-4 text-lg leading-relaxed text-zinc-400 lg:mt-0">
              <p>
                For B2B startups, "can you deploy into our environment?" is the
                question that stalls enterprise deals. With a PaaS, the answer
                is no. With raw Kubernetes, the answer is a six-month
                engineering project, per customer.
              </p>
              <p>
                With Kix, your product is a verifiable cluster artifact. The
                same definition that runs your SaaS deploys into a customer's
                AWS account, their data center, or their private cloud.
                Everything is checked and previewed before anything runs, so
                their security team can see exactly what they're getting.
                When the next customer asks for the same thing, it's the same
                definition with different settings, not another project.
              </p>
            </div>
          </Reveal>
          <div>
            <Reveal delay={3}>
              <p className="mt-8 text-xl font-medium text-white">
                One stack definition. Your cloud, their cloud, their basement.
              </p>
            </Reveal>
            <Reveal delay={4}>
              <div className="mt-9">
                <Button
                  asChild
                  className="bg-(--brand-on-dark) text-zinc-950 hover:bg-(--brand-on-dark)/85"
                >
                  <a
                    href="#early-access"
                    onClick={() => {
                      window.dispatchEvent(
                        new CustomEvent("kix:preselect-usecase", {
                          detail: "customer-infra",
                        }),
                      )
                    }}
                  >
                    I need customer-hosted deploys
                    <ArrowRight className="size-4" />
                  </a>
                </Button>
                <p className="mt-3 text-sm text-zinc-500">
                  Deal on a deadline? Say so when you request access. Teams
                  with a deal in flight get onboarded first.
                </p>
              </div>
            </Reveal>
          </div>
        </div>
      </Container>
    </section>
  )
}

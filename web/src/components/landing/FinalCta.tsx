import { useEffect, useState, type FormEvent } from "react"
import { Check, MailCheck } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Container, Reveal } from "@/components/landing/primitives"
import { cn } from "@/lib/utils"

// TODO: point at the interest-capture endpoint
const FORM_ENDPOINT = ""

const useCaseOptions: { value: string; label: string }[] = [
  { value: "paas", label: "Moving off a PaaS (Heroku, Render, Fly, …)" },
  {
    value: "customer-infra",
    label: "Deploying our product into customer infrastructure",
  },
  {
    value: "no-platform-team",
    label: "Adopting Kubernetes without hiring a platform team",
  },
  { value: "other", label: "Something else" },
]

const reassurances = [
  "Free during early access",
  "Founding pricing locked in for early teams",
  "No newsletter, no spam, just onboarding",
]

export default function FinalCta() {
  const [email, setEmail] = useState("")
  const [useCase, setUseCase] = useState("")
  const [notes, setNotes] = useState("")
  const [useCaseError, setUseCaseError] = useState(false)
  const [submitted, setSubmitted] = useState(false)

  useEffect(() => {
    const handler = (e: Event) => setUseCase((e as CustomEvent<string>).detail)
    window.addEventListener("kix:preselect-usecase", handler)
    return () => window.removeEventListener("kix:preselect-usecase", handler)
  }, [])

  const handleSubmit = async (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault()
    if (!useCase) {
      setUseCaseError(true)
      return
    }
    if (!FORM_ENDPOINT) {
      setSubmitted(true)
      return
    }
    const res = await fetch(FORM_ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email, useCase, notes }),
    })
    if (res.ok) {
      setSubmitted(true)
    }
  }

  return (
    <section id="early-access" className="py-24 sm:py-28">
      <Container>
        <Reveal>
          <div className="relative overflow-hidden rounded-3xl bg-(--band) p-8 text-white ring-1 ring-white/10 sm:p-14">
            <div className="pointer-events-none absolute -top-24 left-1/2 h-64 w-[80%] -translate-x-1/2 bg-[radial-gradient(ellipse_at_center,color-mix(in_srgb,var(--brand)_35%,transparent),transparent_60%)]" />
            <div className="relative lg:grid lg:grid-cols-2 lg:items-center lg:gap-14">
              <div>
                <h2 className="text-balance text-3xl font-semibold tracking-tight sm:text-4xl">
                  Get on Kubernetes without making it your job
                </h2>
                <p className="mt-5 text-lg leading-relaxed text-zinc-400">
                  Kix is onboarding early-access teams now. Tell us what you're
                  trying to do and we'll get you set up. We onboard a small
                  number of teams at a time.
                </p>
                <ul className="mt-7 space-y-3 text-sm text-zinc-300">
                  {reassurances.map((line) => (
                    <li key={line} className="flex items-start gap-3">
                      <Check className="mt-0.5 size-4 shrink-0 text-(--brand-on-dark)" />
                      {line}
                    </li>
                  ))}
                </ul>
              </div>

              <div className="mt-10 rounded-2xl bg-card p-6 text-foreground shadow-2xl ring-1 ring-foreground/10 sm:p-8 lg:mt-0">
                {submitted ? (
                  <div>
                    <div className="flex size-9 items-center justify-center rounded-lg bg-brand-soft text-brand">
                      <MailCheck className="size-4.5" />
                    </div>
                    <h3 className="mt-4 text-xl font-semibold tracking-tight">
                      You're on the list.
                    </h3>
                    <p className="mt-2 text-sm leading-relaxed text-muted-foreground">
                      We're onboarding teams in small groups and we'll email
                      you when your spot opens. Want to skip ahead? Reply to
                      the confirmation email with a paragraph about your
                      stack. Teams with a concrete migration or a customer deal in
                      flight get priority.
                    </p>
                  </div>
                ) : (
                  <form onSubmit={handleSubmit}>
                    <label
                      htmlFor="cta-email"
                      className="block text-sm font-medium"
                    >
                      Work email
                    </label>
                    <input
                      id="cta-email"
                      type="email"
                      required
                      value={email}
                      onChange={(e) => setEmail(e.target.value)}
                      placeholder="you@yourstartup.com"
                      className="mt-2 w-full rounded-lg border border-input bg-card px-3.5 py-2.5 text-sm outline-none transition focus:border-brand focus:ring-3 focus:ring-brand/15"
                    />

                    <p className="mt-5 text-sm font-medium">
                      What would you use Kix for?
                    </p>
                    <div className="mt-2 space-y-2">
                      {useCaseOptions.map((opt) => (
                        <button
                          key={opt.value}
                          type="button"
                          aria-pressed={useCase === opt.value}
                          onClick={() => {
                            setUseCase(opt.value)
                            setUseCaseError(false)
                          }}
                          className={cn(
                            "w-full rounded-lg border px-3.5 py-2.5 text-left text-sm transition",
                            useCase === opt.value
                              ? "border-brand bg-brand-soft/60 text-foreground"
                              : "border-input text-muted-foreground hover:border-muted-foreground/50",
                          )}
                        >
                          {opt.label}
                        </button>
                      ))}
                    </div>
                    {useCaseError && (
                      <p className="mt-2 text-sm text-destructive">
                        Please pick the option closest to your situation.
                      </p>
                    )}

                    <label
                      htmlFor="cta-notes"
                      className="mt-5 block text-sm font-medium"
                    >
                      Anything we should know? (optional)
                    </label>
                    <textarea
                      id="cta-notes"
                      rows={2}
                      value={notes}
                      onChange={(e) => setNotes(e.target.value)}
                      className="mt-2 w-full rounded-lg border border-input bg-card px-3.5 py-2.5 text-sm outline-none transition focus:border-brand focus:ring-3 focus:ring-brand/15"
                    />

                    <Button size="lg" className="mt-5 w-full">
                      Request early access
                    </Button>
                    <p className="mt-3 text-center text-xs text-muted-foreground">
                      We read every submission and reply personally.
                    </p>
                  </form>
                )}
              </div>
            </div>
          </div>
        </Reveal>
      </Container>
    </section>
  )
}

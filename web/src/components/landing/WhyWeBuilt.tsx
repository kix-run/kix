import {
  Container,
  Reveal,
  SectionHeading,
} from "@/components/landing/primitives"

const quotes: { text: string; name: string }[] = [
  {
    text: "If Kix had existed, I wouldn't have lost ten months to Fargate and Lambda. We had so much pain there, and Kix would have solved it.",
    name: "Luca Dombetzki",
  },
  {
    text: "I've seen our managed Kubernetes clients get caught out time and time again by production errors that could have been stopped before they ever left the engineer's laptop.",
    name: "Adam Charnock",
  },
]

export default function WhyWeBuilt() {
  return (
    <section id="why-we-built-it" className="bg-(--surface-tint) py-24 sm:py-28">
      <Container>
        <SectionHeading
          kicker="Why we built it"
          title="Why we built Kix"
        />

        <div className="mt-14 grid gap-4 lg:grid-cols-2">
          {quotes.map((quote, i) => (
            <Reveal key={quote.name} delay={i}>
              <figure className="h-full rounded-2xl border border-border bg-card p-7 sm:p-8">
                <blockquote className="text-lg leading-relaxed text-foreground">
                  "{quote.text}"
                </blockquote>
                <figcaption className="mt-5 text-sm font-medium text-muted-foreground">
                  {quote.name}, Kix
                </figcaption>
              </figure>
            </Reveal>
          ))}
        </div>
      </Container>
    </section>
  )
}

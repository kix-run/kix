import { Container, Reveal, SectionHeading } from "@/components/landing/primitives"

const frameworks = ["SOC 2", "ISO 27001", "DORA", "NIS2"]

const artifacts = [
  {
    file: "sbom.json",
    desc: "Software bill of materials: every image, package, and input in the build",
  },
  {
    file: "provenance.json",
    desc: "Build provenance: what was built, from which commit, by what",
  },
  {
    file: "scorecard-results.sarif",
    desc: "Configuration findings, machine-readable",
  },
  {
    file: "assessment-results.json",
    desc: "Findings mapped to the controls of your chosen framework",
  },
  {
    file: "audit-report.md",
    desc: "A readable summary you can hand straight to the auditor",
  },
]

export default function Compliance() {
  return (
    <section id="compliance" className="py-24 sm:py-28">
      <Container>
        <SectionHeading
          kicker="Compliance"
          title="Audit evidence as a build output"
        />

        <div className="mt-12 grid items-start gap-10 lg:grid-cols-2 lg:gap-16">
          <div>
            <Reveal>
              <p className="text-lg leading-relaxed text-muted-foreground">
                When the security questionnaire lands, the evidence already
                exists. Because Kix compiles your whole stack, it knows every
                image, every package, and every setting in production. One
                command turns that knowledge into the bundle your auditor
                actually asked for. The same bundle answers the security
                review that comes with a customer-hosted deployment.
              </p>
              <p className="mt-5 leading-relaxed text-muted-foreground">
                Not a scanner bolted on after the fact. The evidence is derived
                from the same build that produced your cluster, so it is
                current by construction: regenerate it on any commit and it
                describes exactly what is running.
              </p>
            </Reveal>
            <Reveal delay={1}>
              <p className="mt-6 text-sm font-medium text-foreground">
                Findings mapped to the framework you answer to
              </p>
              <div className="mt-3 flex flex-wrap gap-2">
                {frameworks.map((fw) => (
                  <span
                    key={fw}
                    className="rounded-full border border-brand/25 bg-brand/[0.04] px-3 py-1 text-sm font-medium text-brand"
                  >
                    {fw}
                  </span>
                ))}
              </div>
            </Reveal>
          </div>

          <Reveal delay={2}>
            <div className="overflow-hidden rounded-xl border border-border bg-card shadow-xl shadow-zinc-950/5 ring-1 ring-foreground/5">
              <div className="flex items-center gap-2 border-b border-border bg-muted/50 px-4 py-3">
                <span className="font-mono text-xs text-muted-foreground">
                  $ kix compliance audit production
                </span>
              </div>
              <ul className="px-5 py-2">
                {artifacts.map((artifact) => (
                  <li
                    key={artifact.file}
                    className="border-b border-border/60 py-3.5 last:border-b-0"
                  >
                    <p className="font-mono text-[0.82rem] text-brand">
                      {artifact.file}
                    </p>
                    <p className="mt-0.5 text-sm leading-relaxed text-muted-foreground">
                      {artifact.desc}
                    </p>
                  </li>
                ))}
              </ul>
            </div>
          </Reveal>
        </div>
      </Container>
    </section>
  )
}

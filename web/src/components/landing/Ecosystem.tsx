import { ArrowRight } from "lucide-react"
import {
  Container,
  Reveal,
  SectionHeading,
} from "@/components/landing/primitives"

const tools = [
  "Helm",
  "Kustomize",
  "Argo CD",
  "Flux",
  "Cilium",
  "Istio",
  "Prometheus",
  "Grafana",
  "Loki",
  "cert-manager",
  "external-dns",
  "Velero",
  "Sealed Secrets",
  "Vault",
  "OPA",
  "Kyverno",
  "Falco",
  "Karpenter",
  "KEDA",
  "Rook",
  "Longhorn",
  "CloudNativePG",
  "Crossplane",
  "Cluster API",
]

export default function Ecosystem() {
  return (
    <section id="ecosystem" className="py-24 sm:py-28">
      <Container>
        <SectionHeading
          kicker="Kubernetes components"
          title="A Kubernetes stack, configured together"
          lede="A Kubernetes stack combines tools for networking, storage, monitoring, and security. Kix packages these components and configures their connections from your definition."
        />

        <div className="mt-14 grid items-stretch gap-4 lg:grid-cols-[3fr_2fr]">
          <Reveal>
            <div className="h-full rounded-2xl border border-border bg-card/60 p-7">
              <h3 className="text-sm font-semibold text-muted-foreground">
                The Kubernetes ecosystem
              </h3>
              <div className="mt-5 flex flex-wrap gap-2">
                {tools.map((tool) => (
                  <span
                    key={tool}
                    className="rounded-full border border-border bg-background px-3 py-1 font-mono text-xs text-muted-foreground"
                  >
                    {tool}
                  </span>
                ))}
                <span className="rounded-full px-3 py-1 font-mono text-xs text-muted-foreground/70">
                  + roughly 1,000 more on the CNCF landscape
                </span>
              </div>
            </div>
          </Reveal>
          <Reveal delay={1}>
            <div className="relative flex h-full flex-col overflow-hidden rounded-2xl bg-(--band) p-7 text-white ring-1 ring-white/10">
              <div className="pointer-events-none absolute -top-20 left-1/2 h-48 w-[80%] -translate-x-1/2 bg-[radial-gradient(ellipse_at_center,color-mix(in_srgb,var(--brand)_35%,transparent),transparent_60%)]" />
              <h3 className="relative text-sm font-semibold text-white">
                With Kix
              </h3>
              <div className="relative my-auto py-8">
                <p className="flex flex-wrap items-center gap-3 font-mono text-lg text-white">
                  cluster.nix
                  <ArrowRight className="size-4 text-(--brand-on-dark)" />
                  <span className="text-(--brand-on-dark)">kix deploy</span>
                </p>
                <p className="mt-4 text-sm leading-relaxed text-zinc-400">
                  Kix configures the components your stack needs from one
                  definition.
                </p>
              </div>
            </div>
          </Reveal>
        </div>
      </Container>
    </section>
  )
}

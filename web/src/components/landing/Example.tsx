import { Tabs } from "radix-ui"
import { ShieldCheck } from "lucide-react"
import {
  Container,
  Reveal,
  SectionHeading,
} from "@/components/landing/primitives"

// Hand-tokenized nix, expressed as data. Token classes mirror the hero
// card: keys, values, punctuation, comments, references.
type Tok = { t: string; c?: "k" | "v" | "p" | "c" | "r" }
type CodeLine = Tok[]

const tokClass: Record<NonNullable<Tok["c"]>, string> = {
  k: "text-zinc-300",
  v: "text-(--brand-on-dark)",
  p: "text-zinc-500",
  c: "text-zinc-500 italic",
  r: "text-[#86bbd8]",
}

// Shorthand constructors keep the line data readable.
const k = (t: string): Tok => ({ t, c: "k" })
const v = (t: string): Tok => ({ t, c: "v" })
const p = (t: string): Tok => ({ t, c: "p" })
const c = (t: string): Tok => ({ t, c: "c" })
const r = (t: string): Tok => ({ t, c: "r" })

const stackLines: CodeLine[] = [
  [k("instances.app"), p(" = {")],
  [k("  api"), p(" = {")],
  [k("    package"), p(" = "), r("packages.app"), p(";")],
  [k("    config"), p(" = {")],
  [k("      image"), p(" = "), v('"ghcr.io/acme-co/api:v2.1.0"'), p(";")],
  [k("      env.DATABASE_HOST"), p(" = "), r("postgres.out.fqdn"), p(";")],
  [k("      env.CACHE_HOST"), p("    = "), r("cache.out.fqdn"), p(";")],
  [k("      ingress.host"), p("      = "), v('"api.acme.co"'), p(";")],
  [p("    };")],
  [p("  };")],
  [],
  [k("  worker"), p(" = {")],
  [k("    package"), p(" = "), r("packages.app"), p(";")],
  [k("    config.image"), p(" = "), v('"ghcr.io/acme-co/worker:v2.1.0"'), p(";")],
  [k("    config.env.DATABASE_HOST"), p(" = "), r("postgres.out.fqdn"), p(";")],
  [p("  };")],
  [],
  [k("  postgres"), p(" = {")],
  [k("    package"), p(" = "), r("packages.postgres"), p(";")],
  [
    k("    config.extensions"),
    p(" = [ "),
    v('"vector"'),
    p(" ];"),
    c("  # the api's embeddings"),
  ],
  [k("    config.backup.enabled"), p(" = "), v("true"), p(";")],
  [p("  };")],
  [],
  [k("  cache"), p(" = { "), k("package"), p(" = "), r("packages.redis"), p("; };")],
  [p("};")],
]

const controlLines: CodeLine[] = [
  [c("# The same stack.nix, a few months on: the defaults are now")],
  [c("# overridden where production demanded it.")],
  [k("instances.app"), p(" = {")],
  [k("  api"), p(" = {")],
  [k("    package"), p(" = "), r("packages.app"), p(";")],
  [k("    config"), p(" = {")],
  [k("      image"), p(" = "), v('"ghcr.io/acme-co/api:v2.4.1"'), p(";")],
  [k("      replicas"), p(" = "), v("6"), p(";"), c("  # was the default: 2")],
  [
    k("      resources.requests"),
    p(" = { "),
    k("cpu"),
    p(" = "),
    v('"500m"'),
    p("; "),
    k("memory"),
    p(" = "),
    v('"1Gi"'),
    p("; };"),
  ],
  [c("      # env and ingress unchanged from the first tab")],
  [p("    };")],
  [p("  };")],
  [],
  [k("  postgres"), p(" = {")],
  [k("    package"), p(" = "), r("packages.postgres"), p(";")],
  [k("    config"), p(" = {")],
  [k("      extensions"), p("       = [ "), v('"vector"'), p(" ];")],
  [k("      postgres.version"), p(" = "), v('"18"'), p(";")],
  [k("      instances"), p("        = "), v("2"), p(";"), c("  # HA pair")],
  [k("      storage.size"), p("     = "), v('"200Gi"'), p(";"), c("  # was 20Gi")],
  [
    k("      instanceProfile"),
    p("  = { "),
    k("cpu"),
    p(" = "),
    v('"4"'),
    p("; "),
    k("memory"),
    p(" = "),
    v('"8Gi"'),
    p("; };"),
  ],
  [k("      backup.schedule"), p("  = "), v('"0 3 * * *"'), p(";")],
  [p("    };")],
  [p("  };")],
  [],
  [k("  cache"), p(" = {")],
  [k("    package"), p(" = "), r("packages.redis"), p(";")],
  [
    k("    config.auth.secretSource"),
    p(" = "),
    v("./secrets/redis.yaml"),
    p(";"),
    c("  # encrypted"),
  ],
  [p("  };")],
  [],
  [c("  # worker unchanged")],
  [p("};")],
]

const manifestLines: CodeLine[] = [
  [c("# Still the same stack. The team now wants tracing, and Kix has")],
  [c("# no tracing package: so they bring a Helm chart and patch what")],
  [c("# it generates, in the same file, next to everything else.")],
  [k("instances.app"), p(" = {")],
  [c("  # api, worker, postgres, cache as before")],
  [],
  [k("  tracing"), p(" = {")],
  [k("    package"), p(" = "), r("kix.helmChart"), p(" {")],
  [k("      repo"), p("    = "), v('"https://grafana.github.io/helm-charts"'), p(";")],
  [k("      name"), p("    = "), v('"tempo"'), p(";")],
  [k("      version"), p(" = "), v('"1.10.1"'), p(";")],
  [],
  [c("      # Rewrite the chart's generated resources before they ship:")],
  [k("      patchResources"), p(" = map (r:")],
  [p("        if "), k("r.kind"), p(" == "), v('"Service"')],
  [
    p("        then r // { "),
    k("spec"),
    p(" = r.spec // { "),
    k("clusterIP"),
    p(" = "),
    v('"None"'),
    p("; }; }")],
  [p("        else r);")],
  [p("    };")],
  [p("  };")],
  [p("};")],
  [],
  [c("# Every resource Kix produces is plain Kubernetes. Inspect it,")],
  [c("# patch it, or set fields no package exposes.")],
]

const tabs: {
  value: string
  label: string
  lines: CodeLine[]
  caption: string
}[] = [
  {
    value: "stack",
    label: "1 · The whole stack",
    lines: stackLines,
    caption:
      "Four instances, wired by reference. Services, network policies, storage, backups, and certificates are derived from this; there is no hand-rolled glue to forget about.",
  },
  {
    value: "control",
    label: "2 · Take control",
    lines: controlLines,
    caption:
      "The same four instances after production turned the defaults into decisions: pinned versions, an HA pair, resource limits, encrypted secrets. Every setting is a typed option the compiler checks.",
  },
  {
    value: "manifests",
    label: "3 · Down to the manifests",
    lines: manifestLines,
    caption:
      "The same stack gains a fifth instance from a Helm chart, its generated resources rewritten in place. If you would set it by hand in Kubernetes, you can set it in your definition.",
  },
]

function CodePane({ lines }: { lines: CodeLine[] }) {
  return (
    <div className="overflow-hidden rounded-xl border border-zinc-800 bg-[#0b0f1a] text-left shadow-2xl shadow-emerald-950/25 ring-1 ring-white/10 dark:ring-white/20">
      <div className="flex items-center gap-2 border-b border-zinc-800 bg-zinc-900/60 px-4 py-2.5">
        <span className="size-3 rounded-full bg-zinc-700" />
        <span className="size-3 rounded-full bg-zinc-700" />
        <span className="size-3 rounded-full bg-zinc-700" />
        <span className="ml-2 font-mono text-xs text-zinc-500">stack.nix</span>
      </div>
      <pre className="overflow-x-auto px-4 py-3 font-mono text-[0.74rem] leading-relaxed sm:px-5 sm:py-4 sm:text-[0.82rem]">
        <code>
          {lines.map((line, i) => (
            <span key={i} className="block">
              {line.length === 0
                ? " "
                : line.map((tok, j) => (
                    <span key={j} className={tok.c ? tokClass[tok.c] : undefined}>
                      {tok.t}
                    </span>
                  ))}
            </span>
          ))}
        </code>
      </pre>
    </div>
  )
}

export default function Example() {
  return (
    <section id="example" className="scroll-mt-16 bg-(--surface-tint) py-24 sm:py-28">
      <Container>
        <SectionHeading
          kicker="A real stack"
          title="A real architecture, with every layer still yours"
          lede="The hero shows the short version. Here is a fuller one: an API and its worker, Postgres with a vector store, and a cache, wired together by reference so the whole graph hangs together at compile time. When you need more than the defaults, every layer opens, down to the generated manifests."
        />

        <Reveal delay={1} className="mt-12">
          <Tabs.Root defaultValue="stack" className="mx-auto max-w-3xl">
            <Tabs.List className="mb-5 flex flex-wrap justify-center gap-2">
              {tabs.map((tab) => (
                <Tabs.Trigger
                  key={tab.value}
                  value={tab.value}
                  className="cursor-pointer rounded-full border border-border bg-card px-4 py-1.5 text-sm font-medium text-muted-foreground transition-colors hover:text-foreground data-[state=active]:border-brand data-[state=active]:bg-brand data-[state=active]:text-primary-foreground"
                >
                  {tab.label}
                </Tabs.Trigger>
              ))}
            </Tabs.List>
            {tabs.map((tab) => (
              <Tabs.Content key={tab.value} value={tab.value} className="-mx-2 sm:mx-0">
                <CodePane lines={tab.lines} />
                <p className="mx-auto mt-4 max-w-2xl text-center text-sm leading-relaxed text-muted-foreground">
                  {tab.caption}
                </p>
              </Tabs.Content>
            ))}
          </Tabs.Root>
        </Reveal>

        <Reveal delay={1}>
          <div className="mx-auto mt-14 max-w-3xl rounded-2xl border border-border bg-card p-7 sm:p-8">
            <div className="flex size-9 items-center justify-center rounded-lg bg-brand-soft text-brand">
              <ShieldCheck className="size-4.5" />
            </div>
            <h3 className="mt-4 font-semibold text-foreground">
              Standard Kubernetes underneath.
            </h3>
            <p className="mt-2 leading-relaxed text-muted-foreground">
              Kix compiles to plain Kubernetes resources on a plain Kubernetes
              cluster, yours or your customer's. You can inspect every line it
              produces, and if you ever leave, you keep a working cluster and
              standard manifests. Leaving Kix means losing the tooling, not
              your infrastructure.
            </p>
          </div>
        </Reveal>
      </Container>
    </section>
  )
}

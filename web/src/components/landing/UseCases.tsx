import { type ReactNode } from "react";
import { Accordion } from "radix-ui";
import {
  ArrowRight,
  ChevronDown,
  Cloud,
  FileCheck,
  MessageCircle,
  SlidersHorizontal,
  TrendingDown,
  type LucideIcon,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Container,
  Reveal,
  SectionHeading,
} from "@/components/landing/primitives";

function preselectUseCase(value: string) {
  window.dispatchEvent(
    new CustomEvent("kix:preselect-usecase", { detail: value }),
  );
}

function UseCaseCta({
  label,
  preselect,
}: {
  label: string;
  preselect: string;
}) {
  return (
    <Button asChild className="mt-6">
      <a href="#early-access" onClick={() => preselectUseCase(preselect)}>
        {label}
        <ArrowRight className="size-4" />
      </a>
    </Button>
  );
}

const items: {
  title: string;
  teaser: string;
  icon: LucideIcon;
  body: ReactNode;
}[] = [
  {
    title: "Deploy into your customer's cloud",
    teaser: "Use your existing stack definition in customer environments.",
    icon: Cloud,
    body: (
      <>
        <p>
          Kix compiles your product into a verifiable cluster artifact. The same
          definition that runs your SaaS deploys into a customer's AWS account,
          data center, or private cloud, with settings for each environment.
          Their security team can inspect the artifact before deployment.
        </p>
        <UseCaseCta
          label="I need customer-hosted deploys"
          preselect="customer-infra"
        />
      </>
    ),
  },
  {
    title: "Cut the infrastructure bill",
    teaser: "Choose infrastructure that fits your workload and budget.",
    icon: TrendingDown,
    body: (
      <>
        <p>
          Kix supports managed and self-managed Kubernetes, so you can choose
          where to run your stack. You can also run databases on your cluster
          to make use of capacity you already pay for.
        </p>
        <UseCaseCta label="Try it out" preselect="paas" />
      </>
    ),
  },
  {
    title: "Own & scale your stack",
    teaser: "Run your stack on standard Kubernetes.",
    icon: SlidersHorizontal,
    body: (
      <>
        <p>
          Configure processes, networking, background jobs, and runtime versions
          in your definition. Add services and adjust resources as your workload
          grows.
        </p>
      </>
    ),
  },
  {
    title: "Compliance reporting built-in",
    teaser: "SBOM, provenance, and findings from the same build.",
    icon: FileCheck,
    body: (
      <>
        <p>
          Because Kix compiles your whole stack, it knows every image, package,
          and setting in production. One command can produce: a software bill of
          materials, build provenance, and findings mapped to SOC 2, ISO 27001,
          DORA, or NIS2.
        </p>
      </>
    ),
  },
  {
    title: "Don't see your use case?",
    teaser: "Tell us what you're trying to do.",
    icon: MessageCircle,
    body: (
      <>
        <p>
          Tell us about your stack and where you want to run it.
        </p>
        <UseCaseCta label="Tell us about it" preselect="other" />
      </>
    ),
  },
];

export default function UseCases() {
  return (
    <section id="use-cases" className="bg-(--surface-tint) py-24 sm:py-28">
      <Container>
        <SectionHeading
          kicker="Use cases"
          title="Why teams use Kix"
          lede="Sooner or later we outgrow our initial deployment. There can be various triggers: bills crossing five figures, big customers asking for on-prem, or simply needing more control than a PaaS allows."
        />

        <Reveal delay={1} className="mt-12">
          <Accordion.Root type="single" collapsible defaultValue="usecase-1">
            {items.map((item, i) => (
              <Accordion.Item
                key={item.title}
                value={`usecase-${i + 1}`}
                className="border-b border-border"
              >
                <Accordion.Header asChild>
                  <Accordion.Trigger className="group flex w-full cursor-pointer items-center gap-4 py-5 text-left">
                    <span className="flex size-9 shrink-0 items-center justify-center rounded-lg bg-brand-soft text-brand">
                      <item.icon className="size-4.5" />
                    </span>
                    <span className="min-w-0 flex-1">
                      <span className="block text-lg font-medium tracking-tight text-foreground transition-colors group-hover:text-brand">
                        {item.title}
                      </span>
                      <span className="mt-0.5 block text-sm text-muted-foreground">
                        {item.teaser}
                      </span>
                    </span>
                    <ChevronDown className="size-5 shrink-0 text-muted-foreground transition-transform duration-200 group-data-[state=open]:rotate-180" />
                  </Accordion.Trigger>
                </Accordion.Header>
                <Accordion.Content className="overflow-hidden leading-relaxed text-muted-foreground data-[state=open]:animate-accordion-down data-[state=closed]:animate-accordion-up">
                  <div className="max-w-3xl pb-8 pl-[3.25rem] pr-8">
                    {item.body}
                  </div>
                </Accordion.Content>
              </Accordion.Item>
            ))}
          </Accordion.Root>
        </Reveal>
      </Container>
    </section>
  );
}

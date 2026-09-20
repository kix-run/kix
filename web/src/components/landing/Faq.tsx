import { Accordion } from "radix-ui"
import { ChevronDown } from "lucide-react"
import {
  Container,
  Reveal,
  SectionHeading,
} from "@/components/landing/primitives"

const items: { question: string; answer: string }[] = [
  {
    question: "Do I need to know Kubernetes to use Kix?",
    answer:
      "You don't need to be a Kubernetes specialist. You define services, databases, and domains, and Kix configures the underlying resources. Your team still manages the applications and infrastructure.",
  },
  {
    question: "The definition is a .nix file. Do we need to learn Nix?",
    answer:
      "You'll use Nix syntax to fill in typed settings for your stack. The examples show the format, and compiler errors point to settings that need fixing. You can use more of Nix as your definitions grow.",
  },
  {
    question: "What if we need a Kubernetes setting Kix doesn't expose?",
    answer:
      "You can always drop down. Definitions provide useful abstractions, but Kix works with standard Kubernetes manifest fields underneath. Any resource or field you would set by hand can be set in your definition too.",
  },
  {
    question: "Can Claude Code or Cursor write our Kix definition?",
    answer:
      "Yes. Agents can write definitions and run local checks for configuration errors. We provide documentation and an MCP server for checks, schemas, and package discovery. You review changes before deploying.",
  },
  {
    question: "What does Kix actually run on?",
    answer:
      "Any conformant Kubernetes cluster: EKS, GKE, AKS, DigitalOcean, or your customer's environment. Kix compiles your definition into standard resources and deploys them to clusters in your accounts or your customers' accounts, never ours. Bare metal is supported through an add-on that knows the hardware and networking of providers like Hetzner and OVH, and of hardware from Dell, HPE, Supermicro, and Lenovo.",
  },
  {
    question: "Can we deploy into a customer's VPC or data center?",
    answer:
      "Yes. Use the same stack definition with settings for each customer's environment. You can check the configuration and review the deployment changes before applying them to their cluster.",
  },
  {
    question: "What happens if we leave Kix?",
    answer:
      "You keep your running cluster and the generated Kubernetes manifests. You'll need to manage future changes with other tooling.",
  },
  {
    question: "Is Kix open source?",
    answer:
      "No. Kix is proprietary software. Its generated Kubernetes resources are inspectable, and you keep your clusters and manifests if you stop using Kix.",
  },
  {
    question: "What does it cost?",
    answer:
      "Pricing scales with the size of your deployment, with bare-metal support as a paid add-on. Early access is free, and early teams lock in founding rates. We haven't published final pricing yet.",
  },
  {
    question: "Is Kix in our runtime data path?",
    answer:
      "No. Kix compiles, checks, and deploys. Your software runs on your own infrastructure without Kix in the runtime data path.",
  },
]

export default function Faq() {
  return (
    <section id="faq" className="py-24 sm:py-28">
      <Container className="lg:grid lg:grid-cols-12 lg:gap-16">
        <SectionHeading
          kicker="FAQ"
          title="Common questions"
          className="lg:col-span-5"
        />

        <Reveal delay={1} className="mt-12 lg:col-span-7 lg:mt-0">
          <Accordion.Root type="single" collapsible>
            {items.map((item, i) => (
              <Accordion.Item
                key={item.question}
                value={`item-${i + 1}`}
                className="border-b border-border"
              >
                <Accordion.Header asChild>
                  <Accordion.Trigger className="group flex w-full cursor-pointer items-center justify-between py-5 text-left text-[0.95rem] font-medium text-foreground transition-colors hover:text-brand">
                    {item.question}
                    <ChevronDown className="size-4 text-muted-foreground transition-transform duration-200 group-data-[state=open]:rotate-180" />
                  </Accordion.Trigger>
                </Accordion.Header>
                <Accordion.Content className="overflow-hidden text-[0.95rem] leading-relaxed text-muted-foreground data-[state=open]:animate-accordion-down data-[state=closed]:animate-accordion-up">
                  <div className="pb-5 pr-8">{item.answer}</div>
                </Accordion.Content>
              </Accordion.Item>
            ))}
          </Accordion.Root>
        </Reveal>
      </Container>
    </section>
  )
}

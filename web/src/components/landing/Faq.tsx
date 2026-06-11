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
      "No. The definition you write is at the level of services, databases, and domains, and the defaults are production-grade out of the box. Kubernetes knowledge helps but isn't required.",
  },
  {
    question: "Can Claude Code or Cursor write our Kix definition?",
    answer:
      "Yes, and it works well today. The definition is compact and typed, and Kix checks every selector, reference, and dependency an agent writes before deploy, so agent mistakes fail the build instead of reaching production. The docs are also published in llms.txt form for agents to read.",
  },
  {
    question: "What does Kix actually run on?",
    answer:
      "Any conformant Kubernetes cluster: EKS, GKE, AKS, DigitalOcean, or your customer's environment. Kix compiles your definition into standard resources and deploys them; it doesn't replace your cluster. Bare metal is supported through an add-on that knows the hardware and networking of providers like Hetzner and OVH.",
  },
  {
    question: "Can we deploy into a customer's VPC or data center?",
    answer:
      "Yes, this is one of the main reasons teams adopt Kix. Your stack compiles into standard Kubernetes resources, so the same definition deploys into your cluster, a customer's AWS or Azure account, or their data center. Each customer environment is the same definition with different settings, and everything is checked and previewed before it touches their cluster, which is exactly what their security review wants to see.",
  },
  {
    question: "What happens if we leave Kix?",
    answer:
      "You keep a working cluster and standard Kubernetes manifests: leaving Kix is losing a tool, not replatforming.",
  },
  {
    question: "Is Kix open source?",
    answer:
      "No, Kix is a commercial product. Everything it produces is plain, inspectable Kubernetes, so your clusters and manifests are always fully yours.",
  },
  {
    question: "What does it cost?",
    answer:
      "Priced per environment, self-service, with bare-metal support as a paid add-on. Kix plus your own infrastructure should cost well under the PaaS bill it replaces. Final numbers ship with early access, and teams joining now lock in founding rates.",
  },
  {
    question: "Is Kix in our runtime data path?",
    answer:
      "No. Kix compiles, checks, and deploys; your software runs on your clusters, on your infrastructure. If Kix disappeared tomorrow, your production wouldn't notice.",
  },
]

export default function Faq() {
  return (
    <section id="faq" className="bg-(--surface-tint) py-24 sm:py-28">
      <Container className="lg:grid lg:grid-cols-12 lg:gap-16">
        <SectionHeading
          kicker="FAQ"
          title="Questions a careful buyer should ask"
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

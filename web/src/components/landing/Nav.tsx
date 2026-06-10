import { Button } from "@/components/ui/button"
import { Container } from "@/components/landing/primitives"

const links = [
  { href: "#why-kubernetes", label: "Why Kubernetes" },
  { href: "#customer-infra", label: "Customer-hosted" },
  { href: "#use-cases", label: "Use cases" },
  { href: "#how-it-works", label: "How it works" },
  { href: "#faq", label: "FAQ" },
]

export default function Nav() {
  return (
    <header className="sticky top-0 z-50 border-b border-border/60 bg-background/80 backdrop-blur-md">
      <Container>
        <div className="flex h-16 items-center justify-between">
          <div className="flex items-baseline gap-1">
            <span className="font-mono text-xl font-bold tracking-tight text-foreground">
              kix
            </span>
            <span className="size-2 rounded-full bg-brand" />
          </div>
          <nav className="hidden gap-7 text-sm md:flex">
            {links.map((link) => (
              <a
                key={link.href}
                href={link.href}
                className="text-muted-foreground transition-colors hover:text-foreground"
              >
                {link.label}
              </a>
            ))}
          </nav>
          <Button asChild>
            <a href="#early-access">Get early access</a>
          </Button>
        </div>
      </Container>
    </header>
  )
}

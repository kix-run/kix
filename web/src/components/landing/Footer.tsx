import { Container } from "@/components/landing/primitives"

// TODO: restore a contact email link once a kixops.dev mailbox exists.
const links = [
  { href: "#how-it-works", label: "How it works" },
  { href: "#customer-infra", label: "Customer-hosted" },
  { href: "#faq", label: "FAQ" },
]

export default function Footer() {
  return (
    <footer className="border-t border-border py-14">
      <Container className="flex flex-col gap-8">
        <div className="flex flex-wrap items-start justify-between gap-8">
          <div>
            <div className="flex items-baseline gap-1">
              <span className="font-mono text-lg font-bold tracking-tight text-foreground">
                kix
              </span>
              <span className="size-1.5 rounded-full bg-brand" />
            </div>
            <p className="mt-2 text-sm text-muted-foreground">
              Kubernetes any developer can run.
            </p>
          </div>
          <div className="flex gap-6 text-sm text-muted-foreground">
            {links.map((link) => (
              <a
                key={link.href}
                href={link.href}
                className="transition-colors hover:text-foreground"
              >
                {link.label}
              </a>
            ))}
          </div>
        </div>
        <p className="text-xs text-muted-foreground/70">
          © 2026 Kix. Standard Kubernetes underneath.
        </p>
      </Container>
    </footer>
  )
}

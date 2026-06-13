import Nav from "@/components/landing/Nav"
import Hero from "@/components/landing/Hero"
import UseCases from "@/components/landing/UseCases"
import Mechanism from "@/components/landing/Mechanism"
import Example from "@/components/landing/Example"
import Ecosystem from "@/components/landing/Ecosystem"
import WhyWeBuilt from "@/components/landing/WhyWeBuilt"
import Faq from "@/components/landing/Faq"
import FinalCta from "@/components/landing/FinalCta"
import Footer from "@/components/landing/Footer"

export default function Landing() {
  return (
    <div className="min-h-screen bg-background text-foreground">
      <Nav />
      <main>
        <Hero />
        <UseCases />
        <Mechanism />
        <Example />
        <Ecosystem />
        <WhyWeBuilt />
        <Faq />
        <FinalCta />
      </main>
      <Footer />
    </div>
  )
}

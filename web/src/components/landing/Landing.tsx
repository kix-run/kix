import Nav from "@/components/landing/Nav"
import Hero from "@/components/landing/Hero"
import WhyKubernetes from "@/components/landing/WhyKubernetes"
import CostComparison from "@/components/landing/CostComparison"
import WhyKix from "@/components/landing/WhyKix"
import StatefulServices from "@/components/landing/StatefulServices"
import Compliance from "@/components/landing/Compliance"
import UseCases from "@/components/landing/UseCases"
import CustomerInfra from "@/components/landing/CustomerInfra"
import Mechanism from "@/components/landing/Mechanism"
import AdoptionPaths from "@/components/landing/AdoptionPaths"
import Faq from "@/components/landing/Faq"
import FinalCta from "@/components/landing/FinalCta"
import Footer from "@/components/landing/Footer"
import ThemeSelector from "@/components/landing/ThemeSelector"

export default function Landing() {
  return (
    <div className="min-h-screen bg-background text-foreground">
      <Nav />
      <main>
        <Hero />
        <WhyKubernetes />
        <CustomerInfra />
        <CostComparison />
        <WhyKix />
        <StatefulServices />
        <UseCases />
        <Mechanism />
        <Compliance />
        <AdoptionPaths />
        <Faq />
        <FinalCta />
      </main>
      <Footer />
      <ThemeSelector />
    </div>
  )
}

import { type ReactNode } from "react"
import { motion, type Variants } from "motion/react"
import { cn } from "@/lib/utils"

export function Container({
  className,
  children,
}: {
  className?: string
  children: ReactNode
}) {
  return (
    <div className={cn("mx-auto w-full max-w-6xl px-6", className)}>
      {children}
    </div>
  )
}

const riseVariants: Variants = {
  hidden: { opacity: 0, y: 22 },
  show: (i: number = 0) => ({
    opacity: 1,
    y: 0,
    transition: { duration: 0.6, delay: i * 0.08, ease: [0.21, 0.5, 0.27, 1] },
  }),
}

/** Fades + rises a block into view on scroll. `delay` staggers siblings. */
export function Reveal({
  children,
  className,
  delay = 0,
  as = "div",
}: {
  children: ReactNode
  className?: string
  delay?: number
  as?: "div" | "section" | "li" | "article"
}) {
  const MotionTag = motion[as]
  return (
    <MotionTag
      className={className}
      variants={riseVariants}
      initial="hidden"
      whileInView="show"
      viewport={{ once: true, margin: "-80px" }}
      custom={delay}
    >
      {children}
    </MotionTag>
  )
}

export function Eyebrow({ children }: { children: ReactNode }) {
  return (
    <span className="inline-flex items-center gap-2 rounded-full border border-brand/20 bg-brand-soft/60 px-3 py-1 font-mono text-[0.72rem] font-medium uppercase tracking-[0.12em] text-brand">
      <span className="size-1.5 rounded-full bg-brand shadow-[0_0_8px] shadow-brand/60" />
      {children}
    </span>
  )
}

/**
 * Section header. With a `lede` it renders as a split header on lg+
 * (title left, lede prose right) so the full container width is used
 * while each column keeps a readable measure.
 */
export function SectionHeading({
  kicker,
  title,
  lede,
  className,
}: {
  kicker: string
  title: ReactNode
  lede?: ReactNode
  className?: string
}) {
  const heading = (
    <>
      <Reveal>
        <p className="font-mono text-[0.78rem] font-medium uppercase tracking-[0.12em] text-brand">
          {kicker}
        </p>
      </Reveal>
      <Reveal delay={1}>
        <h2 className="mt-3 text-balance text-3xl font-semibold tracking-tight text-foreground sm:text-[2.6rem] sm:leading-[1.05]">
          {title}
        </h2>
      </Reveal>
    </>
  )

  if (!lede) {
    return <div className={cn("max-w-3xl", className)}>{heading}</div>
  }

  return (
    <div className={cn("grid gap-x-16 gap-y-6 lg:grid-cols-2", className)}>
      <div>{heading}</div>
      <Reveal delay={2} className="lg:pt-9">
        <div className="space-y-4 text-lg leading-relaxed text-muted-foreground">
          {lede}
        </div>
      </Reveal>
    </div>
  )
}

type Line = { tokens: { t: string; c?: string }[] }

const tokenColor: Record<string, string> = {
  p: "text-zinc-100",
  ok: "text-emerald-400",
  err: "text-rose-400",
  wn: "text-amber-300",
  cm: "text-zinc-500",
  str: "text-emerald-300",
}

/** Dark terminal card with sequentially revealed lines. */
export function Terminal({
  title = "zsh",
  lines,
  className,
}: {
  title?: string
  lines: Line[]
  className?: string
}) {
  return (
    <div
      className={cn(
        "w-full min-w-0 overflow-hidden rounded-xl border border-zinc-800 bg-[#0b0f1a] shadow-2xl shadow-emerald-950/20 ring-1 ring-white/5",
        className,
      )}
    >
      <div className="flex items-center gap-2 border-b border-zinc-800 bg-zinc-900/60 px-4 py-3">
        <span className="size-3 rounded-full bg-zinc-700" />
        <span className="size-3 rounded-full bg-zinc-700" />
        <span className="size-3 rounded-full bg-zinc-700" />
        <span className="ml-2 font-mono text-xs text-zinc-500">{title}</span>
      </div>
      <pre className="overflow-x-auto px-5 py-4 font-mono text-[0.82rem] leading-relaxed">
        <code>
          {lines.map((line, i) => (
            <motion.span
              key={i}
              className="block"
              initial={{ opacity: 0 }}
              whileInView={{ opacity: 1 }}
              viewport={{ once: true }}
              transition={{ delay: 0.15 + i * 0.18, duration: 0.3 }}
            >
              {line.tokens.length === 0 ? (
                " "
              ) : (
                line.tokens.map((tok, j) => (
                  <span key={j} className={tok.c ? tokenColor[tok.c] : "text-zinc-400"}>
                    {tok.t}
                  </span>
                ))
              )}
            </motion.span>
          ))}
        </code>
      </pre>
    </div>
  )
}

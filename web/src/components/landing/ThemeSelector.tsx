import { useEffect, useState } from "react"
import { Check, Palette } from "lucide-react"
import { cn } from "@/lib/utils"

/**
 * Floating theme preview switcher. A decision-making tool, not a product
 * feature: delete this file and its <ThemeSelector /> usage in Landing.tsx
 * once a theme is chosen. Themes are defined in src/index.css.
 * Also reachable via ?theme=<id> for sharing links.
 */

type Theme = { id: string; label: string; swatch: string; bg: string }

const GROUPS: { label: string; themes: Theme[] }[] = [
  {
    label: "Light",
    themes: [
      { id: "lagoon", label: "Lagoon", swatch: "#40798c", bg: "#fafcf8" },
      { id: "harbor", label: "Harbor", swatch: "#f26419", bg: "#ffffff" },
      { id: "blossom", label: "Blossom", swatch: "#f76f8e", bg: "#fffaf2" },
      { id: "pacific", label: "Pacific", swatch: "#009fb7", bg: "#ffffff" },
      { id: "bonfire", label: "Bonfire", swatch: "#c44900", bg: "#fdf7ec" },
      { id: "mint", label: "Mint", swatch: "#587a5e", bg: "#f7fcf8" },
    ],
  },
  {
    label: "Dark",
    themes: [
      { id: "lagoon-dark", label: "Lagoon", swatch: "#70a9a1", bg: "#16262b" },
      { id: "harbor-dark", label: "Harbor", swatch: "#f6ae2d", bg: "#20333d" },
      {
        id: "blossom-dark",
        label: "Blossom",
        swatch: "#f76f8e",
        bg: "#0c2628",
      },
      {
        id: "pacific-dark",
        label: "Pacific",
        swatch: "#fed766",
        bg: "#1b1b1b",
      },
      {
        id: "bonfire-dark",
        label: "Bonfire",
        swatch: "#c44900",
        bg: "#04151f",
      },
      { id: "mint-dark", label: "Mint", swatch: "#b6c8a9", bg: "#232b26" },
    ],
  },
]

const THEMES = GROUPS.flatMap((g) => g.themes)

// Must match the data-theme preset on <html> in index.html so the first
// paint and the React state agree.
const DEFAULT_THEME = "lagoon"
const STORAGE_KEY = "kix-theme"

function applyTheme(id: string) {
  document.documentElement.dataset.theme = id
}

export default function ThemeSelector() {
  const [open, setOpen] = useState(false)
  const [theme, setTheme] = useState(() => {
    const fromQuery = new URLSearchParams(window.location.search).get("theme")
    const stored = localStorage.getItem(STORAGE_KEY)
    return (
      [fromQuery, stored].find((t) => THEMES.some((th) => th.id === t)) ??
      DEFAULT_THEME
    )
  })

  useEffect(() => {
    applyTheme(theme)
  }, [theme])

  const select = (id: string) => {
    setTheme(id)
    localStorage.setItem(STORAGE_KEY, id)
  }

  return (
    <div className="fixed bottom-4 right-4 z-50 flex flex-col items-end gap-2">
      {open && (
        <div className="grid w-96 grid-cols-2 gap-x-3 gap-y-3 rounded-xl border border-border bg-card p-3 shadow-2xl">
          {GROUPS.map((group) => (
            <div key={group.label}>
              <p className="px-2 pb-1 font-mono text-[0.62rem] font-medium uppercase tracking-[0.14em] text-muted-foreground">
                {group.label}
              </p>
              {group.themes.map((t) => (
                <button
                  key={t.id}
                  type="button"
                  onClick={() => select(t.id)}
                  className={cn(
                    "flex w-full cursor-pointer items-center gap-2.5 rounded-lg px-2 py-1.5 text-left text-sm transition-colors hover:bg-muted",
                    theme === t.id && "font-medium",
                  )}
                >
                  <span
                    className="size-4 shrink-0 rounded-full border border-black/10"
                    style={{
                      background: `linear-gradient(135deg, ${t.swatch} 50%, ${t.bg} 50%)`,
                    }}
                  />
                  {t.label}
                  {theme === t.id && (
                    <Check className="ml-auto size-3.5 text-muted-foreground" />
                  )}
                </button>
              ))}
            </div>
          ))}
        </div>
      )}
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        aria-label="Switch theme preview"
        className="flex size-11 cursor-pointer items-center justify-center rounded-full border border-border bg-card text-foreground shadow-lg transition-transform hover:scale-105"
      >
        <Palette className="size-5" />
      </button>
    </div>
  )
}

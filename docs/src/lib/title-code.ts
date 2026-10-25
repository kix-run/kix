// Page titles use Markdown backticks for code ("`deploy` / `apply`"), but
// Starlight renders titles as plain text. The H1 renders the spans as
// <code>; navigation labels drop the backticks.
import type { StarlightRouteData } from '@astrojs/starlight/route-data';

const BACKTICK_SPAN = /`([^`]+)`/g;

export function stripBackticks(text: string): string {
  return text.replace(BACKTICK_SPAN, '$1');
}

const escapeHtml = (text: string) =>
  text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

export function backticksToHtml(text: string): string {
  return text
    .split(BACKTICK_SPAN)
    .map((part, index) => (index % 2 ? `<code>${escapeHtml(part)}</code>` : escapeHtml(part)))
    .join('');
}

type SidebarEntry = StarlightRouteData['sidebar'][number];

export function stripSidebarBackticks(entries: SidebarEntry[]): SidebarEntry[] {
  return entries.map((entry) =>
    entry.type === 'link'
      ? { ...entry, label: stripBackticks(entry.label) }
      : { ...entry, label: stripBackticks(entry.label), entries: stripSidebarBackticks(entry.entries) },
  );
}

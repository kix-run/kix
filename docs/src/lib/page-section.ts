// Derives the eyebrow above a page title from the page's Diátaxis topic and
// sidebar position: "TUTORIAL 05", "HOW-TO GUIDE / OPERATE A CLUSTER",
// "REFERENCE / CLI".
import type { StarlightRouteData } from '@astrojs/starlight/route-data';
import { splitLessonNumber } from './lesson-number';

const SECTION_NAMES: Record<string, string> = {
  Tutorials: 'Tutorial',
  'How-to guides': 'How-to guide',
  Reference: 'Reference',
  Explanation: 'Explanation',
};

type SidebarEntry = StarlightRouteData['sidebar'][number];

// Returns the label of the group holding the current page: '' when the page
// is a top-level link, undefined when the page is not in the sidebar (the
// topic index pages).
function findGroupLabel(entries: SidebarEntry[], parent = ''): string | undefined {
  for (const entry of entries) {
    if (entry.type === 'link') {
      if (entry.isCurrent) return parent;
    } else {
      const found = findGroupLabel(entry.entries, entry.label);
      if (found !== undefined) return found;
    }
  }
  return undefined;
}

export function pageSection(
  topicLabel: string | undefined,
  sidebar: SidebarEntry[],
  title: string,
): { section: string; detail?: string; title: string } | undefined {
  // Topic index pages and pages outside the four quadrants get no eyebrow.
  const section = topicLabel ? SECTION_NAMES[topicLabel] : undefined;
  if (!section) return undefined;
  if (topicLabel === 'Tutorials') {
    const { number, label } = splitLessonNumber(title);
    return number ? { section: `${section} ${number}`, title: label } : undefined;
  }
  const group = findGroupLabel(sidebar);
  if (group === undefined) return undefined;
  return { section, detail: group || undefined, title };
}

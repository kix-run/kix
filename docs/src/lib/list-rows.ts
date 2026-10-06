// Shared by Recap.astro and Loop.astro, which restyle a Markdown list passed
// as their slot. Authors write an ordinary list, so the page's Markdown twin
// keeps reading as a list.
//
// A row that starts with inline code ("`kix check` catches problems") splits
// into the command and the description. Leading code joined by "and" or a
// comma stays together ("`kix status` and `kix graph` inspect …"). Any other
// row is plain text.

export interface ListRow {
  /** HTML of the leading inline code, or '' for a plain-text row. */
  command: string;
  /** HTML of the rest of the row. */
  text: string;
}

const LEADING_CODE = /^\s*((?:<code[^>]*>[^<]*<\/code>)(?:\s*(?:,|,?\s*and)\s*<code[^>]*>[^<]*<\/code>)*)\s*([\s\S]*)$/;

export function parseListRows(html: string): ListRow[] {
  const rows: ListRow[] = [];
  for (const [, inner] of html.matchAll(/<li[^>]*>([\s\S]*?)<\/li>/g)) {
    // MDX wraps loose list items in <p>.
    const body = inner.replace(/^\s*<p>|<\/p>\s*$/g, '').trim();
    // Rows read as fragments, so list punctuation ("…;", "….") is dropped.
    const clean = (s: string) => s.replace(/\s*[;,.]\s*$/, '').trim();
    const match = LEADING_CODE.exec(body);
    rows.push(match ? { command: match[1], text: clean(match[2]) } : { command: '', text: clean(body) });
  }
  return rows;
}

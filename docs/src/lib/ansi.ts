// Minimal ANSI SGR parser. Turns a string with embedded `\x1b[<params>m`
// escapes into a sequence of styled spans. Non-SGR escapes (cursor moves,
// clear-line, etc.) and stray control bytes are silently dropped — the
// upstream output-transforms pipeline is expected to have already removed
// them, but this parser is defensive.
//
// Only SGR semantics we actually need are implemented:
//   - 0          reset
//   - 1 / 22     bold on / off
//   - 2 / 22     dim on / off    (shares 22 with bold per spec)
//   - 3 / 23     italic
//   - 4 / 24     underline
//   - 7 / 27     inverse
//   - 9 / 29     strikethrough
//   - 30-37      basic foreground
//   - 38;5;N     256-colour foreground
//   - 38;2;R;G;B truecolor foreground
//   - 39         default foreground
//   - 40-47      basic background
//   - 48;5;N / 48;2;R;G;B background
//   - 49         default background
//   - 90-97      bright foreground
//   - 100-107    bright background

export type NamedColor =
  | 'black' | 'red' | 'green' | 'yellow' | 'blue' | 'magenta' | 'cyan' | 'white'
  | 'bright-black' | 'bright-red' | 'bright-green' | 'bright-yellow'
  | 'bright-blue' | 'bright-magenta' | 'bright-cyan' | 'bright-white';

export type Color =
  | { kind: 'named'; name: NamedColor }
  | { kind: '256'; index: number }
  | { kind: 'rgb'; r: number; g: number; b: number };

export interface Style {
  fg?: Color;
  bg?: Color;
  bold?: boolean;
  dim?: boolean;
  italic?: boolean;
  underline?: boolean;
  inverse?: boolean;
  strikethrough?: boolean;
}

export interface Span {
  text: string;
  style: Style;
}

const NAMED: NamedColor[] = [
  'black', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'white',
];
const BRIGHT: NamedColor[] = [
  'bright-black', 'bright-red', 'bright-green', 'bright-yellow',
  'bright-blue', 'bright-magenta', 'bright-cyan', 'bright-white',
];

function applyParams(style: Style, params: number[]): Style {
  const next: Style = { ...style };
  let i = 0;
  while (i < params.length) {
    const p = params[i];
    switch (true) {
      case p === 0:
        for (const key of Object.keys(next) as (keyof Style)[]) delete next[key];
        i += 1;
        break;
      case p === 1: next.bold = true; i += 1; break;
      case p === 2: next.dim = true; i += 1; break;
      case p === 3: next.italic = true; i += 1; break;
      case p === 4: next.underline = true; i += 1; break;
      case p === 7: next.inverse = true; i += 1; break;
      case p === 9: next.strikethrough = true; i += 1; break;
      case p === 22: delete next.bold; delete next.dim; i += 1; break;
      case p === 23: delete next.italic; i += 1; break;
      case p === 24: delete next.underline; i += 1; break;
      case p === 27: delete next.inverse; i += 1; break;
      case p === 29: delete next.strikethrough; i += 1; break;
      case p >= 30 && p <= 37:
        next.fg = { kind: 'named', name: NAMED[p - 30] };
        i += 1;
        break;
      case p === 38: {
        const consumed = readExtendedColor(params, i + 1);
        if (consumed) { next.fg = consumed.color; i = consumed.next; }
        else i = params.length;
        break;
      }
      case p === 39: delete next.fg; i += 1; break;
      case p >= 40 && p <= 47:
        next.bg = { kind: 'named', name: NAMED[p - 40] };
        i += 1;
        break;
      case p === 48: {
        const consumed = readExtendedColor(params, i + 1);
        if (consumed) { next.bg = consumed.color; i = consumed.next; }
        else i = params.length;
        break;
      }
      case p === 49: delete next.bg; i += 1; break;
      case p >= 90 && p <= 97:
        next.fg = { kind: 'named', name: BRIGHT[p - 90] };
        i += 1;
        break;
      case p >= 100 && p <= 107:
        next.bg = { kind: 'named', name: BRIGHT[p - 100] };
        i += 1;
        break;
      default:
        // Unknown / unsupported parameter — skip it.
        i += 1;
        break;
    }
  }
  return next;
}

function readExtendedColor(
  params: number[],
  start: number,
): { color: Color; next: number } | null {
  const mode = params[start];
  if (mode === 5 && params.length >= start + 2) {
    return { color: { kind: '256', index: params[start + 1] }, next: start + 2 };
  }
  if (mode === 2 && params.length >= start + 4) {
    return {
      color: { kind: 'rgb', r: params[start + 1], g: params[start + 2], b: params[start + 3] },
      next: start + 4,
    };
  }
  return null;
}

// Match SGR sequences only: `\x1b[<digits and ;>m`.
// Non-SGR CSI escapes are not consumed by this regex; we strip them via a
// separate pass so they don't appear as literal text.
const SGR_PATTERN = /\x1b\[([\d;]*)m/;
const ANY_ESCAPE_PATTERN = /\x1b\[[\d;?]*[A-Za-z]/g;

function stripNonSgrEscapes(input: string): string {
  return input.replace(ANY_ESCAPE_PATTERN, (match) => (SGR_PATTERN.test(match) ? match : ''));
}

export function parseAnsi(input: string): Span[] {
  const cleaned = stripNonSgrEscapes(input);
  const spans: Span[] = [];
  let style: Style = {};
  let cursor = 0;
  while (cursor < cleaned.length) {
    const match = SGR_PATTERN.exec(cleaned.slice(cursor));
    if (!match) {
      const tail = cleaned.slice(cursor);
      if (tail) spans.push({ text: tail, style: { ...style } });
      break;
    }
    const matchStart = cursor + match.index;
    if (matchStart > cursor) {
      spans.push({ text: cleaned.slice(cursor, matchStart), style: { ...style } });
    }
    const paramText = match[1];
    const params = paramText === ''
      ? [0]
      : paramText.split(';').map((p) => (p === '' ? 0 : Number(p)));
    style = applyParams(style, params);
    cursor = matchStart + match[0].length;
  }
  return mergeAdjacent(spans);
}

function styleKey(s: Style): string {
  return JSON.stringify(s);
}

function mergeAdjacent(spans: Span[]): Span[] {
  const out: Span[] = [];
  for (const span of spans) {
    if (span.text === '') continue;
    const last = out[out.length - 1];
    if (last && styleKey(last.style) === styleKey(span.style)) {
      last.text += span.text;
    } else {
      out.push(span);
    }
  }
  return out;
}

// Lower a Style to a list of class names (palette-driven) and inline `style`
// declarations (only for 256/truecolor, which we cannot pre-bake as classes).
export function styleToCss(style: Style): { classes: string[]; inline: string } {
  const classes: string[] = [];
  const inlineParts: string[] = [];

  if (style.bold) classes.push('ansi-bold');
  if (style.dim) classes.push('ansi-dim');
  if (style.italic) classes.push('ansi-italic');
  if (style.underline) classes.push('ansi-underline');
  if (style.strikethrough) classes.push('ansi-strikethrough');
  if (style.inverse) classes.push('ansi-inverse');

  const fg = style.fg;
  if (fg) {
    if (fg.kind === 'named') classes.push(`ansi-fg-${fg.name}`);
    else if (fg.kind === 'rgb') inlineParts.push(`color:rgb(${fg.r},${fg.g},${fg.b})`);
    else if (fg.kind === '256') classes.push(`ansi-fg-256-${fg.index}`);
  }
  const bg = style.bg;
  if (bg) {
    if (bg.kind === 'named') classes.push(`ansi-bg-${bg.name}`);
    else if (bg.kind === 'rgb') inlineParts.push(`background-color:rgb(${bg.r},${bg.g},${bg.b})`);
    else if (bg.kind === '256') classes.push(`ansi-bg-256-${bg.index}`);
  }

  return { classes, inline: inlineParts.join(';') };
}

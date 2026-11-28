// Render the site icons from the Kix mark in public/logos/kix-mark-light.svg.
//
// Run from web/: `node scripts/render-icons.mjs`. Commit the output. The docs
// build serves its own copy of favicon.svg under its base path, so this
// script writes that copy too.
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const web = fileURLToPath(new URL('..', import.meta.url));
const repo = fileURLToPath(new URL('../..', import.meta.url));

const TILE = '#ffffff';

const markSvg = await readFile(`${web}public/logos/kix-mark-light.svg`, 'utf8');
const viewBox = markSvg.match(/viewBox="([^"]+)"/)[1].split(/\s+/).map(Number);
const markBody = markSvg.replace(/^[\s\S]*?<svg[^>]*>/, '').replace(/<\/svg>\s*$/, '');

// Return an SVG of the mark centred on a square tile. `scale` is the share of
// the tile's width the mark fills. `radius` rounds the tile's corners, as a
// share of its width.
function tileSvg({ size, scale, radius }) {
  const [, , w, h] = viewBox;
  const k = (size * scale) / Math.max(w, h);
  const x = (size - w * k) / 2 - viewBox[0] * k;
  const y = (size - h * k) / 2 - viewBox[1] * k;
  const r = size * radius;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">
  <rect width="${size}" height="${size}" rx="${r}" fill="${TILE}"/>
  <g transform="translate(${x.toFixed(3)} ${y.toFixed(3)}) scale(${k.toFixed(5)})">${markBody}</g>
</svg>
`;
}

async function png(svg, size) {
  return sharp(Buffer.from(svg), { density: 72 * 8 }).resize(size, size).png().toBuffer();
}

// Return an ICO file that wraps the given PNG images. Every browser and
// crawler that asks for /favicon.ico reads PNG-compressed ICO entries.
function ico(images) {
  const header = Buffer.alloc(6);
  header.writeUInt16LE(1, 2);
  header.writeUInt16LE(images.length, 4);
  const entries = [];
  let offset = 6 + 16 * images.length;
  for (const { size, data } of images) {
    const entry = Buffer.alloc(16);
    entry.writeUInt8(size >= 256 ? 0 : size, 0);
    entry.writeUInt8(size >= 256 ? 0 : size, 1);
    entry.writeUInt16LE(1, 4);
    entry.writeUInt16LE(32, 6);
    entry.writeUInt32LE(data.length, 8);
    entry.writeUInt32LE(offset, 12);
    entries.push(entry);
    offset += data.length;
  }
  return Buffer.concat([header, ...entries, ...images.map((i) => i.data)]);
}

// The tab icon keeps a rounded tile so the mark reads on light and dark tab
// strips alike. The mark fills most of it because tabs draw it at 16px.
const tab = tileSvg({ size: 64, scale: 0.8, radius: 0.22 });

// Home-screen icons fill the whole square because the phone rounds the
// corners itself. iOS only rounds them, so the touch icon can show the mark
// larger. Android may crop the manifest icons to a circle, so their mark stays
// inside the central 80% safe zone.
const touch = tileSvg({ size: 180, scale: 0.68, radius: 0 });
const maskable = (size) => tileSvg({ size, scale: 0.56, radius: 0 });

await writeFile(`${web}public/favicon.svg`, tab);
await writeFile(`${repo}docs/public/favicon.svg`, tab);
await writeFile(
  `${web}public/favicon.ico`,
  ico(await Promise.all([16, 32, 48].map(async (size) => ({ size, data: await png(tab, size) })))),
);
await writeFile(`${web}public/apple-touch-icon.png`, await png(touch, 180));
await writeFile(`${web}public/icon-192.png`, await png(maskable(192), 192));
await writeFile(`${web}public/icon-512.png`, await png(maskable(512), 512));

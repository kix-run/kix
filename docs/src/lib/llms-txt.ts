import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { StarlightPlugin } from '@astrojs/starlight/types';
import { AstroError } from 'astro/errors';

/**
 * Generates `/docs/llms.txt` from the Starlight content collection and
 * verifies at `astro:build:done` time that every URL emitted in `llms.txt`
 * resolves to both a built HTML page and a `.md` twin in `dist/`.
 */
export default function kixLlmsTxt(): StarlightPlugin {
  return {
    name: 'kix-llms-txt',
    hooks: {
      'config:setup'({ astroConfig, addIntegration, logger }) {
        if (!astroConfig.site) {
          throw new AstroError(
            '`site` not set in Astro configuration',
            'The `kix-llms-txt` plugin requires setting `site` in `astro.config.mjs`.',
          );
        }

        addIntegration({
          name: 'kix-llms-txt-integration',
          hooks: {
            'astro:config:setup'({ injectRoute }) {
              injectRoute({
                entrypoint: new URL('./llms-txt-route.ts', import.meta.url),
                pattern: '/llms.txt',
                prerender: true,
              });
            },
            'astro:build:done'({ dir }) {
              const distDir = fileURLToPath(dir);
              const llmsTxtPath = join(distDir, 'llms.txt');

              if (!existsSync(llmsTxtPath)) {
                throw new AstroError('dist/llms.txt was not generated during build.');
              }

              for (const forbidden of ['llms-small.txt', 'llms-full.txt']) {
                if (existsSync(join(distDir, forbidden))) {
                  throw new AstroError(`Unexpected legacy file ${forbidden} found in dist/.`);
                }
              }

              const content = readFileSync(llmsTxtPath, 'utf8');
              const MAX_LLMS_TXT_BYTES = 28_000;
              const byteLength = Buffer.byteLength(content, 'utf8');
              if (byteLength > MAX_LLMS_TXT_BYTES) {
                throw new AstroError(
                  `dist/llms.txt is ${byteLength} bytes, exceeding the ${MAX_LLMS_TXT_BYTES}-byte agent truncation limit.`,
                );
              }

              const linkPattern = /\[[^\]]+\]\((https?:\/\/[^)\s]+)\)/gu;
              const matches = [...content.matchAll(linkPattern)];

              if (matches.length === 0) {
                throw new AstroError('dist/llms.txt contains no documentation links.');
              }

              const broken: string[] = [];
              const siteOrigin = new URL(astroConfig.site).origin;
              const basePrefix = astroConfig.base.replace(/\/+$/u, '') || '/docs';

              for (const match of matches) {
                const rawUrl = match[1]!;
                let parsed: URL;
                try {
                  parsed = new URL(rawUrl);
                } catch {
                  broken.push(`${rawUrl} (invalid URL)`);
                  continue;
                }

                if (parsed.origin !== siteOrigin) {
                  continue;
                }

                if (!parsed.pathname.startsWith(`${basePrefix}/`)) {
                  broken.push(`${rawUrl} (does not start with ${basePrefix}/)`);
                  continue;
                }

                const relSlug = parsed.pathname
                  .slice(basePrefix.length + 1)
                  .replace(/\/+$/u, '');

                if (!relSlug) {
                  broken.push(`${rawUrl} (empty page slug)`);
                  continue;
                }

                const htmlPath = join(distDir, relSlug, 'index.html');
                const mdPath = join(distDir, `${relSlug}.md`);

                if (!existsSync(htmlPath)) {
                  broken.push(`${rawUrl} -> missing HTML output (${relSlug}/index.html)`);
                }
                if (!existsSync(mdPath)) {
                  broken.push(`${rawUrl} -> missing Markdown twin (${relSlug}.md)`);
                }
              }

              if (broken.length > 0) {
                throw new AstroError(
                  `Broken links found in dist/llms.txt (${broken.length}):\n` +
                    broken.map((entry) => `  - ${entry}`).join('\n'),
                );
              }

              logger.info(
                `Verified ${matches.length} documentation links in llms.txt (${byteLength} / ${MAX_LLMS_TXT_BYTES} bytes, HTML + .md twins).`,
              );
            },
          },
        });
      },
    },
  };
}

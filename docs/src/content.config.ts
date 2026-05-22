import { defineCollection } from 'astro:content';
import { docsLoader } from '@astrojs/starlight/loaders';
import { docsSchema } from '@astrojs/starlight/schema';

// Note: when starlight-versions is activated (non-empty `versions` array in
// astro.config.mjs), this file must also wire in `docsVersionsLoader()` from
// `starlight-versions/loader`. See:
//   https://starlight-versions.netlify.app/getting-started/
export const collections = {
  docs: defineCollection({ loader: docsLoader(), schema: docsSchema() }),
};

import { defineCollection } from 'astro:content';
import { docsLoader, i18nLoader } from '@astrojs/starlight/loaders';
import { docsSchema, i18nSchema } from '@astrojs/starlight/schema';
import { topicSchema } from './lib/sidebar-topics/schema';

export const collections = {
  docs: defineCollection({
    loader: docsLoader(),
    schema: docsSchema({ extend: topicSchema }),
  }),
  // UI string overrides, e.g. the search placeholder.
  i18n: defineCollection({ loader: i18nLoader(), schema: i18nSchema() }),
};

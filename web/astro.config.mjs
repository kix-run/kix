// @ts-check
import { defineConfig } from 'astro/config';
import tailwindcss from '@tailwindcss/vite';

// The landing page at kix.run/. The docs are a separate Astro project
// (docs/, base /docs); .github/workflows/pages.yml merges the two builds.
export default defineConfig({
  site: 'https://kix.run',
  vite: { plugins: [tailwindcss()] },
  devToolbar: { enabled: false },
});

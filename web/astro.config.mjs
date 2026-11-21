// @ts-check
import { defineConfig } from 'astro/config';
import tailwindcss from '@tailwindcss/vite';
import sitemap from '@astrojs/sitemap';

// Domaine public ; SITE_URL le surcharge (préproduction, essais). VERCEL_PROJECT_PRODUCTION_URL est ignoré :
// il vaut l'alias *.vercel.app, pas le domaine canonique.
const site = process.env.SITE_URL ?? 'https://www.escalecompany.com';

export default defineConfig({
  site,
  trailingSlash: 'never',
  build: { format: 'file' },
  integrations: [sitemap()],
  vite: { plugins: [tailwindcss()] },
});

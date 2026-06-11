import path from 'node:path';
import tailwindcss from '@tailwindcss/vite';
import { TanStackRouterVite } from '@tanstack/router-plugin/vite';
import react from '@vitejs/plugin-react';
import { defineConfig, type Plugin } from 'vite';

const bundledFileCompatibility: Plugin = {
  name: 'bundled-file-compatibility',
  apply: 'build' as const,
  enforce: 'post' as const,
  transformIndexHtml(html: string) {
    return html.replaceAll(' type="module"', '').replaceAll(' crossorigin', '');
  },
  generateBundle(_, bundle) {
    const index = bundle['index.html'];
    const entry = Object.values(bundle).find(
      (output) => output.type === 'chunk' && output.isEntry,
    );
    if (index?.type !== 'asset' || entry?.type !== 'chunk') {
      throw new Error('Desktop UI build is missing its index or entry script');
    }

    const entryFileName = Object.entries(bundle).find(
      ([, output]) => output === entry,
    )?.[0];
    if (!entryFileName) {
      throw new Error('Desktop UI entry script has no output path');
    }

    const scriptTag = `<script src="./${entryFileName}"></script>`;
    const inlineEntry = entry.code.replaceAll('</script', '<\\/script');
    index.source = String(index.source)
      .replace(scriptTag, '')
      .replace('</body>', () => `<script>${inlineEntry}</script>\n  </body>`);
    delete bundle[entryFileName];
  },
};

export default defineConfig({
  base: './',
  build: {
    assetsInlineLimit: Number.MAX_SAFE_INTEGER,
    outDir: 'dist',
    emptyOutDir: true,
    rollupOptions: {
      output: {
        format: 'iife',
        inlineDynamicImports: true,
      },
    },
  },
  plugins: [
    TanStackRouterVite(),
    react(),
    tailwindcss(),
    bundledFileCompatibility,
  ],
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
    },
  },
});

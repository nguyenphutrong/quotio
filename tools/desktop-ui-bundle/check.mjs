import { readFile } from 'node:fs/promises';

const indexPath = new URL(
  '../../apps/desktop-ui/dist/index.html',
  import.meta.url,
);
const html = await readFile(indexPath, 'utf8');

if (html.includes(' crossorigin')) {
  throw new Error(
    'Bundled desktop UI assets must not use crossorigin with file://',
  );
}

if (html.includes(' type="module"')) {
  throw new Error('Bundled desktop UI entry must be a classic script');
}

if (
  /^\s*<script[^>]+src=["']\.\/assets\//m.test(html) ||
  /^\s*<link[^>]+href=["']\.\/assets\//m.test(html)
) {
  throw new Error('Bundled desktop UI must inline its executable assets');
}

console.log('Bundled desktop UI is compatible with file:// hosts');

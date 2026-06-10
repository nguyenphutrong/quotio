import { readdirSync, readFileSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = fileURLToPath(new URL('../..', import.meta.url));

function collectSourceFiles(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const absolutePath = join(directory, entry.name);

    if (entry.isDirectory()) {
      return collectSourceFiles(absolutePath);
    }

    if (!entry.isFile() || !/\.(ts|tsx)$/.test(entry.name)) {
      return [];
    }

    return [relative(repoRoot, absolutePath)];
  });
}

const sourceFiles = collectSourceFiles(
  join(repoRoot, 'apps/desktop-ui/src'),
).filter((filePath) => filePath !== 'apps/desktop-ui/src/routeTree.gen.ts');

const allowedWindowOpenFiles = new Set([
  'apps/desktop-ui/src/lib/admin/runtime.tsx',
]);

const violations = [];

for (const filePath of sourceFiles) {
  const absolutePath = new URL(`../../${filePath}`, import.meta.url);
  const source = readFileSync(absolutePath, 'utf8');

  if (/\btarget=["']_blank["']/.test(source)) {
    violations.push(`${filePath}: use openExternal instead of target="_blank"`);
  }

  if (
    /\bwindow\.open\s*\(/.test(source) &&
    !allowedWindowOpenFiles.has(filePath)
  ) {
    violations.push(`${filePath}: route external opens through openExternal`);
  }
}

if (violations.length > 0) {
  throw new Error(
    ['Native-feel gate failed:', ...violations.map((item) => `- ${item}`)].join(
      '\n',
    ),
  );
}

console.log(
  `Native-feel shared UI gates passed for ${sourceFiles.length} files from ${relative(process.cwd(), repoRoot) || '.'}`,
);

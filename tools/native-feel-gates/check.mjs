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
const macosSharedUIScreen = readFileSync(
  new URL(
    '../../Quotio/Views/Screens/SharedDesktopUIScreen.swift',
    import.meta.url,
  ),
  'utf8',
);
const macosBundleScript = readFileSync(
  new URL('../../scripts/download-cpa-plusplus.sh', import.meta.url),
  'utf8',
);

const allowedWindowOpenFiles = new Set([
  'apps/desktop-ui/src/lib/admin/runtime.tsx',
]);
const macosDebugBundleGuard =
  'if [[ "$' + '{CONFIGURATION:-}" == "Debug" ]]; then';
const desktopRuntime = readFileSync(
  new URL('../../apps/desktop-ui/src/lib/admin/runtime.tsx', import.meta.url),
  'utf8',
);

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

if (!macosSharedUIScreen.includes('return true')) {
  violations.push(
    'Quotio/Views/Screens/SharedDesktopUIScreen.swift: shared UI must remain the default macOS app surface',
  );
}

for (const requiredText of [
  'authStatus: bootstrap.authStatus',
  "isAuthenticated: bootstrap.authStatus === 'authenticated'",
  "throw new AdminAuthError('Desktop management bridge is not connected')",
]) {
  if (!desktopRuntime.includes(requiredText)) {
    violations.push(
      `apps/desktop-ui/src/lib/admin/runtime.tsx: missing host-owned auth state guard: ${requiredText}`,
    );
  }
}

for (const requiredText of [
  'DESKTOP_UI_SOURCE_DIR="$ROOT_DIR/apps/desktop-ui/dist"',
  'if [[ -f "$DESKTOP_UI_SOURCE_DIR/index.html" ]]; then',
  macosDebugBundleGuard,
  'error: desktop UI bundle not found',
]) {
  if (!macosBundleScript.includes(requiredText)) {
    violations.push(
      `scripts/download-cpa-plusplus.sh: missing macOS desktop UI bundle guard: ${requiredText}`,
    );
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

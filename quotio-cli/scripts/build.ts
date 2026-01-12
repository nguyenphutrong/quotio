#!/usr/bin/env bun
import { parseArgs } from "node:util";
import { existsSync } from "node:fs";
import { join, dirname } from "node:path";

const PLATFORMS = [
  { target: "bun-darwin-arm64", binary: "darwin-arm64" },
  { target: "bun-darwin-x64", binary: "darwin-x64" },
  { target: "bun-linux-arm64", binary: "linux-arm64" },
  { target: "bun-linux-x64", binary: "linux-x64" },
  { target: "bun-windows-x64", binary: "windows-x64" },
] as const;

const ROOT_DIR = dirname(dirname(import.meta.url.replace("file://", "")));
const BIN_DIR = join(ROOT_DIR, "bin");
const DIST_DIR = join(ROOT_DIR, "dist");
const ENTRY_FILE = join(ROOT_DIR, "src/index.ts");

interface BuildOptions {
  platform?: string;
  all?: boolean;
  verbose?: boolean;
}

async function main(): Promise<void> {
  const { values } = parseArgs({
    args: Bun.argv.slice(2),
    options: {
      platform: { type: "string", short: "p" },
      all: { type: "boolean", short: "a", default: false },
      verbose: { type: "boolean", short: "v", default: false },
      help: { type: "boolean", short: "h", default: false },
    },
    allowPositionals: false,
    strict: true,
  });

  if (values.help) {
    printHelp();
    process.exit(0);
  }

  const options: BuildOptions = {
    platform: values.platform,
    all: values.all,
    verbose: values.verbose,
  };

  await ensureDistDir();

  if (options.all) {
    await buildAllPlatforms(options);
  } else if (options.platform) {
    await buildPlatform(options.platform, options);
  } else {
    await buildCurrentPlatform(options);
  }
}

function printHelp(): void {
  console.log(`
quotio-cli build script

Usage: bun run scripts/build.ts [options]

Options:
  -p, --platform <platform>  Build for specific platform
  -a, --all                  Build for all platforms
  -v, --verbose              Verbose output
  -h, --help                 Show this help

Platforms:
  darwin-arm64   macOS Apple Silicon
  darwin-x64     macOS Intel
  linux-arm64    Linux ARM64
  linux-x64      Linux x64
  windows-x64    Windows x64

Examples:
  bun run scripts/build.ts                    # Build for current platform
  bun run scripts/build.ts -p darwin-arm64    # Build for macOS ARM64
  bun run scripts/build.ts --all              # Build for all platforms

Note: Run 'bun run download-proxy' first to download required binaries.
`.trim());
}

async function ensureDistDir(): Promise<void> {
  await Bun.spawn(["mkdir", "-p", DIST_DIR]).exited;
}

async function buildCurrentPlatform(options: BuildOptions): Promise<void> {
  const os = process.platform === "win32" ? "windows" : process.platform;
  const arch = process.arch === "x64" ? "x64" : process.arch === "arm64" ? "arm64" : process.arch;
  const platform = `${os}-${arch}`;
  await buildPlatform(platform, options);
}

async function buildAllPlatforms(options: BuildOptions): Promise<void> {
  console.log("Building for all platforms...\n");

  const results: { platform: string; success: boolean; error?: string }[] = [];

  for (const { binary } of PLATFORMS) {
    const proxyBinaryPath = join(BIN_DIR, getBinaryFilename(binary));
    if (!existsSync(proxyBinaryPath)) {
      console.log(`⚠ Skipping ${binary}: proxy binary not found`);
      results.push({ platform: binary, success: false, error: "binary not found" });
      continue;
    }

    try {
      await buildPlatform(binary, options);
      results.push({ platform: binary, success: true });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      results.push({ platform: binary, success: false, error: message });
    }
  }

  console.log("\n=== Build Summary ===");
  for (const result of results) {
    const status = result.success ? "✓" : "✗";
    const detail = result.error ? ` (${result.error})` : "";
    console.log(`${status} ${result.platform}${detail}`);
  }

  const successful = results.filter((r) => r.success).length;
  console.log(`\nBuilt ${successful}/${results.length} platforms`);
}

async function buildPlatform(platform: string, options: BuildOptions): Promise<void> {
  const platformConfig = PLATFORMS.find((p) => p.binary === platform);
  if (!platformConfig) {
    throw new Error(`Unknown platform: ${platform}. Use --help to see available platforms.`);
  }

  const proxyBinaryPath = join(BIN_DIR, getBinaryFilename(platform));
  if (!existsSync(proxyBinaryPath)) {
    throw new Error(
      `Proxy binary not found for ${platform}. Run:\n  bun run download-proxy --platform ${platform}`
    );
  }

  const outputName = getOutputFilename(platform);
  const outputPath = join(DIST_DIR, outputName);

  console.log(`Building for ${platform}...`);
  if (options.verbose) {
    console.log(`  Entry: ${ENTRY_FILE}`);
    console.log(`  Target: ${platformConfig.target}`);
    console.log(`  Output: ${outputPath}`);
    console.log(`  Proxy binary: ${proxyBinaryPath}`);
  }

  const buildArgs = [
    "build",
    ENTRY_FILE,
    "--compile",
    "--target",
    platformConfig.target,
    "--outfile",
    outputPath,
  ];

  const proc = Bun.spawn(["bun", ...buildArgs], {
    cwd: ROOT_DIR,
    stdout: options.verbose ? "inherit" : "pipe",
    stderr: "inherit",
  });

  const exitCode = await proc.exited;
  if (exitCode !== 0) {
    throw new Error(`Build failed for ${platform} (exit code: ${exitCode})`);
  }

  const stat = Bun.file(outputPath);
  const size = await stat.size;
  const sizeMB = (size / 1024 / 1024).toFixed(2);

  console.log(`✓ Built ${outputName} (${sizeMB} MB)`);
}

function getBinaryFilename(platform: string): string {
  const isWindows = platform.startsWith("windows");
  return `CLIProxyAPI-${platform}${isWindows ? ".exe" : ""}`;
}

function getOutputFilename(platform: string): string {
  const isWindows = platform.startsWith("windows");
  return `quotio-${platform}${isWindows ? ".exe" : ""}`;
}

main().catch((error) => {
  console.error("Build failed:", error.message);
  process.exit(1);
});

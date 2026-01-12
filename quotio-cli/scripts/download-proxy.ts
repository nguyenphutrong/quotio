#!/usr/bin/env bun
/**
 * Download CLIProxyAPI binaries from GitHub releases.
 * Usage: bun run scripts/download-proxy.ts [--platform <name>] [--version <tag>] [--verify]
 */

import { parseArgs } from "node:util";
import { createHash } from "node:crypto";

const REPO = "router-for-me/CLIProxyAPIPlus";
const BIN_DIR = new URL("../bin/", import.meta.url).pathname;

interface Platform {
  name: string;
  os: string;
  arch: string;
  ext: string;
  binaryName: string;
}

const PLATFORMS: Platform[] = [
  { name: "darwin-arm64", os: "darwin", arch: "arm64", ext: "tar.gz", binaryName: "cli-proxy-api-plus" },
  { name: "darwin-x64", os: "darwin", arch: "amd64", ext: "tar.gz", binaryName: "cli-proxy-api-plus" },
  { name: "linux-arm64", os: "linux", arch: "arm64", ext: "tar.gz", binaryName: "cli-proxy-api-plus" },
  { name: "linux-x64", os: "linux", arch: "amd64", ext: "tar.gz", binaryName: "cli-proxy-api-plus" },
  { name: "windows-x64", os: "windows", arch: "amd64", ext: "zip", binaryName: "cli-proxy-api-plus.exe" },
  { name: "windows-arm64", os: "windows", arch: "arm64", ext: "zip", binaryName: "cli-proxy-api-plus.exe" },
];

interface ReleaseAsset {
  name: string;
  browser_download_url: string;
  size: number;
}

interface Release {
  tag_name: string;
  assets: ReleaseAsset[];
}

async function getLatestRelease(): Promise<Release> {
  const response = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`);
  if (!response.ok) {
    throw new Error(`Failed to fetch latest release: ${response.statusText}`);
  }
  return response.json() as Promise<Release>;
}

async function getRelease(version: string): Promise<Release> {
  const response = await fetch(`https://api.github.com/repos/${REPO}/releases/tags/${version}`);
  if (!response.ok) {
    throw new Error(`Failed to fetch release ${version}: ${response.statusText}`);
  }
  return response.json() as Promise<Release>;
}

async function downloadFile(url: string, dest: string): Promise<void> {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`Failed to download ${url}: ${response.statusText}`);
  }
  const arrayBuffer = await response.arrayBuffer();
  await Bun.write(dest, arrayBuffer);
}

async function extractTarGz(archivePath: string, outputDir: string, binaryName: string): Promise<string> {
  const proc = Bun.spawn(["tar", "-xzf", archivePath, "-C", outputDir], {
    stdout: "pipe",
    stderr: "pipe",
  });
  const exitCode = await proc.exited;
  if (exitCode !== 0) {
    const stderr = await new Response(proc.stderr).text();
    throw new Error(`Failed to extract tar.gz: ${stderr}`);
  }

  const entries = await Array.fromAsync(new Bun.Glob("**/*").scan({ cwd: outputDir, onlyFiles: true }));
  const binary = entries.find((e) => e.endsWith(binaryName));
  if (!binary) {
    throw new Error(`Binary ${binaryName} not found in archive`);
  }
  return `${outputDir}/${binary}`;
}

async function extractZip(archivePath: string, outputDir: string, binaryName: string): Promise<string> {
  const proc = Bun.spawn(["unzip", "-o", archivePath, "-d", outputDir], {
    stdout: "pipe",
    stderr: "pipe",
  });
  const exitCode = await proc.exited;
  if (exitCode !== 0) {
    const stderr = await new Response(proc.stderr).text();
    throw new Error(`Failed to extract zip: ${stderr}`);
  }

  const entries = await Array.fromAsync(new Bun.Glob("**/*").scan({ cwd: outputDir, onlyFiles: true }));
  const binary = entries.find((e) => e.endsWith(binaryName));
  if (!binary) {
    throw new Error(`Binary ${binaryName} not found in archive`);
  }
  return `${outputDir}/${binary}`;
}

async function computeSha256(filePath: string): Promise<string> {
  const file = Bun.file(filePath);
  const buffer = await file.arrayBuffer();
  return createHash("sha256").update(Buffer.from(buffer)).digest("hex");
}

async function fetchChecksums(release: Release): Promise<Map<string, string>> {
  const checksumAsset = release.assets.find((a) => a.name === "checksums.txt");
  if (!checksumAsset) {
    return new Map();
  }

  const response = await fetch(checksumAsset.browser_download_url);
  if (!response.ok) {
    console.warn("Warning: Could not fetch checksums.txt");
    return new Map();
  }

  const text = await response.text();
  const checksums = new Map<string, string>();

  for (const line of text.split("\n")) {
    const match = line.match(/^([a-f0-9]{64})\s+(.+)$/);
    if (match?.[1] && match[2]) {
      checksums.set(match[2], match[1]);
    }
  }

  return checksums;
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

async function downloadPlatform(
  platform: Platform,
  release: Release,
  checksums: Map<string, string>,
  verify: boolean
): Promise<void> {
  const version = release.tag_name.replace(/^v/, "");
  const assetName = `CLIProxyAPIPlus_${version}_${platform.os}_${platform.arch}.${platform.ext}`;
  const asset = release.assets.find((a) => a.name === assetName);

  if (!asset) {
    throw new Error(`Asset ${assetName} not found in release ${release.tag_name}`);
  }

  console.log(`\n📦 ${platform.name}`);
  console.log(`   Downloading ${assetName} (${formatBytes(asset.size)})...`);

  const tempDir = `${BIN_DIR}/.temp-${platform.name}`;
  const archivePath = `${tempDir}/${assetName}`;
  const finalBinaryPath = `${BIN_DIR}/CLIProxyAPI-${platform.name}${platform.os === "windows" ? ".exe" : ""}`;

  await Bun.spawn(["rm", "-rf", tempDir]).exited;
  await Bun.spawn(["mkdir", "-p", tempDir]).exited;

  try {
    await downloadFile(asset.browser_download_url, archivePath);
    console.log(`   Downloaded to ${archivePath}`);

    if (verify && checksums.has(assetName)) {
      console.log("   Verifying checksum...");
      const actualHash = await computeSha256(archivePath);
      const expectedHash = checksums.get(assetName);
      if (actualHash !== expectedHash) {
        throw new Error(`Checksum mismatch for ${assetName}:\n  Expected: ${expectedHash}\n  Actual:   ${actualHash}`);
      }
      console.log("   ✓ Checksum verified");
    }

    console.log("   Extracting...");
    const binaryPath =
      platform.ext === "tar.gz"
        ? await extractTarGz(archivePath, tempDir, platform.binaryName)
        : await extractZip(archivePath, tempDir, platform.binaryName);

    await Bun.spawn(["mv", binaryPath, finalBinaryPath]).exited;

    if (platform.os !== "windows") {
      await Bun.spawn(["chmod", "+x", finalBinaryPath]).exited;
    }

    const finalSize = (await Bun.file(finalBinaryPath).stat())?.size ?? 0;
    console.log(`   ✓ Extracted to ${finalBinaryPath} (${formatBytes(finalSize)})`);
  } finally {
    await Bun.spawn(["rm", "-rf", tempDir]).exited;
  }
}

function printHelp(): void {
  console.log(`
Usage: bun run scripts/download-proxy.ts [options]

Options:
  -p, --platform <name>  Download only specific platform
                         (darwin-arm64, darwin-x64, linux-arm64, linux-x64, windows-x64, windows-arm64)
  -v, --version <tag>    Specific version to download (default: latest)
  --verify               Verify checksums (default: true)
  --no-verify            Skip checksum verification
  -h, --help             Show this help

Examples:
  bun run scripts/download-proxy.ts                    # Download all platforms, latest version
  bun run scripts/download-proxy.ts -p darwin-arm64    # Download only macOS ARM64
  bun run scripts/download-proxy.ts -v v6.6.100-0      # Download specific version
`);
}

async function main(): Promise<void> {
  const { values } = parseArgs({
    args: Bun.argv.slice(2),
    options: {
      platform: { type: "string", short: "p" },
      version: { type: "string", short: "v" },
      verify: { type: "boolean", default: true },
      help: { type: "boolean", short: "h" },
    },
  });

  if (values.help) {
    printHelp();
    process.exit(0);
  }

  console.log("🚀 CLIProxyAPI Binary Downloader\n");

  await Bun.spawn(["mkdir", "-p", BIN_DIR]).exited;

  console.log("📡 Fetching release information...");
  const release = values.version ? await getRelease(values.version) : await getLatestRelease();
  console.log(`   Version: ${release.tag_name}`);
  console.log(`   Assets: ${release.assets.length}`);

  const checksums = await fetchChecksums(release);
  if (checksums.size > 0) {
    console.log(`   Checksums: ${checksums.size} entries`);
  }

  let platformsToDownload = PLATFORMS;
  if (values.platform) {
    const platform = PLATFORMS.find((p) => p.name === values.platform);
    if (!platform) {
      console.error(`Error: Unknown platform '${values.platform}'`);
      console.error(`Valid platforms: ${PLATFORMS.map((p) => p.name).join(", ")}`);
      process.exit(1);
    }
    platformsToDownload = [platform];
  }

  console.log(`\n📥 Downloading ${platformsToDownload.length} platform(s)...`);

  for (const platform of platformsToDownload) {
    try {
      await downloadPlatform(platform, release, checksums, values.verify ?? true);
    } catch (error) {
      console.error(`   ❌ Failed: ${error instanceof Error ? error.message : error}`);
      process.exit(1);
    }
  }

  console.log("\n✅ All downloads complete!");
  console.log(`\nBinaries are in: ${BIN_DIR}`);

  const versionFile = `${BIN_DIR}/.version`;
  await Bun.write(versionFile, release.tag_name);
  console.log(`Version recorded: ${versionFile}`);
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});

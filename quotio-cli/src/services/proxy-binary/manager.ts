import {
	BUNDLED_PROXY_VERSION,
	getProxyBinaryDir,
	getProxyBinaryPath,
	getProxyDataDir,
} from "./constants.ts";

export interface ProxyBinaryInfo {
	path: string;
	version: string;
	exists: boolean;
	isExecutable: boolean;
}

export async function ensureDirectories(): Promise<void> {
	const dirs = [getProxyDataDir(), getProxyBinaryDir()];
	for (const dir of dirs) {
		await Bun.spawn(["mkdir", "-p", dir]).exited;
	}
}

export async function getBinaryInfo(): Promise<ProxyBinaryInfo> {
	const path = getProxyBinaryPath();
	const file = Bun.file(path);
	const exists = await file.exists();

	let version = "";
	let isExecutable = false;

	if (exists) {
		try {
			const proc = Bun.spawn([path], {
				stdout: "pipe",
				stderr: "pipe",
				env: { ...process.env },
			});

			const stdout = await new Response(proc.stdout).text();
			const exitCode = await proc.exited;

			isExecutable = exitCode !== 126 && exitCode !== 127;

			const versionMatch = stdout.match(/Version:\s*([^\s,]+)/);
			if (versionMatch?.[1]) {
				version = versionMatch[1];
			}
		} catch {
			isExecutable = false;
		}
	}

	return { path, version, exists, isExecutable };
}

export async function extractEmbeddedBinary(): Promise<string> {
	await ensureDirectories();

	const targetPath = getProxyBinaryPath();
	const existingInfo = await getBinaryInfo();

	if (existingInfo.exists && existingInfo.version === BUNDLED_PROXY_VERSION) {
		return targetPath;
	}

	const platform = getPlatformIdentifier();
	const embeddedPath = getEmbeddedBinaryPath(platform);

	const embeddedFile = Bun.file(embeddedPath);
	if (!(await embeddedFile.exists())) {
		throw new Error(
			`Embedded binary not found for platform ${platform}. ` +
				`Run 'bun run download-proxy --platform ${platform}' first.`,
		);
	}

	const content = await embeddedFile.arrayBuffer();
	await Bun.write(targetPath, content);

	if (process.platform !== "win32") {
		await Bun.spawn(["chmod", "+x", targetPath]).exited;
	}

	return targetPath;
}

function getPlatformIdentifier(): string {
	const os = process.platform === "win32" ? "windows" : process.platform;
	const arch =
		process.arch === "x64"
			? "x64"
			: process.arch === "arm64"
				? "arm64"
				: process.arch;
	return `${os}-${arch}`;
}

function getEmbeddedBinaryPath(platform: string): string {
	const isWindows = platform.startsWith("windows");
	const binDir = new URL("../../../bin/", import.meta.url).pathname;
	return `${binDir}CLIProxyAPI-${platform}${isWindows ? ".exe" : ""}`;
}

export async function verifyBinary(): Promise<{
	valid: boolean;
	error?: string;
}> {
	const info = await getBinaryInfo();

	if (!info.exists) {
		return { valid: false, error: "Binary not found" };
	}

	if (!info.isExecutable) {
		return { valid: false, error: "Binary is not executable" };
	}

	return { valid: true };
}

export async function removeBinary(): Promise<void> {
	const path = getProxyBinaryPath();
	await Bun.spawn(["rm", "-f", path]).exited;
}

import { copyFile, mkdir, readdir, stat } from "node:fs/promises";
import { parseArgs } from "node:util";
import { isDaemonRunning, sendCommand } from "../../ipc/client.ts";
import type { AIProvider } from "../../models/index.ts";
import { PROVIDER_METADATA, parseProvider } from "../../models/index.ts";
import { ManagementAPIClient } from "../../services/management-api.ts";
import { getAuthDir } from "../../services/quota-fetchers/types.ts";
import {
	type TableColumn,
	colors,
	formatJson,
	formatTable,
	logger,
} from "../../utils/index.ts";
import {
	type CLIContext,
	type CommandResult,
	registerCommand,
} from "../index.ts";

const authColumns: TableColumn[] = [
	{ key: "provider", header: "Provider", width: 15 },
	{ key: "account", header: "Account", width: 30 },
	{ key: "status", header: "Status", width: 10 },
];

async function handleAuth(
	args: string[],
	ctx: CLIContext,
): Promise<CommandResult> {
	const { values, positionals } = parseArgs({
		args,
		options: {
			help: { type: "boolean", short: "h", default: false },
		},
		allowPositionals: true,
		strict: false,
	});

	const subcommand = positionals[0] ?? "list";

	if (values.help) {
		printAuthHelp();
		return { success: true };
	}

	const client = new ManagementAPIClient({
		baseURL: ctx.baseUrl,
		authKey: "",
	});

	switch (subcommand) {
		case "list":
		case "ls":
			return await listAuth(client, ctx);
		case "login":
			return await login(client, ctx, positionals.slice(1));
		case "logout":
			return await logout(client, ctx, positionals.slice(1));
		case "import":
			return await importAuth(ctx, positionals.slice(1));
		case "export":
			return await exportAuth(ctx, positionals.slice(1));
		default:
			logger.error(`Unknown auth subcommand: ${subcommand}`);
			printAuthHelp();
			return { success: false, message: `Unknown subcommand: ${subcommand}` };
	}
}

function printAuthHelp(): void {
	const providers = Object.entries(PROVIDER_METADATA)
		.filter(([, meta]) => meta.oauthEndpoint)
		.map(([key]) => key)
		.join(", ");

	const help = `
quotio auth - Authentication management

Usage: quotio auth <subcommand> [options]

Subcommands:
  list, ls              List authenticated accounts
  login <provider>      Start OAuth flow for provider
  logout <provider>     Remove authentication for provider
  import <file|dir>     Import auth files from file or directory
  export <dir>          Export auth files to a directory

Supported providers for OAuth:
  ${providers}

Options:
  --help, -h    Show this help message

Examples:
  quotio auth list
  quotio auth login anthropic
  quotio auth logout gemini-cli
  quotio auth import ~/backup/auth-files/
  quotio auth export ~/backup/auth-files/
`.trim();

	logger.print(help);
}

async function listAuth(
	client: ManagementAPIClient,
	ctx: CLIContext,
): Promise<CommandResult> {
	// Try IPC daemon first (works without proxy running)
	const daemonRunning = await isDaemonRunning();
	if (daemonRunning) {
		try {
			const result = await sendCommand("auth.list", {});

			if (result.accounts.length === 0) {
				logger.print(colors.dim("No authenticated accounts."));
				return { success: true, data: [] };
			}

			const rows = result.accounts.map((account) => {
				const metadata = PROVIDER_METADATA[account.provider as AIProvider];
				return {
					provider: metadata?.displayName ?? account.provider,
					account: account.email ?? account.name ?? "-",
					status:
						account.status === "ready" && !account.disabled
							? colors.green("Active")
							: colors.dim(account.status),
				};
			});

			if (ctx.format === "json") {
				logger.print(formatJson(result.accounts));
			} else {
				logger.print(formatTable(rows, authColumns));
			}

			return { success: true, data: result.accounts };
		} catch {
			// Fall through to HTTP API
		}
	}

	// Fallback to HTTP API (requires proxy running)
	try {
		const authFiles = await client.fetchAuthFiles();

		if (authFiles.length === 0) {
			logger.print(colors.dim("No authenticated accounts."));
			return { success: true, data: [] };
		}

		const rows = authFiles.map((auth) => {
			const metadata = PROVIDER_METADATA[auth.provider as AIProvider];
			return {
				provider: metadata?.displayName ?? auth.provider,
				account: auth.email ?? auth.account ?? auth.label ?? "-",
				status:
					auth.status === "ready" && !auth.disabled
						? colors.green("Active")
						: colors.dim(auth.status),
			};
		});

		if (ctx.format === "json") {
			logger.print(formatJson(authFiles));
		} else {
			logger.print(formatTable(rows, authColumns));
		}

		return { success: true, data: authFiles };
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		return { success: false, message: `Failed to list auth: ${message}` };
	}
}

async function login(
	client: ManagementAPIClient,
	ctx: CLIContext,
	args: string[],
): Promise<CommandResult> {
	const providerArg = args[0];
	if (!providerArg) {
		logger.error("Provider required. Usage: quotio auth login <provider>");
		return { success: false, message: "Provider required" };
	}

	const provider = parseProvider(providerArg);
	if (!provider) {
		logger.error(`Unknown provider: ${providerArg}`);
		return { success: false, message: `Unknown provider: ${providerArg}` };
	}

	const metadata = PROVIDER_METADATA[provider];
	if (!metadata.oauthEndpoint) {
		logger.error(
			`Provider ${metadata.displayName} does not support OAuth login`,
		);
		return { success: false, message: `OAuth not supported for ${provider}` };
	}

	try {
		logger.info(`Starting OAuth flow for ${metadata.displayName}...`);
		const response = await client.getOAuthURL(provider);

		if (response.error) {
			return { success: false, message: response.error };
		}

		if (response.url) {
			logger.print("\nOpen this URL in your browser to authenticate:\n");
			logger.print(colors.cyan(response.url));
			logger.print(colors.dim("\nWaiting for authentication..."));

			if (response.state) {
				const result = await pollForAuth(client, response.state);
				if (result.success) {
					logger.print(colors.green("\nAuthentication successful!"));
				}
				return result;
			}
		}

		return { success: true, data: response };
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		return { success: false, message: `Login failed: ${message}` };
	}
}

async function pollForAuth(
	client: ManagementAPIClient,
	state: string,
): Promise<CommandResult> {
	const maxAttempts = 60;
	const pollInterval = 2000;

	for (let i = 0; i < maxAttempts; i++) {
		await Bun.sleep(pollInterval);

		try {
			const status = await client.pollOAuthStatus(state);
			if (status.status === "success") {
				return { success: true };
			}
			if (status.status === "error" || status.error) {
				return {
					success: false,
					message: status.error ?? "Authentication failed",
				};
			}
		} catch {
			// Continue polling
		}
	}

	return { success: false, message: "Authentication timed out" };
}

async function logout(
	client: ManagementAPIClient,
	ctx: CLIContext,
	args: string[],
): Promise<CommandResult> {
	const providerArg = args[0];

	try {
		if (!providerArg || providerArg === "all") {
			logger.info("Removing all authentication...");
			await client.deleteAllAuthFiles();
			logger.print(colors.green("All authentication removed."));
		} else {
			logger.info(`Removing authentication for ${providerArg}...`);
			await client.deleteAuthFile(providerArg);
			logger.print(colors.green(`Authentication removed for ${providerArg}.`));
		}

		return { success: true };
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		return { success: false, message: `Logout failed: ${message}` };
	}
}

async function importAuth(
	ctx: CLIContext,
	args: string[],
): Promise<CommandResult> {
	const sourcePath = args[0];
	if (!sourcePath) {
		logger.error("Source path required. Usage: quotio auth import <file|dir>");
		return { success: false, message: "Source path required" };
	}

	const authDir = getAuthDir();
	let importedCount = 0;

	try {
		await mkdir(authDir, { recursive: true });

		const sourceStats = await stat(sourcePath);

		if (sourceStats.isDirectory()) {
			const files = await readdir(sourcePath);
			const jsonFiles = files.filter((f) => f.endsWith(".json"));

			for (const fileName of jsonFiles) {
				const srcFile = `${sourcePath}/${fileName}`;
				const destFile = `${authDir}/${fileName}`;

				try {
					const content = await Bun.file(srcFile).json();
					if (
						content.access_token ||
						content.accessToken ||
						content.api_key ||
						content.apiKey
					) {
						await copyFile(srcFile, destFile);
						importedCount++;
						logger.info(`Imported: ${fileName}`);
					}
				} catch {
					logger.warn(`Skipped invalid file: ${fileName}`);
				}
			}
		} else if (sourceStats.isFile()) {
			const fileName = sourcePath.split("/").pop() ?? "imported.json";
			const destFile = `${authDir}/${fileName}`;

			const content = await Bun.file(sourcePath).json();
			if (
				content.access_token ||
				content.accessToken ||
				content.api_key ||
				content.apiKey
			) {
				await copyFile(sourcePath, destFile);
				importedCount++;
				logger.info(`Imported: ${fileName}`);
			} else {
				return {
					success: false,
					message: "File does not contain valid auth data",
				};
			}
		} else {
			return { success: false, message: "Source must be a file or directory" };
		}

		if (importedCount === 0) {
			logger.print(colors.yellow("No valid auth files found to import."));
		} else {
			logger.print(
				colors.green(`Successfully imported ${importedCount} auth file(s).`),
			);
		}

		return { success: true, data: { imported: importedCount } };
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		return { success: false, message: `Import failed: ${message}` };
	}
}

async function exportAuth(
	ctx: CLIContext,
	args: string[],
): Promise<CommandResult> {
	const destPath = args[0];
	if (!destPath) {
		logger.error("Destination path required. Usage: quotio auth export <dir>");
		return { success: false, message: "Destination path required" };
	}

	const authDir = getAuthDir();
	let exportedCount = 0;

	try {
		await mkdir(destPath, { recursive: true });

		const files = await readdir(authDir);
		const jsonFiles = files.filter((f) => f.endsWith(".json"));

		if (jsonFiles.length === 0) {
			logger.print(colors.yellow("No auth files found to export."));
			return { success: true, data: { exported: 0 } };
		}

		for (const fileName of jsonFiles) {
			const srcFile = `${authDir}/${fileName}`;
			const destFile = `${destPath}/${fileName}`;

			try {
				await copyFile(srcFile, destFile);
				exportedCount++;
				logger.info(`Exported: ${fileName}`);
			} catch {
				logger.warn(`Failed to export: ${fileName}`);
			}
		}

		logger.print(
			colors.green(
				`Successfully exported ${exportedCount} auth file(s) to ${destPath}`,
			),
		);
		return { success: true, data: { exported: exportedCount, path: destPath } };
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		return { success: false, message: `Export failed: ${message}` };
	}
}

registerCommand("auth", handleAuth);

export { handleAuth };

import {
	extractEmbeddedBinary,
	getBinaryInfo,
	verifyBinary,
} from "../../../services/proxy-binary/index.ts";
import { colors, formatJson, logger } from "../../../utils/index.ts";
import type { CLIContext, CommandResult } from "../../index.ts";

export async function proxyInstall(ctx: CLIContext): Promise<CommandResult> {
	try {
		const existingInfo = await getBinaryInfo();
		if (existingInfo.exists && existingInfo.isExecutable) {
			if (ctx.format === "json") {
				logger.print(
					formatJson({ status: "already_installed", ...existingInfo }),
				);
			} else {
				logger.print(colors.yellow("Proxy binary already installed"));
				logger.print(`  Path: ${existingInfo.path}`);
				logger.print(`  Version: ${existingInfo.version || "unknown"}`);
			}
			return {
				success: true,
				data: { status: "already_installed", ...existingInfo },
			};
		}

		logger.print("Installing proxy binary...");
		const targetPath = await extractEmbeddedBinary();

		const verification = await verifyBinary();
		if (!verification.valid) {
			return {
				success: false,
				message: `Installation failed: ${verification.error}`,
			};
		}

		const info = await getBinaryInfo();
		if (ctx.format === "json") {
			logger.print(formatJson({ status: "installed", ...info }));
		} else {
			logger.print(`${colors.green("✓")} Proxy binary installed successfully`);
			logger.print(`  Path: ${targetPath}`);
			logger.print(`  Version: ${info.version || "unknown"}`);
		}

		return { success: true, data: { status: "installed", ...info } };
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		logger.error(`Failed to install proxy: ${message}`);
		return { success: false, message };
	}
}

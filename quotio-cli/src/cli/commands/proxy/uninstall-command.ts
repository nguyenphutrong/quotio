import {
	getBinaryInfo,
	removeBinary,
} from "../../../services/proxy-binary/index.ts";
import {
	isProxyRunning,
	stopProxy,
} from "../../../services/proxy-process/index.ts";
import { colors, formatJson, logger } from "../../../utils/index.ts";
import type { CLIContext, CommandResult } from "../../index.ts";

export async function proxyUninstall(ctx: CLIContext): Promise<CommandResult> {
	try {
		const info = await getBinaryInfo();
		if (!info.exists) {
			if (ctx.format === "json") {
				logger.print(formatJson({ status: "not_installed" }));
			} else {
				logger.print(colors.yellow("Proxy binary is not installed"));
			}
			return { success: true, data: { status: "not_installed" } };
		}

		const running = await isProxyRunning();
		if (running) {
			logger.print("Stopping proxy before uninstall...");
			await stopProxy();
		}

		logger.print("Removing proxy binary...");
		await removeBinary();

		if (ctx.format === "json") {
			logger.print(formatJson({ status: "uninstalled" }));
		} else {
			logger.print(`${colors.green("✓")} Proxy binary removed successfully`);
		}

		return { success: true, data: { status: "uninstalled" } };
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		logger.error(`Failed to uninstall proxy: ${message}`);
		return { success: false, message };
	}
}

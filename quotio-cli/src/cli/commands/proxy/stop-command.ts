import {
	isProxyRunning,
	stopProxy,
} from "../../../services/proxy-process/index.ts";
import { colors, formatJson, logger } from "../../../utils/index.ts";
import type { CLIContext, CommandResult } from "../../index.ts";

export async function proxyStop(ctx: CLIContext): Promise<CommandResult> {
	try {
		const running = await isProxyRunning();
		if (!running) {
			if (ctx.format === "json") {
				logger.print(formatJson({ status: "not_running" }));
			} else {
				logger.print(colors.yellow("Proxy is not running"));
			}
			return { success: true, data: { status: "not_running" } };
		}

		logger.print("Stopping proxy...");
		await stopProxy();

		if (ctx.format === "json") {
			logger.print(formatJson({ status: "stopped" }));
		} else {
			logger.print(`${colors.green("✓")} Proxy stopped successfully`);
		}

		return { success: true, data: { status: "stopped" } };
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		logger.error(`Failed to stop proxy: ${message}`);
		return { success: false, message };
	}
}

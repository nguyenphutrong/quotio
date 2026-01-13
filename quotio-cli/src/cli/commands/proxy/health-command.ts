import { checkHealth } from "../../../services/proxy-process/index.ts";
import { colors, formatJson, logger } from "../../../utils/index.ts";
import type { CLIContext, CommandResult } from "../../index.ts";

export async function healthCheck(
	port: number,
	ctx: CLIContext,
): Promise<CommandResult> {
	try {
		const healthy = await checkHealth(port);

		if (ctx.format === "json") {
			logger.print(formatJson({ healthy, port }));
		} else {
			if (healthy) {
				logger.print(`${colors.green("✓")} Proxy is healthy on port ${port}`);
			} else {
				logger.print(
					`${colors.red("✗")} Proxy is not responding on port ${port}`,
				);
			}
		}

		return { success: healthy, data: { healthy, port } };
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		return { success: false, message: `Health check failed: ${message}` };
	}
}

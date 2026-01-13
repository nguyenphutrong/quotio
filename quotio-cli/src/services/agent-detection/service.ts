import { execSync, spawnSync } from "node:child_process";
import { constants, accessSync, existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import {
	ALL_CLI_AGENTS,
	type AgentStatus,
	type CLIAgent,
	COMMON_BINARY_PATHS,
	expandPath,
	getVersionManagerPaths,
} from "./types";

class AgentDetectionServiceImpl {
	private cachedStatuses: AgentStatus[] | null = null;
	private cacheTimestamp: number | null = null;
	private readonly cacheValidityMs = 60_000;

	async detectAllAgents(forceRefresh = false): Promise<AgentStatus[]> {
		if (
			!forceRefresh &&
			this.cachedStatuses &&
			this.cacheTimestamp &&
			Date.now() - this.cacheTimestamp < this.cacheValidityMs
		) {
			return this.cachedStatuses;
		}

		const results = await Promise.all(
			ALL_CLI_AGENTS.map((agent) => this.detectAgent(agent)),
		);

		this.cachedStatuses = results.sort((a, b) =>
			a.agent.displayName.localeCompare(b.agent.displayName),
		);
		this.cacheTimestamp = Date.now();
		return this.cachedStatuses;
	}

	invalidateCache(): void {
		this.cachedStatuses = null;
		this.cacheTimestamp = null;
	}

	async detectAgent(agent: CLIAgent): Promise<AgentStatus> {
		const { found, path } = this.findBinary(agent.binaryNames);
		const version = found && path ? this.getVersion(path) : undefined;
		const configured = found ? this.checkConfiguration(agent) : false;

		return {
			agent,
			installed: found,
			configured,
			binaryPath: path,
			version,
			lastConfigured: configured
				? this.getLastConfiguredDate(agent)
				: undefined,
		};
	}

	private findBinary(names: string[]): { found: boolean; path?: string } {
		const home = homedir();

		for (const name of names) {
			const whichPath = this.whichCommand(name);
			if (whichPath) {
				return { found: true, path: whichPath };
			}

			for (const basePath of COMMON_BINARY_PATHS) {
				const expandedBase = expandPath(basePath);
				const fullPath = `${expandedBase}/${name}`;
				if (this.isExecutable(fullPath)) {
					return { found: true, path: fullPath };
				}
			}

			for (const path of getVersionManagerPaths(name, home)) {
				if (this.isExecutable(path)) {
					return { found: true, path };
				}
			}
		}

		return { found: false };
	}

	private whichCommand(name: string): string | undefined {
		try {
			const result = execSync(`/usr/bin/which ${name}`, {
				encoding: "utf-8",
				timeout: 5000,
				stdio: ["pipe", "pipe", "pipe"],
			});
			const path = result.trim();
			return path || undefined;
		} catch {
			return undefined;
		}
	}

	private isExecutable(path: string): boolean {
		try {
			accessSync(path, constants.X_OK);
			return true;
		} catch {
			return false;
		}
	}

	private getVersion(binaryPath: string): string | undefined {
		try {
			const result = spawnSync(binaryPath, ["--version"], {
				encoding: "utf-8",
				timeout: 5000,
				stdio: ["pipe", "pipe", "pipe"],
			});
			if (result.status === 0 && result.stdout) {
				return result.stdout.trim().split("\n")[0];
			}
			if (result.stderr) {
				return result.stderr.trim().split("\n")[0];
			}
		} catch {
			/* binary may not support --version */
		}
		return undefined;
	}

	private checkConfiguration(agent: CLIAgent): boolean {
		switch (agent.configType) {
			case "file":
			case "both":
				return this.checkConfigFiles(agent);
			case "env":
				return this.getConfiguredFlag(agent);
		}
	}

	private checkConfigFiles(agent: CLIAgent): boolean {
		for (const configPath of agent.configPaths) {
			const expandedPath = expandPath(configPath);

			if (existsSync(expandedPath)) {
				try {
					const content = readFileSync(expandedPath, "utf-8");
					if (
						content.includes("127.0.0.1") ||
						content.includes("localhost") ||
						content.includes("cliproxyapi")
					) {
						return true;
					}
				} catch {
					/* file not readable */
				}
			}
		}
		return false;
	}

	private getConfiguredFlag(_agent: CLIAgent): boolean {
		return false;
	}

	private getLastConfiguredDate(_agent: CLIAgent): Date | undefined {
		return undefined;
	}
}

let serviceInstance: AgentDetectionServiceImpl | null = null;

export function getAgentDetectionService(): AgentDetectionServiceImpl {
	if (!serviceInstance) {
		serviceInstance = new AgentDetectionServiceImpl();
	}
	return serviceInstance;
}

export { AgentDetectionServiceImpl as AgentDetectionService };

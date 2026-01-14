import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import {
	type ActiveProviderState,
	BUILT_IN_PROVIDERS,
	type UniversalProvider,
} from "../models/universal-provider.ts";

const CONFIG_DIR = join(homedir(), ".config", "quotio");
const PROVIDERS_FILE = join(CONFIG_DIR, "universal-providers.json");
const ACTIVE_STATE_FILE = join(CONFIG_DIR, "active-provider-state.json");
const SECRETS_FILE = join(CONFIG_DIR, ".secrets.json");

function ensureConfigDir(): void {
	if (!existsSync(CONFIG_DIR)) {
		mkdirSync(CONFIG_DIR, { recursive: true, mode: 0o700 });
	}
}

function loadJSON<T>(filePath: string, defaultValue: T): T {
	try {
		if (existsSync(filePath)) {
			const data = readFileSync(filePath, "utf-8");
			return JSON.parse(data) as T;
		}
	} catch {}
	return defaultValue;
}

function saveJSON<T>(filePath: string, data: T): void {
	ensureConfigDir();
	const dir = dirname(filePath);
	if (!existsSync(dir)) {
		mkdirSync(dir, { recursive: true });
	}
	writeFileSync(filePath, JSON.stringify(data, null, 2), { mode: 0o600 });
}

export class UniversalProviderService {
	private providers: UniversalProvider[] = [];
	private activeState: ActiveProviderState = { providerIdByAgent: {} };
	private secrets: Record<string, string> = {};

	constructor() {
		this.load();
	}

	private load(): void {
		const savedProviders = loadJSON<UniversalProvider[]>(PROVIDERS_FILE, []);

		const builtInIds = new Set(BUILT_IN_PROVIDERS.map((p) => p.id));
		const customProviders = savedProviders.filter((p) => !builtInIds.has(p.id));

		this.providers = [...BUILT_IN_PROVIDERS, ...customProviders];

		this.activeState = loadJSON<ActiveProviderState>(ACTIVE_STATE_FILE, {
			providerIdByAgent: {},
		});

		this.secrets = loadJSON<Record<string, string>>(SECRETS_FILE, {});
	}

	private saveProviders(): void {
		const customProviders = this.providers.filter((p) => !p.isBuiltIn);
		saveJSON(PROVIDERS_FILE, customProviders);
	}

	private saveActiveState(): void {
		saveJSON(ACTIVE_STATE_FILE, this.activeState);
	}

	private saveSecrets(): void {
		saveJSON(SECRETS_FILE, this.secrets);
	}

	getAllProviders(): UniversalProvider[] {
		return [...this.providers];
	}

	getEnabledProviders(): UniversalProvider[] {
		return this.providers.filter((p) => p.isEnabled);
	}

	getBuiltInProviders(): UniversalProvider[] {
		return this.providers.filter((p) => p.isBuiltIn);
	}

	getCustomProviders(): UniversalProvider[] {
		return this.providers.filter((p) => !p.isBuiltIn);
	}

	getProvider(id: string): UniversalProvider | undefined {
		return this.providers.find((p) => p.id === id);
	}

	addProvider(
		provider: Omit<UniversalProvider, "id" | "createdAt" | "updatedAt">,
	): UniversalProvider {
		const now = new Date().toISOString();
		const newProvider: UniversalProvider = {
			...provider,
			id: crypto.randomUUID(),
			createdAt: now,
			updatedAt: now,
		};
		this.providers.push(newProvider);
		this.saveProviders();
		return newProvider;
	}

	updateProvider(
		id: string,
		updates: Partial<UniversalProvider>,
	): UniversalProvider | undefined {
		const index = this.providers.findIndex((p) => p.id === id);
		if (index === -1) return undefined;

		const existing = this.providers[index];
		if (!existing) return undefined;

		const updated: UniversalProvider = {
			...existing,
			...updates,
			id: existing.id,
			isBuiltIn: existing.isBuiltIn,
			createdAt: existing.createdAt,
			updatedAt: new Date().toISOString(),
		};
		this.providers[index] = updated;
		this.saveProviders();
		return updated;
	}

	deleteProvider(id: string): boolean {
		const provider = this.providers.find((p) => p.id === id);
		if (!provider || provider.isBuiltIn) return false;

		this.providers = this.providers.filter((p) => p.id !== id);
		this.deleteAPIKey(id);
		this.saveProviders();
		return true;
	}

	getActiveProvider(agentId: string): UniversalProvider | undefined {
		const providerId = this.activeState.providerIdByAgent[agentId];
		if (!providerId) return undefined;
		return this.providers.find((p) => p.id === providerId);
	}

	setActiveProvider(agentId: string, providerId: string): void {
		this.activeState.providerIdByAgent[agentId] = providerId;
		this.saveActiveState();
	}

	clearActiveProvider(agentId: string): void {
		delete this.activeState.providerIdByAgent[agentId];
		this.saveActiveState();
	}

	storeAPIKey(providerId: string, apiKey: string): void {
		this.secrets[`universal.${providerId}`] = apiKey;
		this.saveSecrets();
	}

	getAPIKey(providerId: string): string | undefined {
		return this.secrets[`universal.${providerId}`];
	}

	hasAPIKey(providerId: string): boolean {
		return `universal.${providerId}` in this.secrets;
	}

	deleteAPIKey(providerId: string): void {
		delete this.secrets[`universal.${providerId}`];
		this.saveSecrets();
	}

	validateAPIKey(apiKey: string): { valid: boolean; error?: string } {
		if (!apiKey || apiKey.trim().length === 0) {
			return { valid: false, error: "API key cannot be empty" };
		}
		if (apiKey.length < 10) {
			return { valid: false, error: "API key is too short" };
		}
		return { valid: true };
	}
}

let instance: UniversalProviderService | null = null;

export function getUniversalProviderService(): UniversalProviderService {
	if (!instance) {
		instance = new UniversalProviderService();
	}
	return instance;
}

/**
 * Fallback Models for Virtual Model / Fallback Chain Support
 *
 * These models mirror the Swift FallbackModels.swift for cross-platform compatibility.
 * Virtual models allow routing requests through a chain of AI providers with automatic
 * fallback when one provider is exhausted (429, 503, etc.).
 *
 * Example: "quotio-opus-4-5-thinking" virtual model with fallback chain:
 *   1. Antigravity → gemini-claude-opus-4-5-thinking
 *   2. Kiro → kiro-claude-opus-4-5-agentic
 *   3. Claude Code → claude-opus-4-5-thinking
 */

import { AIProvider } from "./provider.ts";

// MARK: - Fallback Entry

/**
 * A single entry in a fallback chain, representing a Provider + Model combination
 */
export interface FallbackEntry {
	/** Unique identifier (UUID) */
	id: string;
	/** The AI provider for this entry */
	provider: AIProvider;
	/** The model ID to use with this provider */
	modelId: string;
	/** Priority in the fallback chain (1 = highest priority, tried first) */
	priority: number;
}

/**
 * Create a new fallback entry with auto-generated UUID
 */
export function createFallbackEntry(
	provider: AIProvider,
	modelId: string,
	priority: number,
): FallbackEntry {
	return {
		id: crypto.randomUUID(),
		provider,
		modelId,
		priority,
	};
}

/**
 * Display name for a fallback entry (for UI/logging)
 */
export function getFallbackEntryDisplayName(entry: FallbackEntry): string {
	const providerName = getProviderDisplayName(entry.provider);
	return `${providerName} → ${entry.modelId}`;
}

// MARK: - Virtual Model

/**
 * A virtual model with a fallback chain
 *
 * Virtual models are "fake" model names that resolve to real provider/model pairs.
 * When a request uses a virtual model, the proxy resolves it to the first available
 * entry in the fallback chain. If that fails (quota exceeded, rate limited, etc.),
 * it automatically tries the next entry.
 */
export interface VirtualModel {
	/** Unique identifier (UUID) */
	id: string;
	/** Name of the virtual model (used in API requests, e.g., "quotio-opus-4-5") */
	name: string;
	/** Ordered list of fallback entries */
	fallbackEntries: FallbackEntry[];
	/** Whether this virtual model is enabled */
	isEnabled: boolean;
}

/**
 * Create a new virtual model with auto-generated UUID
 */
export function createVirtualModel(
	name: string,
	fallbackEntries: FallbackEntry[] = [],
	isEnabled = true,
): VirtualModel {
	return {
		id: crypto.randomUUID(),
		name: name.trim(),
		fallbackEntries,
		isEnabled,
	};
}

/**
 * Get entries sorted by priority (lowest priority number first)
 */
export function getSortedEntries(model: VirtualModel): FallbackEntry[] {
	return [...model.fallbackEntries].sort((a, b) => a.priority - b.priority);
}

/**
 * Add a new entry at the end of the chain
 */
export function addFallbackEntry(
	model: VirtualModel,
	provider: AIProvider,
	modelId: string,
): VirtualModel {
	const nextPriority =
		model.fallbackEntries.length > 0
			? Math.max(...model.fallbackEntries.map((e) => e.priority)) + 1
			: 1;

	const entry = createFallbackEntry(provider, modelId, nextPriority);

	return {
		...model,
		fallbackEntries: [...model.fallbackEntries, entry],
	};
}

/**
 * Remove an entry by ID and reorder remaining priorities
 */
export function removeFallbackEntry(
	model: VirtualModel,
	entryId: string,
): VirtualModel {
	const filteredEntries = model.fallbackEntries.filter((e) => e.id !== entryId);
	const reorderedEntries = reorderPriorities(filteredEntries);

	return {
		...model,
		fallbackEntries: reorderedEntries,
	};
}

/**
 * Move entry from one position to another
 */
export function moveFallbackEntry(
	model: VirtualModel,
	fromIndex: number,
	toIndex: number,
): VirtualModel {
	const sorted = getSortedEntries(model);
	if (fromIndex < 0 || fromIndex >= sorted.length) return model;
	if (toIndex < 0 || toIndex >= sorted.length) return model;

	const [moved] = sorted.splice(fromIndex, 1);
	if (!moved) return model;
	sorted.splice(toIndex, 0, moved);

	// Update priorities based on new order
	const reorderedEntries = sorted.map((entry, index) => ({
		...entry,
		priority: index + 1,
	}));

	return {
		...model,
		fallbackEntries: reorderedEntries,
	};
}

/**
 * Reorder priorities to be sequential (1, 2, 3, ...)
 */
function reorderPriorities(entries: FallbackEntry[]): FallbackEntry[] {
	const sorted = [...entries].sort((a, b) => a.priority - b.priority);
	return sorted.map((entry, index) => ({
		...entry,
		priority: index + 1,
	}));
}

// MARK: - Fallback Configuration

/**
 * Global fallback configuration containing all virtual models
 */
export interface FallbackConfiguration {
	/** Whether fallback feature is globally enabled */
	isEnabled: boolean;
	/** List of virtual models */
	virtualModels: VirtualModel[];
}

/**
 * Create default (empty) fallback configuration
 */
export function createDefaultFallbackConfiguration(): FallbackConfiguration {
	return {
		isEnabled: false,
		virtualModels: [],
	};
}

/**
 * Find a virtual model by name (case-sensitive, must be enabled)
 */
export function findVirtualModel(
	config: FallbackConfiguration,
	name: string,
): VirtualModel | null {
	return (
		config.virtualModels.find((vm) => vm.name === name && vm.isEnabled) ?? null
	);
}

/**
 * Check if a model name is a virtual model
 */
export function isVirtualModel(
	config: FallbackConfiguration,
	name: string,
): boolean {
	return config.virtualModels.some((vm) => vm.name === name && vm.isEnabled);
}

/**
 * Get all enabled virtual model names
 */
export function getEnabledVirtualModelNames(
	config: FallbackConfiguration,
): string[] {
	return config.virtualModels.filter((vm) => vm.isEnabled).map((vm) => vm.name);
}

/**
 * Add a new virtual model (returns null if name already exists)
 */
export function addVirtualModel(
	config: FallbackConfiguration,
	name: string,
): FallbackConfiguration | null {
	const trimmedName = name.trim();

	// Check for duplicate name (case-insensitive)
	const isDuplicate = config.virtualModels.some(
		(vm) => vm.name.toLowerCase() === trimmedName.toLowerCase(),
	);

	if (isDuplicate) {
		return null;
	}

	const model = createVirtualModel(trimmedName);

	return {
		...config,
		virtualModels: [...config.virtualModels, model],
	};
}

/**
 * Remove a virtual model by ID
 */
export function removeVirtualModel(
	config: FallbackConfiguration,
	modelId: string,
): FallbackConfiguration {
	return {
		...config,
		virtualModels: config.virtualModels.filter((vm) => vm.id !== modelId),
	};
}

/**
 * Update a virtual model
 */
export function updateVirtualModel(
	config: FallbackConfiguration,
	model: VirtualModel,
): FallbackConfiguration {
	return {
		...config,
		virtualModels: config.virtualModels.map((vm) =>
			vm.id === model.id ? model : vm,
		),
	};
}

/**
 * Rename a virtual model (returns null if new name already exists)
 */
export function renameVirtualModel(
	config: FallbackConfiguration,
	modelId: string,
	newName: string,
): FallbackConfiguration | null {
	const trimmedName = newName.trim();

	// Check for duplicate name (case-insensitive), excluding the current model
	const isDuplicate = config.virtualModels.some(
		(vm) =>
			vm.id !== modelId && vm.name.toLowerCase() === trimmedName.toLowerCase(),
	);

	if (isDuplicate) {
		return null;
	}

	return {
		...config,
		virtualModels: config.virtualModels.map((vm) =>
			vm.id === modelId ? { ...vm, name: trimmedName } : vm,
		),
	};
}

/**
 * Toggle virtual model enabled state
 */
export function toggleVirtualModel(
	config: FallbackConfiguration,
	modelId: string,
): FallbackConfiguration {
	return {
		...config,
		virtualModels: config.virtualModels.map((vm) =>
			vm.id === modelId ? { ...vm, isEnabled: !vm.isEnabled } : vm,
		),
	};
}

// MARK: - Cached Entry Info

/**
 * Cached entry information for resuming fallback chains
 * When a fallback succeeds with entry N, we cache it for 60 minutes
 * so subsequent requests start from entry N instead of entry 0
 */
export interface CachedEntryInfo {
	/** The entry ID that was successful */
	entryId: string;
	/** When this cache entry was created */
	cachedAt: Date;
}

/**
 * Cache expiration time in milliseconds (60 minutes)
 */
export const CACHE_EXPIRATION_MS = 60 * 60 * 1000;

/**
 * Check if a cached entry is still valid
 */
export function isCacheValid(cached: CachedEntryInfo): boolean {
	const elapsed = Date.now() - cached.cachedAt.getTime();
	return elapsed < CACHE_EXPIRATION_MS;
}

// MARK: - Fallback Route State

/**
 * Runtime state for tracking the current position in a fallback chain
 * Used for UI display and debugging
 */
export interface FallbackRouteState {
	/** Name of the virtual model */
	virtualModelName: string;
	/** Current index in the fallback chain (0-based) */
	currentEntryIndex: number;
	/** The current entry being used */
	currentEntry: FallbackEntry;
	/** When this state was last updated */
	lastUpdated: Date;
	/** Total number of entries in the chain */
	totalEntries: number;
}

/**
 * Display string for the current route (e.g., "Antigravity → claude-opus-4-5")
 */
export function getRouteDisplayString(state: FallbackRouteState): string {
	return getFallbackEntryDisplayName(state.currentEntry);
}

/**
 * Progress string (e.g., "1/3")
 */
export function getRouteProgressString(state: FallbackRouteState): string {
	return `${state.currentEntryIndex + 1}/${state.totalEntries}`;
}

// MARK: - Provider Display Names

/**
 * Get display name for a provider
 */
function getProviderDisplayName(provider: AIProvider): string {
	const displayNames: Record<AIProvider, string> = {
		[AIProvider.GEMINI]: "Gemini CLI",
		[AIProvider.CLAUDE]: "Claude Code",
		[AIProvider.CODEX]: "Codex (OpenAI)",
		[AIProvider.QWEN]: "Qwen Code",
		[AIProvider.IFLOW]: "iFlow",
		[AIProvider.ANTIGRAVITY]: "Antigravity",
		[AIProvider.VERTEX]: "Vertex AI",
		[AIProvider.KIRO]: "Kiro",
		[AIProvider.COPILOT]: "GitHub Copilot",
		[AIProvider.CURSOR]: "Cursor",
		[AIProvider.TRAE]: "Trae",
		[AIProvider.GLM]: "GLM",
	};
	return displayNames[provider] ?? provider;
}

// MARK: - Serialization

/**
 * Serialize fallback configuration to JSON (for persistence)
 */
export function serializeFallbackConfiguration(
	config: FallbackConfiguration,
): string {
	return JSON.stringify(config, null, 2);
}

/**
 * Deserialize fallback configuration from JSON
 */
export function deserializeFallbackConfiguration(
	json: string,
): FallbackConfiguration {
	try {
		const parsed = JSON.parse(json) as FallbackConfiguration;

		// Validate structure
		if (typeof parsed.isEnabled !== "boolean") {
			return createDefaultFallbackConfiguration();
		}

		if (!Array.isArray(parsed.virtualModels)) {
			return createDefaultFallbackConfiguration();
		}

		// Validate and sanitize virtual models
		const validatedModels = parsed.virtualModels
			.filter(
				(vm) =>
					typeof vm.id === "string" &&
					typeof vm.name === "string" &&
					typeof vm.isEnabled === "boolean" &&
					Array.isArray(vm.fallbackEntries),
			)
			.map((vm) => ({
				...vm,
				fallbackEntries: vm.fallbackEntries.filter(
					(e) =>
						typeof e.id === "string" &&
						typeof e.provider === "string" &&
						typeof e.modelId === "string" &&
						typeof e.priority === "number",
				),
			}));

		return {
			isEnabled: parsed.isEnabled,
			virtualModels: validatedModels,
		};
	} catch {
		return createDefaultFallbackConfiguration();
	}
}

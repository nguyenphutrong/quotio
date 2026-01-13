import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type {
	CachedEntryInfo,
	FallbackConfiguration,
	FallbackEntry,
	FallbackRouteState,
	VirtualModel,
} from "../../models/fallback.ts";
import {
	CACHE_EXPIRATION_MS,
	createDefaultFallbackConfiguration,
	deserializeFallbackConfiguration,
	isCacheValid,
	serializeFallbackConfiguration,
} from "../../models/fallback.ts";
import type { AIProvider } from "../../models/provider.ts";
import { ensureDir, getConfigDir } from "../../utils/paths.ts";

const FALLBACK_CONFIG_FILE = "fallback-config.json";

let configCache: FallbackConfiguration | null = null;
const entryIdCache = new Map<string, CachedEntryInfo>();
const routeStates = new Map<string, FallbackRouteState>();

function getConfigPath(): string {
	return join(getConfigDir(), FALLBACK_CONFIG_FILE);
}

export async function loadFallbackConfiguration(): Promise<FallbackConfiguration> {
	if (configCache !== null) {
		return configCache;
	}

	const configPath = getConfigPath();

	try {
		if (existsSync(configPath)) {
			const content = readFileSync(configPath, "utf-8");
			configCache = deserializeFallbackConfiguration(content);
		} else {
			configCache = createDefaultFallbackConfiguration();
		}
	} catch {
		configCache = createDefaultFallbackConfiguration();
	}

	return configCache;
}

export async function saveFallbackConfiguration(
	config: FallbackConfiguration,
): Promise<void> {
	await ensureDir(getConfigDir());
	const configPath = getConfigPath();
	const content = serializeFallbackConfiguration(config);
	writeFileSync(configPath, content, "utf-8");
	configCache = config;
}

export async function getFallbackEnabled(): Promise<boolean> {
	const config = await loadFallbackConfiguration();
	return config.isEnabled;
}

export async function setFallbackEnabled(enabled: boolean): Promise<void> {
	const config = await loadFallbackConfiguration();
	await saveFallbackConfiguration({ ...config, isEnabled: enabled });
}

export async function getVirtualModels(): Promise<VirtualModel[]> {
	const config = await loadFallbackConfiguration();
	return config.virtualModels;
}

export async function getVirtualModel(
	id: string,
): Promise<VirtualModel | null> {
	const config = await loadFallbackConfiguration();
	return config.virtualModels.find((vm) => vm.id === id) ?? null;
}

export async function findVirtualModelByName(
	name: string,
): Promise<VirtualModel | null> {
	const config = await loadFallbackConfiguration();
	return (
		config.virtualModels.find((vm) => vm.name === name && vm.isEnabled) ?? null
	);
}

export async function isVirtualModelName(name: string): Promise<boolean> {
	const config = await loadFallbackConfiguration();
	return config.virtualModels.some((vm) => vm.name === name && vm.isEnabled);
}

export async function addVirtualModel(
	name: string,
): Promise<VirtualModel | null> {
	const config = await loadFallbackConfiguration();
	const trimmedName = name.trim();

	const isDuplicate = config.virtualModels.some(
		(vm) => vm.name.toLowerCase() === trimmedName.toLowerCase(),
	);

	if (isDuplicate) {
		return null;
	}

	const newModel: VirtualModel = {
		id: crypto.randomUUID(),
		name: trimmedName,
		fallbackEntries: [],
		isEnabled: true,
	};

	await saveFallbackConfiguration({
		...config,
		virtualModels: [...config.virtualModels, newModel],
	});

	return newModel;
}

export async function removeVirtualModel(modelId: string): Promise<boolean> {
	const config = await loadFallbackConfiguration();
	const model = config.virtualModels.find((vm) => vm.id === modelId);

	if (!model) {
		return false;
	}

	clearRouteState(model.name);

	await saveFallbackConfiguration({
		...config,
		virtualModels: config.virtualModels.filter((vm) => vm.id !== modelId),
	});

	return true;
}

export async function updateVirtualModel(
	model: VirtualModel,
): Promise<boolean> {
	const config = await loadFallbackConfiguration();
	const index = config.virtualModels.findIndex((vm) => vm.id === model.id);

	if (index === -1) {
		return false;
	}

	const updatedModels = [...config.virtualModels];
	updatedModels[index] = model;

	await saveFallbackConfiguration({
		...config,
		virtualModels: updatedModels,
	});

	return true;
}

export async function renameVirtualModel(
	modelId: string,
	newName: string,
): Promise<boolean> {
	const config = await loadFallbackConfiguration();
	const trimmedName = newName.trim();

	const isDuplicate = config.virtualModels.some(
		(vm) =>
			vm.id !== modelId && vm.name.toLowerCase() === trimmedName.toLowerCase(),
	);

	if (isDuplicate) {
		return false;
	}

	const model = config.virtualModels.find((vm) => vm.id === modelId);
	if (!model) {
		return false;
	}

	const oldName = model.name;
	const updatedModel = { ...model, name: trimmedName };

	await updateVirtualModel(updatedModel);

	const state = routeStates.get(oldName);
	if (state) {
		routeStates.delete(oldName);
		routeStates.set(trimmedName, {
			...state,
			virtualModelName: trimmedName,
		});
	}

	return true;
}

export async function toggleVirtualModel(modelId: string): Promise<boolean> {
	const config = await loadFallbackConfiguration();
	const model = config.virtualModels.find((vm) => vm.id === modelId);

	if (!model) {
		return false;
	}

	if (model.isEnabled) {
		clearRouteState(model.name);
	}

	const updatedModel = { ...model, isEnabled: !model.isEnabled };
	return await updateVirtualModel(updatedModel);
}

export async function addFallbackEntry(
	modelId: string,
	provider: AIProvider,
	modelName: string,
): Promise<FallbackEntry | null> {
	const config = await loadFallbackConfiguration();
	const model = config.virtualModels.find((vm) => vm.id === modelId);

	if (!model) {
		return null;
	}

	const nextPriority =
		model.fallbackEntries.length > 0
			? Math.max(...model.fallbackEntries.map((e) => e.priority)) + 1
			: 1;

	const newEntry: FallbackEntry = {
		id: crypto.randomUUID(),
		provider,
		modelId: modelName,
		priority: nextPriority,
	};

	const updatedModel = {
		...model,
		fallbackEntries: [...model.fallbackEntries, newEntry],
	};

	await updateVirtualModel(updatedModel);
	return newEntry;
}

export async function removeFallbackEntry(
	modelId: string,
	entryId: string,
): Promise<boolean> {
	const config = await loadFallbackConfiguration();
	const model = config.virtualModels.find((vm) => vm.id === modelId);

	if (!model) {
		return false;
	}

	const filteredEntries = model.fallbackEntries.filter((e) => e.id !== entryId);

	if (filteredEntries.length === model.fallbackEntries.length) {
		return false;
	}

	const reorderedEntries = filteredEntries
		.sort((a, b) => a.priority - b.priority)
		.map((e, i) => ({ ...e, priority: i + 1 }));

	const updatedModel = { ...model, fallbackEntries: reorderedEntries };

	clearRouteState(model.name);
	await updateVirtualModel(updatedModel);

	return true;
}

export async function moveFallbackEntry(
	modelId: string,
	fromIndex: number,
	toIndex: number,
): Promise<boolean> {
	const config = await loadFallbackConfiguration();
	const model = config.virtualModels.find((vm) => vm.id === modelId);

	if (!model) {
		return false;
	}

	const sorted = [...model.fallbackEntries].sort(
		(a, b) => a.priority - b.priority,
	);

	if (fromIndex < 0 || fromIndex >= sorted.length) return false;
	if (toIndex < 0 || toIndex >= sorted.length) return false;

	const [moved] = sorted.splice(fromIndex, 1);
	if (!moved) return false;
	sorted.splice(toIndex, 0, moved);

	const reorderedEntries = sorted.map((e, i) => ({ ...e, priority: i + 1 }));

	const updatedModel = { ...model, fallbackEntries: reorderedEntries };

	clearRouteState(model.name);
	await updateVirtualModel(updatedModel);

	return true;
}

export function getCachedEntryId(virtualModelName: string): string | null {
	const cached = entryIdCache.get(virtualModelName);
	if (!cached) {
		return null;
	}

	if (!isCacheValid(cached)) {
		entryIdCache.delete(virtualModelName);
		return null;
	}

	return cached.entryId;
}

export function setCachedEntryId(
	virtualModelName: string,
	entryId: string,
): void {
	entryIdCache.set(virtualModelName, {
		entryId,
		cachedAt: new Date(),
	});
}

export function clearCachedEntryId(virtualModelName: string): void {
	entryIdCache.delete(virtualModelName);
}

export function updateRouteState(
	virtualModelName: string,
	entryIndex: number,
	entry: FallbackEntry,
	totalEntries: number,
): void {
	routeStates.set(virtualModelName, {
		virtualModelName,
		currentEntryIndex: entryIndex,
		currentEntry: entry,
		lastUpdated: new Date(),
		totalEntries,
	});
}

export function clearRouteState(virtualModelName: string): void {
	routeStates.delete(virtualModelName);
	entryIdCache.delete(virtualModelName);
}

export function clearAllRouteStates(): void {
	routeStates.clear();
	entryIdCache.clear();
}

export function getRouteState(
	virtualModelName: string,
): FallbackRouteState | null {
	return routeStates.get(virtualModelName) ?? null;
}

export function getAllRouteStates(): FallbackRouteState[] {
	return Array.from(routeStates.values()).sort((a, b) =>
		a.virtualModelName.localeCompare(b.virtualModelName),
	);
}

export async function exportConfiguration(): Promise<string> {
	const config = await loadFallbackConfiguration();
	return serializeFallbackConfiguration(config);
}

export async function importConfiguration(json: string): Promise<boolean> {
	try {
		const config = deserializeFallbackConfiguration(json);
		await saveFallbackConfiguration(config);
		clearAllRouteStates();
		return true;
	} catch {
		return false;
	}
}

export async function resetToDefaults(): Promise<void> {
	await saveFallbackConfiguration(createDefaultFallbackConfiguration());
	clearAllRouteStates();
}

export function invalidateCache(): void {
	configCache = null;
}

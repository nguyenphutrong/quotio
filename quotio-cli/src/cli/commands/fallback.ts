import { parseArgs } from "node:util";
import { PROVIDER_METADATA, parseProvider } from "../../models/provider.ts";
import {
	addFallbackEntry,
	addVirtualModel,
	clearAllRouteStates,
	exportConfiguration,
	getAllRouteStates,
	getFallbackEnabled,
	getVirtualModel,
	getVirtualModels,
	importConfiguration,
	moveFallbackEntry,
	removeFallbackEntry,
	removeVirtualModel,
	renameVirtualModel,
	setFallbackEnabled,
	toggleVirtualModel,
} from "../../services/fallback/settings-service.ts";
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

const modelColumns: TableColumn[] = [
	{ key: "name", header: "Name", width: 20 },
	{ key: "entries", header: "Fallback Entries", width: 8 },
	{ key: "enabled", header: "Enabled", width: 8 },
];

const entryColumns: TableColumn[] = [
	{ key: "priority", header: "#", width: 3 },
	{ key: "provider", header: "Provider", width: 15 },
	{ key: "model", header: "Model", width: 25 },
];

const routeStateColumns: TableColumn[] = [
	{ key: "virtualModel", header: "Virtual Model", width: 20 },
	{ key: "currentEntry", header: "Current Entry", width: 30 },
	{ key: "position", header: "Position", width: 10 },
	{ key: "lastUpdated", header: "Last Updated", width: 15 },
];

async function handleFallback(
	args: string[],
	ctx: CLIContext,
): Promise<CommandResult> {
	const { values, positionals } = parseArgs({
		args,
		options: {
			help: { type: "boolean", short: "h", default: false },
			name: { type: "string", short: "n" },
			model: { type: "string", short: "m" },
			provider: { type: "string", short: "p" },
			id: { type: "string" },
			from: { type: "string" },
			to: { type: "string" },
		},
		allowPositionals: true,
		strict: false,
	});

	const subcommand = positionals[0] ?? "list";

	if (values.help) {
		printFallbackHelp();
		return { success: true };
	}

	switch (subcommand) {
		case "list":
		case "ls":
			return await listVirtualModels(ctx);
		case "show":
			return await showVirtualModel(ctx, values.name as string | undefined);
		case "status":
			return await showStatus(ctx);
		case "add":
			return await handleAdd(ctx, positionals, values);
		case "remove":
		case "rm":
			return await handleRemove(ctx, positionals, values);
		case "move":
			return await handleMove(values);
		case "rename":
			return await handleRename(values);
		case "toggle":
			return await handleToggle(values);
		case "enable":
			return await handleEnable(true);
		case "disable":
			return await handleEnable(false);
		case "routes":
			return await showRouteStates(ctx);
		case "clear-routes":
			return await handleClearRoutes();
		case "export":
			return await handleExport();
		case "import":
			return await handleImport(positionals[1]);
		default:
			logger.error(`Unknown fallback subcommand: ${subcommand}`);
			printFallbackHelp();
			return { success: false, message: `Unknown subcommand: ${subcommand}` };
	}
}

function printFallbackHelp(): void {
	const providers = Object.values(PROVIDER_METADATA)
		.map((p) => p.id)
		.slice(0, 6)
		.join(", ");

	const help = `
quotio fallback - Manage fallback virtual models

Usage: quotio fallback <subcommand> [options]

Subcommands:
  list, ls            List all virtual models (default)
  show --name <name>  Show entries for a virtual model
  status              Show fallback enabled status
  add model <name>    Create a new virtual model
  add entry           Add a fallback entry (use --name, --provider, --model)
  remove model        Remove a virtual model (use --name or --id)
  remove entry        Remove a fallback entry (use --name, --id)
  move                Move entry position (use --name, --from, --to)
  rename              Rename virtual model (use --id, --name)
  toggle --name       Toggle virtual model enabled state
  enable              Enable fallback feature globally
  disable             Disable fallback feature globally
  routes              Show current fallback route states
  clear-routes        Clear all route states (reset caches)
  export              Export configuration as JSON
  import <file>       Import configuration from JSON file

Options:
  --name, -n <name>      Virtual model name
  --model, -m <model>    Provider model ID (e.g., claude-sonnet-4)
  --provider, -p <prov>  Provider ID (${providers}, ...)
  --id <id>              Entity ID (for model or entry)
  --from <index>         Source index for move (0-based)
  --to <index>           Destination index for move (0-based)
  --help, -h             Show this help message

Examples:
  quotio fallback list
  quotio fallback add model "fast-model"
  quotio fallback add entry -n "fast-model" -p claude -m claude-sonnet-4
  quotio fallback add entry -n "fast-model" -p gemini -m gemini-2.5-pro
  quotio fallback show -n "fast-model"
  quotio fallback move -n "fast-model" --from 0 --to 1
  quotio fallback remove entry -n "fast-model" --id <entry-id>
  quotio fallback toggle -n "fast-model"
  quotio fallback export > fallback.json
  quotio fallback import fallback.json
`.trim();

	logger.print(help);
}

async function listVirtualModels(ctx: CLIContext): Promise<CommandResult> {
	const models = await getVirtualModels();
	const enabled = await getFallbackEnabled();

	if (models.length === 0) {
		logger.print(colors.dim("No virtual models configured."));
		logger.print("\nRun 'quotio fallback add model <name>' to create one.");
		return { success: true, data: [] };
	}

	const rows = models.map((vm) => ({
		name: vm.name,
		entries: String(vm.fallbackEntries.length),
		enabled: vm.isEnabled ? colors.green("Yes") : colors.dim("No"),
	}));

	if (ctx.format === "json") {
		logger.print(formatJson({ enabled, models }));
	} else {
		const statusLine = enabled
			? colors.green("Fallback: Enabled")
			: colors.dim("Fallback: Disabled");
		logger.print(`${statusLine}\n`);
		logger.print(formatTable(rows, modelColumns));
	}

	return { success: true, data: { enabled, models } };
}

async function showVirtualModel(
	ctx: CLIContext,
	name: string | undefined,
): Promise<CommandResult> {
	if (!name) {
		return { success: false, message: "Missing --name option" };
	}

	const models = await getVirtualModels();
	const model = models.find(
		(vm) => vm.name.toLowerCase() === name.toLowerCase(),
	);

	if (!model) {
		return { success: false, message: `Virtual model not found: ${name}` };
	}

	if (ctx.format === "json") {
		logger.print(formatJson(model));
	} else {
		const enabledStr = model.isEnabled
			? colors.green("Enabled")
			: colors.dim("Disabled");
		logger.print(`${colors.bold(model.name)} (${enabledStr})\n`);

		if (model.fallbackEntries.length === 0) {
			logger.print(colors.dim("No fallback entries."));
			logger.print(
				"\nRun 'quotio fallback add entry' to add a provider/model.",
			);
		} else {
			const sorted = [...model.fallbackEntries].sort(
				(a, b) => a.priority - b.priority,
			);
			const rows = sorted.map((e) => {
				const meta =
					PROVIDER_METADATA[e.provider as keyof typeof PROVIDER_METADATA];
				return {
					priority: String(e.priority),
					provider: meta?.displayName ?? e.provider,
					model: e.modelId,
				};
			});
			logger.print(formatTable(rows, entryColumns));
			logger.print(colors.dim(`\nIDs: ${sorted.map((e) => e.id).join(", ")}`));
		}
	}

	return { success: true, data: model };
}

async function showStatus(ctx: CLIContext): Promise<CommandResult> {
	const enabled = await getFallbackEnabled();
	const models = await getVirtualModels();

	if (ctx.format === "json") {
		logger.print(formatJson({ enabled, modelCount: models.length }));
	} else {
		const status = enabled ? colors.green("Enabled") : colors.red("Disabled");
		logger.print(`Fallback status: ${status}`);
		logger.print(`Virtual models: ${models.length}`);
	}

	return { success: true, data: { enabled, modelCount: models.length } };
}

async function handleAdd(
	ctx: CLIContext,
	positionals: string[],
	values: Record<string, unknown>,
): Promise<CommandResult> {
	const subType = positionals[1];

	if (subType === "model") {
		const name = positionals[2] || (values.name as string | undefined);
		if (!name) {
			return { success: false, message: "Missing model name" };
		}

		const model = await addVirtualModel(name);
		if (!model) {
			return {
				success: false,
				message: `Failed to create model. Name may already exist: ${name}`,
			};
		}

		logger.print(`Created virtual model: ${colors.green(model.name)}`);
		return { success: true, data: model };
	}

	if (subType === "entry") {
		const modelName = values.name as string | undefined;
		const providerStr = values.provider as string | undefined;
		const modelId = values.model as string | undefined;

		if (!modelName) {
			return { success: false, message: "Missing --name (virtual model name)" };
		}
		if (!providerStr) {
			return { success: false, message: "Missing --provider" };
		}
		if (!modelId) {
			return { success: false, message: "Missing --model" };
		}

		const provider = parseProvider(providerStr);
		if (!provider) {
			return { success: false, message: `Unknown provider: ${providerStr}` };
		}

		const models = await getVirtualModels();
		const model = models.find(
			(vm) => vm.name.toLowerCase() === modelName.toLowerCase(),
		);

		if (!model) {
			return {
				success: false,
				message: `Virtual model not found: ${modelName}`,
			};
		}

		const entry = await addFallbackEntry(model.id, provider, modelId);
		if (!entry) {
			return { success: false, message: "Failed to add fallback entry" };
		}

		const meta = PROVIDER_METADATA[provider];
		logger.print(
			`Added entry: ${colors.green(meta.displayName)} / ${modelId} (priority ${entry.priority})`,
		);
		return { success: true, data: entry };
	}

	return {
		success: false,
		message: "Unknown add subtype. Use 'model' or 'entry'.",
	};
}

async function handleRemove(
	ctx: CLIContext,
	positionals: string[],
	values: Record<string, unknown>,
): Promise<CommandResult> {
	const subType = positionals[1];

	if (subType === "model") {
		const name = values.name as string | undefined;
		const id = values.id as string | undefined;

		let modelId = id;
		if (!modelId && name) {
			const models = await getVirtualModels();
			const model = models.find(
				(vm) => vm.name.toLowerCase() === name.toLowerCase(),
			);
			modelId = model?.id;
		}

		if (!modelId) {
			return { success: false, message: "Missing --name or --id" };
		}

		const success = await removeVirtualModel(modelId);
		if (!success) {
			return { success: false, message: "Failed to remove virtual model" };
		}

		logger.print("Removed virtual model");
		return { success: true };
	}

	if (subType === "entry") {
		const modelName = values.name as string | undefined;
		const entryId = values.id as string | undefined;

		if (!modelName) {
			return { success: false, message: "Missing --name (virtual model name)" };
		}
		if (!entryId) {
			return { success: false, message: "Missing --id (entry ID)" };
		}

		const models = await getVirtualModels();
		const model = models.find(
			(vm) => vm.name.toLowerCase() === modelName.toLowerCase(),
		);

		if (!model) {
			return {
				success: false,
				message: `Virtual model not found: ${modelName}`,
			};
		}

		const success = await removeFallbackEntry(model.id, entryId);
		if (!success) {
			return { success: false, message: "Failed to remove entry" };
		}

		logger.print("Removed fallback entry");
		return { success: true };
	}

	return {
		success: false,
		message: "Unknown remove subtype. Use 'model' or 'entry'.",
	};
}

async function handleMove(
	values: Record<string, unknown>,
): Promise<CommandResult> {
	const modelName = values.name as string | undefined;
	const fromStr = values.from as string | undefined;
	const toStr = values.to as string | undefined;

	if (!modelName) {
		return { success: false, message: "Missing --name" };
	}
	if (!fromStr || !toStr) {
		return { success: false, message: "Missing --from or --to index" };
	}

	const fromIndex = Number.parseInt(fromStr, 10);
	const toIndex = Number.parseInt(toStr, 10);

	if (Number.isNaN(fromIndex) || Number.isNaN(toIndex)) {
		return { success: false, message: "Invalid index values" };
	}

	const models = await getVirtualModels();
	const model = models.find(
		(vm) => vm.name.toLowerCase() === modelName.toLowerCase(),
	);

	if (!model) {
		return { success: false, message: `Virtual model not found: ${modelName}` };
	}

	const success = await moveFallbackEntry(model.id, fromIndex, toIndex);
	if (!success) {
		return { success: false, message: "Failed to move entry" };
	}

	logger.print(`Moved entry from position ${fromIndex} to ${toIndex}`);
	return { success: true };
}

async function handleRename(
	values: Record<string, unknown>,
): Promise<CommandResult> {
	const id = values.id as string | undefined;
	const newName = values.name as string | undefined;

	if (!id) {
		return { success: false, message: "Missing --id" };
	}
	if (!newName) {
		return { success: false, message: "Missing --name (new name)" };
	}

	const success = await renameVirtualModel(id, newName);
	if (!success) {
		return {
			success: false,
			message: "Failed to rename. Model not found or name already exists.",
		};
	}

	logger.print(`Renamed to: ${colors.green(newName)}`);
	return { success: true };
}

async function handleToggle(
	values: Record<string, unknown>,
): Promise<CommandResult> {
	const name = values.name as string | undefined;

	if (!name) {
		return { success: false, message: "Missing --name" };
	}

	const models = await getVirtualModels();
	const model = models.find(
		(vm) => vm.name.toLowerCase() === name.toLowerCase(),
	);

	if (!model) {
		return { success: false, message: `Virtual model not found: ${name}` };
	}

	const success = await toggleVirtualModel(model.id);
	if (!success) {
		return { success: false, message: "Failed to toggle model" };
	}

	const refreshed = await getVirtualModel(model.id);
	const status = refreshed?.isEnabled
		? colors.green("enabled")
		: colors.dim("disabled");
	logger.print(`${name} is now ${status}`);
	return { success: true };
}

async function handleEnable(enabled: boolean): Promise<CommandResult> {
	await setFallbackEnabled(enabled);
	const status = enabled ? colors.green("enabled") : colors.dim("disabled");
	logger.print(`Fallback feature is now ${status}`);
	return { success: true };
}

async function showRouteStates(ctx: CLIContext): Promise<CommandResult> {
	const states = getAllRouteStates();

	if (states.length === 0) {
		logger.print(colors.dim("No active fallback routes."));
		return { success: true, data: [] };
	}

	if (ctx.format === "json") {
		logger.print(formatJson(states));
	} else {
		const rows = states.map((s) => {
			const meta =
				PROVIDER_METADATA[
					s.currentEntry.provider as keyof typeof PROVIDER_METADATA
				];
			return {
				virtualModel: s.virtualModelName,
				currentEntry: `${meta?.displayName ?? s.currentEntry.provider} / ${s.currentEntry.modelId}`,
				position: `${s.currentEntryIndex + 1}/${s.totalEntries}`,
				lastUpdated: formatRelativeTime(s.lastUpdated),
			};
		});
		logger.print(formatTable(rows, routeStateColumns));
	}

	return { success: true, data: states };
}

async function handleClearRoutes(): Promise<CommandResult> {
	clearAllRouteStates();
	logger.print("Cleared all fallback route states");
	return { success: true };
}

async function handleExport(): Promise<CommandResult> {
	const json = await exportConfiguration();
	logger.print(json);
	return { success: true };
}

async function handleImport(
	filePath: string | undefined,
): Promise<CommandResult> {
	if (!filePath) {
		return { success: false, message: "Missing file path" };
	}

	try {
		const file = Bun.file(filePath);
		const content = await file.text();
		const success = await importConfiguration(content);

		if (!success) {
			return { success: false, message: "Failed to import configuration" };
		}

		logger.print(`Imported configuration from ${filePath}`);
		return { success: true };
	} catch (err) {
		const msg = err instanceof Error ? err.message : String(err);
		return { success: false, message: `Failed to read file: ${msg}` };
	}
}

function formatRelativeTime(date: Date): string {
	const now = Date.now();
	const diffMs = now - date.getTime();
	const diffSec = Math.floor(diffMs / 1000);

	if (diffSec < 60) return `${diffSec}s ago`;
	if (diffSec < 3600) return `${Math.floor(diffSec / 60)}m ago`;
	if (diffSec < 86400) return `${Math.floor(diffSec / 3600)}h ago`;
	return `${Math.floor(diffSec / 86400)}d ago`;
}

registerCommand("fallback", handleFallback);

export { handleFallback };

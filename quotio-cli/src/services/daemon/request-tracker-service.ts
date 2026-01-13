import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import type {
	RequestHistoryStore,
	RequestLog,
	RequestStats,
} from "../../models/request-log.ts";
import {
	CURRENT_VERSION,
	addEntryToStore,
	calculateStats,
	createEmptyStats,
	createEmptyStore,
} from "../../models/request-log.ts";
import { getCacheDir } from "../../utils/paths.ts";

const HISTORY_FILE = "request-history.json";

class RequestTrackerService {
	private store: RequestHistoryStore = createEmptyStore();
	private isActive = false;
	private storagePath: string;

	constructor() {
		this.storagePath = join(getCacheDir(), HISTORY_FILE);
		this.loadFromDisk();
	}

	start(): void {
		this.isActive = true;
	}

	stop(): void {
		this.isActive = false;
	}

	getStatus(): { isActive: boolean; entryCount: number } {
		return { isActive: this.isActive, entryCount: this.store.entries.length };
	}

	getHistory(): RequestLog[] {
		return this.store.entries;
	}

	getStats(): RequestStats {
		return calculateStats(this.store.entries);
	}

	addEntry(entry: RequestLog): void {
		this.store = addEntryToStore(this.store, entry);
		this.saveToDisk();
	}

	clear(): void {
		this.store = createEmptyStore();
		this.saveToDisk();
	}

	getRecentRequests(minutes: number): RequestLog[] {
		const cutoff = new Date(Date.now() - minutes * 60 * 1000).toISOString();
		return this.store.entries.filter((e) => e.timestamp >= cutoff);
	}

	getRequestsByProvider(provider: string): RequestLog[] {
		return this.store.entries.filter((e) => e.provider === provider);
	}

	private loadFromDisk(): void {
		if (!existsSync(this.storagePath)) return;

		try {
			const data = readFileSync(this.storagePath, "utf-8");
			const parsed = JSON.parse(data) as RequestHistoryStore;
			if (parsed.version === CURRENT_VERSION && Array.isArray(parsed.entries)) {
				this.store = parsed;
			}
		} catch {
			this.store = createEmptyStore();
		}
	}

	private saveToDisk(): void {
		try {
			const dir = dirname(this.storagePath);
			if (!existsSync(dir)) {
				mkdirSync(dir, { recursive: true });
			}
			writeFileSync(this.storagePath, JSON.stringify(this.store, null, 2));
		} catch {}
	}
}

export const requestTrackerService = new RequestTrackerService();

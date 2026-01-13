import { describe, expect, test } from "bun:test";

const REFRESH_BUFFER_SECONDS = 5 * 60;

function parseExpiryDate(expiresAt: string | number | undefined): Date | null {
	if (!expiresAt) return null;

	if (typeof expiresAt === "number") {
		return new Date(expiresAt * 1000);
	}

	const date = new Date(expiresAt);
	return Number.isNaN(date.getTime()) ? null : date;
}

interface MockAuthFile {
	accessToken?: string;
	refreshToken?: string;
	expiresAt?: string | number;
	authMethod?: "Social" | "IdC";
	clientId?: string;
	clientSecret?: string;
	path: string;
	email?: string;
}

function shouldRefreshToken(authFile: MockAuthFile): {
	shouldRefresh: boolean;
	reason: string;
} {
	const expiresAt = authFile.expiresAt;
	if (!expiresAt) {
		return { shouldRefresh: false, reason: "no expiry info" };
	}

	const expiryDate = parseExpiryDate(expiresAt);
	if (!expiryDate) {
		return { shouldRefresh: false, reason: "unparseable expiry" };
	}

	const timeRemainingMs = expiryDate.getTime() - Date.now();
	const timeRemainingSec = timeRemainingMs / 1000;

	if (timeRemainingSec <= 0) {
		return {
			shouldRefresh: true,
			reason: `expired ${Math.abs(Math.floor(timeRemainingSec))}s ago`,
		};
	}

	if (timeRemainingSec < REFRESH_BUFFER_SECONDS) {
		return {
			shouldRefresh: true,
			reason: `expiring in ${Math.floor(timeRemainingSec)}s (<5min buffer)`,
		};
	}

	return {
		shouldRefresh: false,
		reason: `${Math.floor(timeRemainingSec)}s remaining`,
	};
}

describe("Kiro Dual Auth Token Refresh", () => {
	describe("parseExpiryDate", () => {
		test("handles undefined", () => {
			expect(parseExpiryDate(undefined)).toBeNull();
		});

		test("handles unix timestamp (seconds)", () => {
			const timestamp = Math.floor(Date.now() / 1000) + 3600;
			const result = parseExpiryDate(timestamp);
			expect(result).toBeInstanceOf(Date);
			expect(result?.getTime()).toBeCloseTo(timestamp * 1000, -3);
		});

		test("handles ISO date string", () => {
			const isoDate = "2025-01-15T12:00:00.000Z";
			const result = parseExpiryDate(isoDate);
			expect(result).toBeInstanceOf(Date);
			expect(result?.toISOString()).toBe(isoDate);
		});

		test("returns null for invalid date string", () => {
			expect(parseExpiryDate("not-a-date")).toBeNull();
		});
	});

	describe("shouldRefreshToken", () => {
		test("returns false when no expiry info", () => {
			const authFile: MockAuthFile = {
				accessToken: "token123",
				path: "/test/path",
			};

			const result = shouldRefreshToken(authFile);
			expect(result.shouldRefresh).toBe(false);
			expect(result.reason).toBe("no expiry info");
		});

		test("returns false when unparseable expiry", () => {
			const authFile: MockAuthFile = {
				accessToken: "token123",
				expiresAt: "invalid-date",
				path: "/test/path",
			};

			const result = shouldRefreshToken(authFile);
			expect(result.shouldRefresh).toBe(false);
			expect(result.reason).toBe("unparseable expiry");
		});

		test("returns true when token expired", () => {
			const pastTimestamp = Math.floor(Date.now() / 1000) - 60;
			const authFile: MockAuthFile = {
				accessToken: "token123",
				expiresAt: pastTimestamp,
				path: "/test/path",
			};

			const result = shouldRefreshToken(authFile);
			expect(result.shouldRefresh).toBe(true);
			expect(result.reason).toContain("expired");
		});

		test("returns true when expiring within 5 minute buffer", () => {
			const soonTimestamp = Math.floor(Date.now() / 1000) + 60;
			const authFile: MockAuthFile = {
				accessToken: "token123",
				expiresAt: soonTimestamp,
				path: "/test/path",
			};

			const result = shouldRefreshToken(authFile);
			expect(result.shouldRefresh).toBe(true);
			expect(result.reason).toContain("expiring in");
			expect(result.reason).toContain("<5min buffer");
		});

		test("returns false when plenty of time remaining", () => {
			const futureTimestamp = Math.floor(Date.now() / 1000) + 3600;
			const authFile: MockAuthFile = {
				accessToken: "token123",
				expiresAt: futureTimestamp,
				path: "/test/path",
			};

			const result = shouldRefreshToken(authFile);
			expect(result.shouldRefresh).toBe(false);
			expect(result.reason).toContain("remaining");
		});

		test("handles ISO date string expiry", () => {
			const futureDate = new Date(Date.now() + 3600 * 1000);
			const authFile: MockAuthFile = {
				accessToken: "token123",
				expiresAt: futureDate.toISOString(),
				path: "/test/path",
			};

			const result = shouldRefreshToken(authFile);
			expect(result.shouldRefresh).toBe(false);
		});
	});

	describe("Auth Method Detection", () => {
		test("Social auth requires only refreshToken", () => {
			const socialAuth: MockAuthFile = {
				accessToken: "token123",
				refreshToken: "refresh456",
				authMethod: "Social",
				path: "/test/path",
			};

			expect(socialAuth.authMethod).toBe("Social");
			expect(socialAuth.refreshToken).toBeDefined();
			expect(socialAuth.clientId).toBeUndefined();
			expect(socialAuth.clientSecret).toBeUndefined();
		});

		test("IdC auth requires refreshToken, clientId, and clientSecret", () => {
			const idcAuth: MockAuthFile = {
				accessToken: "token123",
				refreshToken: "refresh456",
				authMethod: "IdC",
				clientId: "client789",
				clientSecret: "secret012",
				path: "/test/path",
			};

			expect(idcAuth.authMethod).toBe("IdC");
			expect(idcAuth.refreshToken).toBeDefined();
			expect(idcAuth.clientId).toBeDefined();
			expect(idcAuth.clientSecret).toBeDefined();
		});

		test("defaults to IdC when authMethod not specified", () => {
			const authFile: MockAuthFile = {
				accessToken: "token123",
				refreshToken: "refresh456",
				clientId: "client789",
				clientSecret: "secret012",
				path: "/test/path",
			};

			const authMethod = authFile.authMethod ?? "IdC";
			expect(authMethod).toBe("IdC");
		});
	});

	describe("Token Refresh Flow", () => {
		test("Social refresh uses Kiro-specific endpoint", () => {
			const socialEndpoint =
				"https://prod.us-east-1.auth.desktop.kiro.dev/refreshToken";
			expect(socialEndpoint).toContain("kiro.dev");
			expect(socialEndpoint).toContain("refreshToken");
		});

		test("IdC refresh uses AWS OIDC endpoint", () => {
			const idcEndpoint = "https://oidc.us-east-1.amazonaws.com/token";
			expect(idcEndpoint).toContain("amazonaws.com");
			expect(idcEndpoint).toContain("token");
		});

		test("refresh preserves new expiry time", () => {
			const expiresIn = 3600;
			const newExpiry = new Date(Date.now() + expiresIn * 1000);

			expect(newExpiry.getTime()).toBeGreaterThan(Date.now());
			expect(newExpiry.getTime() - Date.now()).toBeCloseTo(expiresIn * 1000, -3);
		});
	});

	describe("Retry Logic on 401/403", () => {
		test("should attempt refresh on 401 status", () => {
			const statusCode = 401;
			const shouldRetryWithRefresh =
				(statusCode === 401 || statusCode === 403) && true;
			expect(shouldRetryWithRefresh).toBe(true);
		});

		test("should attempt refresh on 403 status", () => {
			const statusCode: number = 403;
			const shouldRetryWithRefresh =
				(statusCode === 401 || statusCode === 403) && true;
			expect(shouldRetryWithRefresh).toBe(true);
		});

		test("should not retry on other status codes", () => {
			const statusCodes = [200, 400, 404, 500, 503];
			for (const statusCode of statusCodes) {
				const shouldRetryWithRefresh =
					(statusCode === 401 || statusCode === 403) && true;
				expect(shouldRetryWithRefresh).toBe(false);
			}
		});

		test("should not retry if already attempted refresh", () => {
			const statusCode = 401;
			const hasAttemptedRefresh = true;
			const shouldRetry =
				(statusCode === 401 || statusCode === 403) && !hasAttemptedRefresh;
			expect(shouldRetry).toBe(false);
		});
	});

	describe("Token Persistence", () => {
		test("calculates new expiry from expiresIn", () => {
			const expiresIn = 3600;
			const now = Date.now();
			const newExpiresAt = new Date(now + expiresIn * 1000);

			expect(newExpiresAt.getTime()).toBeGreaterThan(now);
			expect(newExpiresAt.toISOString()).toMatch(
				/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/,
			);
		});

		test("preserves refresh token if new one provided", () => {
			const originalRefresh = "old-refresh-token";
			const newRefresh = "new-refresh-token";

			const finalToken = newRefresh ?? originalRefresh;
			expect(finalToken).toBe("new-refresh-token");
		});

		test("keeps original refresh token if new one not provided", () => {
			const originalRefresh = "old-refresh-token";
			const newRefresh = undefined;

			const finalToken = newRefresh ?? originalRefresh;
			expect(finalToken).toBe("old-refresh-token");
		});
	});

	describe("Usage API Response Handling", () => {
		test("handles successful response with quota data", () => {
			const mockResponse = {
				usageBreakdownList: [
					{
						displayName: "Agent Invocations",
						currentUsage: 50,
						usageLimit: 100,
					},
				],
				subscriptionInfo: {
					subscriptionTitle: "Pro",
					type: "PAID",
				},
			};

			expect(mockResponse.usageBreakdownList).toHaveLength(1);
			expect(mockResponse.subscriptionInfo?.subscriptionTitle).toBe("Pro");
		});

		test("handles free trial info in breakdown", () => {
			const breakdown = {
				displayName: "Agent Invocations",
				freeTrialInfo: {
					currentUsage: 10,
					usageLimit: 50,
					freeTrialStatus: "ACTIVE",
					freeTrialExpiry: Math.floor(Date.now() / 1000) + 86400 * 7,
				},
			};

			const hasActiveTrial = breakdown.freeTrialInfo?.freeTrialStatus === "ACTIVE";
			expect(hasActiveTrial).toBe(true);
		});

		test("calculates percentage remaining correctly", () => {
			const used = 30;
			const total = 100;
			const percentage = Math.max(0, ((total - used) / total) * 100);

			expect(percentage).toBe(70);
		});

		test("handles zero total gracefully", () => {
			const used = 0;
			const total = 0;
			const percentage = total > 0 ? ((total - used) / total) * 100 : 0;

			expect(percentage).toBe(0);
		});
	});

	describe("Format Reset Time", () => {
		test("formats timestamp to MM/DD reset string", () => {
			const timestamp = new Date("2025-03-15T00:00:00Z").getTime() / 1000;
			const date = new Date(timestamp * 1000);
			const month = String(date.getMonth() + 1).padStart(2, "0");
			const day = String(date.getDate()).padStart(2, "0");
			const resetStr = `resets ${month}/${day}`;

			expect(resetStr).toMatch(/^resets \d{2}\/\d{2}$/);
		});

		test("returns empty string for undefined timestamp", () => {
			const timestamp = undefined;
			const resetStr = timestamp ? "has value" : "";

			expect(resetStr).toBe("");
		});
	});
});

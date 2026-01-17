import type { OAuthSession, StoredAuthFile, TokenStore } from '../../store/types.js';

const AWS_SSO_OIDC_REGISTRATION_URL =
	'https://oidc.us-east-1.amazonaws.com/us-east-1/amazoncognito';
const AWS_SSO_OIDC_TOKEN_URL =
	'https://oidc.us-east-1.amazonaws.com/us-east-1/amazoncognito/oauth2/token';

interface AwsDeviceCodeResponse {
	deviceCode: string;
	userCode: string;
	verificationUri: string;
	expiresIn: number;
	interval: number;
}

interface AwsTokenResponse {
	access_token: string;
	refresh_token: string;
	expires_in: number;
	token_type: string;
	id_token?: string;
	error?: string;
	error_description?: string;
}

interface KiroAwsSession extends OAuthSession {
	clientId: string;
	clientSecret: string;
	deviceCode: string;
	userCode: string;
	verificationUri: string;
	pollInterval: number;
}

export interface KiroAwsDeviceCodeResult {
	success: boolean;
	userCode?: string;
	verificationUri?: string;
	deviceCode?: string;
	expiresIn?: number;
	interval?: number;
	error?: string;
}

export interface KiroAwsPollResult {
	status: 'pending' | 'success' | 'error' | 'expired';
	email?: string;
	error?: string;
}

function decodeJwtEmail(idToken: string | undefined): string | undefined {
	if (!idToken) return undefined;
	const parts = idToken.split('.');
	if (parts.length < 2) return undefined;
	try {
		const payload = parts[1] ?? '';
		const decoded = JSON.parse(Buffer.from(payload, 'base64').toString('utf-8')) as {
			email?: string;
		};
		return decoded.email;
	} catch {
		return undefined;
	}
}

function getSessionFields(session: OAuthSession): KiroAwsSession | null {
	const data = session as Partial<KiroAwsSession>;
	if (
		typeof data.clientId !== 'string' ||
		typeof data.clientSecret !== 'string' ||
		typeof data.deviceCode !== 'string' ||
		typeof data.userCode !== 'string' ||
		typeof data.verificationUri !== 'string'
	) {
		return null;
	}

	return {
		...session,
		clientId: data.clientId,
		clientSecret: data.clientSecret,
		deviceCode: data.deviceCode,
		userCode: data.userCode,
		verificationUri: data.verificationUri,
		pollInterval: typeof data.pollInterval === 'number' ? data.pollInterval : 5,
	};
}

export async function startKiroAwsDeviceCode(store: TokenStore): Promise<KiroAwsDeviceCodeResult> {
	try {
		const registerResponse = await fetch(AWS_SSO_OIDC_REGISTRATION_URL, {
			method: 'POST',
			headers: {
				'Content-Type': 'application/json',
				Accept: 'application/json',
			},
			body: JSON.stringify({
				clientName: 'KiroIDE',
				redirectUris: ['http://localhost:9876/callback'],
				scopes: ['openid', 'profile', 'email'],
			}),
		});

		if (!registerResponse.ok) {
			const error = await registerResponse.text();
			return {
				success: false,
				error: `AWS OIDC registration failed: ${registerResponse.status} - ${error}`,
			};
		}

		const registration = (await registerResponse.json()) as {
			clientId: string;
			clientSecret: string;
		};

		const deviceResponse = await fetch(`${AWS_SSO_OIDC_REGISTRATION_URL}/device/authorization`, {
			method: 'POST',
			headers: {
				'Content-Type': 'application/json',
				Accept: 'application/json',
			},
			body: JSON.stringify({
				clientId: registration.clientId,
				scope: 'openid profile email',
			}),
		});

		if (!deviceResponse.ok) {
			const error = await deviceResponse.text();
			return {
				success: false,
				error: `AWS device authorization failed: ${deviceResponse.status} - ${error}`,
			};
		}

		const deviceData = (await deviceResponse.json()) as AwsDeviceCodeResponse;

		const expiresAt = new Date(Date.now() + deviceData.expiresIn * 1000);
		const session: KiroAwsSession = {
			state: deviceData.deviceCode,
			codeVerifier: '',
			provider: 'kiro-aws',
			createdAt: new Date(),
			expiresAt,
			deviceCode: deviceData.deviceCode,
			userCode: deviceData.userCode,
			verificationUri: deviceData.verificationUri,
			pollInterval: deviceData.interval,
			clientId: registration.clientId,
			clientSecret: registration.clientSecret,
		};

		await store.savePendingSession(session);

		return {
			success: true,
			userCode: deviceData.userCode,
			verificationUri: deviceData.verificationUri,
			deviceCode: deviceData.deviceCode,
			expiresIn: deviceData.expiresIn,
			interval: deviceData.interval,
		};
	} catch (error) {
		return {
			success: false,
			error: error instanceof Error ? error.message : String(error),
		};
	}
}

export async function pollKiroAwsDeviceCode(
	store: TokenStore,
	deviceCode: string,
): Promise<KiroAwsPollResult> {
	const session = await store.getPendingSession(deviceCode);
	if (!session) {
		return { status: 'expired', error: 'Session not found or expired' };
	}

	if (new Date() > session.expiresAt) {
		await store.deletePendingSession(deviceCode);
		return { status: 'expired', error: 'Device code expired' };
	}

	const fields = getSessionFields(session);
	if (!fields) {
		await store.deletePendingSession(deviceCode);
		return { status: 'error', error: 'Invalid session data' };
	}

	try {
		const response = await fetch(AWS_SSO_OIDC_TOKEN_URL, {
			method: 'POST',
			headers: {
				'Content-Type': 'application/x-www-form-urlencoded',
				Accept: 'application/json',
			},
			body: new URLSearchParams({
				grant_type: 'urn:ietf:params:oauth:grant-type:device_code',
				client_id: fields.clientId,
				client_secret: fields.clientSecret,
				device_code: deviceCode,
			}),
		});

		const data = (await response.json()) as AwsTokenResponse;
		if (!response.ok) {
			if (data.error?.includes('authorization_pending')) {
				return { status: 'pending' };
			}
			if (data.error?.includes('slow_down')) {
				return { status: 'pending', error: 'Please wait before polling again' };
			}
			return {
				status: 'error',
				error: data.error_description || `AWS token error: ${response.status}`,
			};
		}

		if (!data.access_token) {
			return { status: 'pending' };
		}

		const now = new Date().toISOString();
		const expiresAt = data.expires_in
			? new Date(Date.now() + data.expires_in * 1000).toISOString()
			: undefined;
		const email = decodeJwtEmail(data.id_token) || 'aws-user';

		const authFile: StoredAuthFile = {
			id: `kiro-aws-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
			provider: 'kiro',
			email,
			name: email,
			createdAt: now,
			updatedAt: now,
			accessToken: data.access_token,
			refreshToken: data.refresh_token,
			expiresAt,
			status: 'ready',
			disabled: false,
			tokenData: {
				auth_method: 'aws',
				id_token: data.id_token,
			},
		};

		await store.saveAuthFile(authFile);
		await store.deletePendingSession(deviceCode);

		return { status: 'success', email };
	} catch (error) {
		return {
			status: 'error',
			error: error instanceof Error ? error.message : String(error),
		};
	}
}

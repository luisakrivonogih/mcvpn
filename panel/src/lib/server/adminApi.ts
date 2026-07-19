/**
 * Thin typed wrapper around the Paper plugin's embedded admin HTTP API.
 *
 * IMPORTANT: this module talks directly to `PLUGIN_API_URL` and must only ever be
 * imported from server-only code (`+page.server.ts`, `+server.ts`, `hooks.server.ts`).
 * Never import it from a `.svelte` component - it embeds the plugin API's network
 * location and would leak it (and any tokens passed through it) to the client bundle.
 *
 * The plugin side is being built in parallel, so the exact JSON shape is provisional.
 * Everything network/shape-related is centralized here so it's easy to adjust later
 * without touching route code.
 */

import { env } from '$env/dynamic/private';

const BASE_URL = env.PLUGIN_API_URL || 'http://127.0.0.1:8081';

/** Thrown for any non-2xx response from the plugin API. */
export class AdminApiError extends Error {
	/** HTTP status code returned by the plugin API (0 if the request never completed, e.g. network error). */
	status: number;

	constructor(status: number, message: string) {
		super(message);
		this.name = 'AdminApiError';
		this.status = status;
	}
}

/** True when the error represents an expired/invalid/missing session token. */
export function isUnauthorized(err: unknown): err is AdminApiError {
	return err instanceof AdminApiError && err.status === 401;
}

export interface LoginResult {
	token: string;
	expiresAt: string;
}

export interface VpnUser {
	id: string;
	keyId: string;
	label: string;
	enabled: boolean;
	online: boolean;
	createdAt: string;
	lastSeenAt: string | null;
}

/** Only returned once, from create / rotate — never persisted or shown again. */
export interface VpnUserWithSecret extends VpnUser {
	secret: string;
}

export interface Admin {
	id: string;
	username: string;
	createdAt: string;
}

async function request<T>(
	path: string,
	options: {
		method?: string;
		token?: string;
		body?: unknown;
		/** Expect an empty (204) response body. */
		expectEmpty?: boolean;
	} = {}
): Promise<T> {
	const { method = 'GET', token, body, expectEmpty = false } = options;

	const headers: Record<string, string> = {};
	if (body !== undefined) headers['Content-Type'] = 'application/json';
	if (token) headers['Authorization'] = `Bearer ${token}`;

	let response: Response;
	try {
		response = await fetch(`${BASE_URL}${path}`, {
			method,
			headers,
			body: body !== undefined ? JSON.stringify(body) : undefined
		});
	} catch (err) {
		const message = err instanceof Error ? err.message : 'unknown network error';
		throw new AdminApiError(0, `could not reach plugin API: ${message}`);
	}

	if (!response.ok) {
		let message = `plugin API returned ${response.status}`;
		try {
			const data = await response.json();
			if (data && typeof data.error === 'string') message = data.error;
		} catch {
			// body wasn't JSON (or was empty) - fall back to the generic message above
		}
		throw new AdminApiError(response.status, message);
	}

	if (expectEmpty || response.status === 204) {
		return undefined as T;
	}

	return (await response.json()) as T;
}

export function login(username: string, password: string): Promise<LoginResult> {
	return request<LoginResult>('/api/login', { method: 'POST', body: { username, password } });
}

export function logout(token: string): Promise<void> {
	return request<void>('/api/logout', { method: 'POST', token, expectEmpty: true });
}

export function listVpnUsers(token: string): Promise<VpnUser[]> {
	return request<VpnUser[]>('/api/vpn-users', { token });
}

export function createVpnUser(token: string, label: string): Promise<VpnUserWithSecret> {
	return request<VpnUserWithSecret>('/api/vpn-users', {
		method: 'POST',
		token,
		body: { label }
	});
}

export function setVpnUserEnabled(
	token: string,
	id: string,
	enabled: boolean
): Promise<VpnUser> {
	return request<VpnUser>(`/api/vpn-users/${encodeURIComponent(id)}`, {
		method: 'PATCH',
		token,
		body: { enabled }
	});
}

export function rotateVpnUserSecret(token: string, id: string): Promise<VpnUserWithSecret> {
	return request<VpnUserWithSecret>(`/api/vpn-users/${encodeURIComponent(id)}/rotate`, {
		method: 'POST',
		token
	});
}

export function deleteVpnUser(token: string, id: string): Promise<void> {
	return request<void>(`/api/vpn-users/${encodeURIComponent(id)}`, {
		method: 'DELETE',
		token,
		expectEmpty: true
	});
}

export function listAdmins(token: string): Promise<Admin[]> {
	return request<Admin[]>('/api/admins', { token });
}

export function createAdmin(token: string, username: string, password: string): Promise<Admin> {
	return request<Admin>('/api/admins', {
		method: 'POST',
		token,
		body: { username, password }
	});
}

export function getSelfAdmin(token: string): Promise<Admin> {
	return request<Admin>('/api/admins/me', { token });
}

export function changeOwnPassword(
	token: string,
	currentPassword: string,
	newPassword: string
): Promise<void> {
	return request<void>('/api/admins/me/password', {
		method: 'PATCH',
		token,
		body: { currentPassword, newPassword },
		expectEmpty: true
	});
}

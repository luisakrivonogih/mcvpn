import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { AdminApiError, listVpnUsers } from '$lib/server/adminApi';

/**
 * Lightweight JSON poll target for the VPN users page's 5s auto-refresh --
 * just the fields that actually change on their own (online, lastSeenAt),
 * not the full user list shape the page's `load` already has.
 */
export const GET: RequestHandler = async ({ locals }) => {
	if (!locals.token) {
		return json({ error: 'unauthorized' }, { status: 401 });
	}

	try {
		const users = await listVpnUsers(locals.token);
		return json(users.map(({ id, online, lastSeenAt }) => ({ id, online, lastSeenAt })));
	} catch (err) {
		const status = err instanceof AdminApiError ? err.status : 502;
		return json({ error: 'failed to load status' }, { status });
	}
};

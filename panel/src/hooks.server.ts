import type { Handle } from '@sveltejs/kit';
import { SESSION_COOKIE } from '$lib/server/session';

/**
 * This app is itself stateless — it's a thin proxy in front of the plugin's own
 * session store. We just read the plugin-issued Bearer token verbatim out of the
 * httpOnly `session` cookie and attach it to `event.locals.token` for route code
 * to use. No separate JWT/session-signing layer here.
 */
export const handle: Handle = async ({ event, resolve }) => {
	event.locals.token = event.cookies.get(SESSION_COOKIE) ?? null;
	return resolve(event);
};

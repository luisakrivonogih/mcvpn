import { redirect } from '@sveltejs/kit';
import type { LayoutServerLoad } from './$types';

/**
 * Guards every route except /login. This only checks for the *presence* of a
 * session cookie — it deliberately does not round-trip to the plugin API on every
 * request just to validate it. If the token has actually expired plugin-side,
 * the first `load`/action that calls the plugin API will get a 401 back, at which
 * point it's responsible for clearing the cookie and redirecting to /login itself.
 */
export const load: LayoutServerLoad = async ({ locals, url }) => {
	if (!locals.token && url.pathname !== '/login') {
		redirect(303, '/login');
	}

	return {
		authenticated: Boolean(locals.token)
	};
};

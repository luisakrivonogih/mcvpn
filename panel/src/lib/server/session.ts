import { redirect, type Cookies } from '@sveltejs/kit';

export const SESSION_COOKIE = 'session';

/**
 * Drops the (presumably expired/invalid) session cookie and sends the admin back
 * to the login screen. Shared by every route that talks to the plugin API, so a
 * 401 from any of them (token expired plugin-side, revoked, etc.) is handled the
 * same way everywhere instead of round-tripping to the plugin API just to check
 * cookie validity up front.
 */
export function clearSessionAndRedirectToLogin(cookies: Cookies): never {
	cookies.delete(SESSION_COOKIE, { path: '/' });
	redirect(303, '/login');
}

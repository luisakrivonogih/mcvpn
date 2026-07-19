import type { RequestHandler } from './$types';
import { logout, AdminApiError } from '$lib/server/adminApi';
import { clearSessionAndRedirectToLogin } from '$lib/server/session';

export const POST: RequestHandler = async ({ locals, cookies }) => {
	if (locals.token) {
		try {
			await logout(locals.token);
		} catch (err) {
			// Best-effort: even if the plugin API call fails (already expired, network
			// blip, etc.), we still want to drop the local cookie and send the admin
			// back to the login screen.
			if (!(err instanceof AdminApiError)) throw err;
		}
	}

	clearSessionAndRedirectToLogin(cookies);
};

import { fail, redirect } from '@sveltejs/kit';
import type { Actions, PageServerLoad } from './$types';
import { login, AdminApiError } from '$lib/server/adminApi';
import { SESSION_COOKIE } from '$lib/server/session';

export const load: PageServerLoad = async ({ locals }) => {
	// Already have a session cookie — no need to log in again. If the token has
	// actually expired plugin-side, the guarded routes will catch that on first use.
	if (locals.token) {
		redirect(303, '/');
	}
};

export const actions: Actions = {
	default: async ({ request, cookies, url }) => {
		const data = await request.formData();
		const username = String(data.get('username') ?? '').trim();
		const password = String(data.get('password') ?? '');

		if (!username || !password) {
			return fail(400, { error: 'Username and password are required.', username });
		}

		try {
			const { token, expiresAt } = await login(username, password);

			const expiresAtMs = Date.parse(expiresAt);
			const maxAge = Number.isFinite(expiresAtMs)
				? Math.max(1, Math.floor((expiresAtMs - Date.now()) / 1000))
				: undefined;

			cookies.set(SESSION_COOKIE, token, {
				path: '/',
				httpOnly: true,
				sameSite: 'lax',
				secure: url.protocol === 'https:',
				maxAge
			});
		} catch (err) {
			if (err instanceof AdminApiError) {
				return fail(err.status === 401 ? 401 : 502, {
					error: err.status === 401 ? 'Invalid username or password.' : err.message,
					username
				});
			}
			throw err;
		}

		redirect(303, '/');
	}
};

import { fail, redirect } from '@sveltejs/kit';
import type { Actions, PageServerLoad } from './$types';
import { AdminApiError, changeOwnPassword, getSelfAdmin } from '$lib/server/adminApi';
import { clearSessionAndRedirectToLogin } from '$lib/server/session';

export const load: PageServerLoad = async ({ locals, cookies }) => {
	if (!locals.token) redirect(303, '/login');

	try {
		const admin = await getSelfAdmin(locals.token);
		return { admin };
	} catch (err) {
		if (err instanceof AdminApiError && err.status === 401) {
			clearSessionAndRedirectToLogin(cookies);
		}
		throw err;
	}
};

export const actions: Actions = {
	changePassword: async ({ request, locals, cookies }) => {
		if (!locals.token) clearSessionAndRedirectToLogin(cookies);

		const data = await request.formData();
		const currentPassword = String(data.get('currentPassword') ?? '');
		const newPassword = String(data.get('newPassword') ?? '');
		const confirmPassword = String(data.get('confirmPassword') ?? '');

		if (!currentPassword || !newPassword) {
			return fail(400, { changeError: 'Both current and new password are required.' });
		}
		if (newPassword !== confirmPassword) {
			return fail(400, { changeError: 'New password and confirmation do not match.' });
		}

		try {
			await changeOwnPassword(locals.token, currentPassword, newPassword);
		} catch (err) {
			// The plugin API only returns 401 here for a wrong currentPassword --
			// an expired/invalid session token would have been rejected by its
			// auth guard before this handler ever ran, so this is never a stale
			// cookie and must not redirect to /login like other 401s do.
			if (err instanceof AdminApiError) {
				return fail(err.status, { changeError: err.message });
			}
			return fail(500, { changeError: 'Unexpected error' });
		}

		return { changed: true };
	}
};

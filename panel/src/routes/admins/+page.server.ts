import { error, fail, redirect } from '@sveltejs/kit';
import type { Actions, PageServerLoad } from './$types';
import { AdminApiError, createAdmin, listAdmins } from '$lib/server/adminApi';
import { clearSessionAndRedirectToLogin } from '$lib/server/session';

export const load: PageServerLoad = async ({ locals, cookies }) => {
	if (!locals.token) redirect(303, '/login');

	try {
		const admins = await listAdmins(locals.token);
		return { admins };
	} catch (err) {
		if (err instanceof AdminApiError && err.status === 401) {
			clearSessionAndRedirectToLogin(cookies);
		}
		const message = err instanceof AdminApiError ? err.message : 'Unexpected error';
		error(502, `Could not load admins: ${message}`);
	}
};

export const actions: Actions = {
	create: async ({ request, locals, cookies }) => {
		if (!locals.token) clearSessionAndRedirectToLogin(cookies);

		const data = await request.formData();
		const username = String(data.get('username') ?? '').trim();
		const password = String(data.get('password') ?? '');

		if (!username || !password) {
			return fail(400, { createError: 'Username and password are required.', username });
		}

		try {
			const created = await createAdmin(locals.token, username, password);
			return { created };
		} catch (err) {
			if (err instanceof AdminApiError && err.status === 401) {
				clearSessionAndRedirectToLogin(cookies);
			}
			return fail(err instanceof AdminApiError ? err.status : 500, {
				createError: err instanceof AdminApiError ? err.message : 'Unexpected error',
				username
			});
		}
	}
};

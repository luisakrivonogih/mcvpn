import { error, fail, redirect } from '@sveltejs/kit';
import type { Actions, PageServerLoad } from './$types';
import {
	AdminApiError,
	createVpnUser,
	deleteVpnUser,
	listVpnUsers,
	rotateVpnUserSecret,
	setVpnUserEnabled,
	type VpnUserWithSecret
} from '$lib/server/adminApi';
import { clearSessionAndRedirectToLogin } from '$lib/server/session';

export const load: PageServerLoad = async ({ locals, cookies }) => {
	if (!locals.token) redirect(303, '/login');

	try {
		const users = await listVpnUsers(locals.token);
		return { users };
	} catch (err) {
		if (err instanceof AdminApiError && err.status === 401) {
			clearSessionAndRedirectToLogin(cookies);
		}
		const message = err instanceof AdminApiError ? err.message : 'Unexpected error';
		error(502, `Could not load VPN users: ${message}`);
	}
};

export const actions: Actions = {
	create: async ({ request, locals, cookies }) => {
		if (!locals.token) clearSessionAndRedirectToLogin(cookies);

		const data = await request.formData();
		const label = String(data.get('label') ?? '').trim();
		if (!label) {
			return fail(400, { createError: 'Label is required.' });
		}

		let created: VpnUserWithSecret;
		try {
			created = await createVpnUser(locals.token, label);
		} catch (err) {
			if (err instanceof AdminApiError && err.status === 401) {
				clearSessionAndRedirectToLogin(cookies);
			}
			return fail(err instanceof AdminApiError ? err.status : 500, {
				createError: err instanceof AdminApiError ? err.message : 'Unexpected error'
			});
		}

		return { created };
	},

	toggle: async ({ request, locals, cookies }) => {
		if (!locals.token) clearSessionAndRedirectToLogin(cookies);

		const data = await request.formData();
		const id = String(data.get('id') ?? '');
		const enabled = data.get('enabled') === 'true';
		if (!id) return fail(400, { actionError: 'Missing user id.' });

		try {
			await setVpnUserEnabled(locals.token, id, enabled);
		} catch (err) {
			if (err instanceof AdminApiError && err.status === 401) {
				clearSessionAndRedirectToLogin(cookies);
			}
			return fail(err instanceof AdminApiError ? err.status : 500, {
				actionError: err instanceof AdminApiError ? err.message : 'Unexpected error'
			});
		}

		return { toggled: true };
	},

	rotate: async ({ request, locals, cookies }) => {
		if (!locals.token) clearSessionAndRedirectToLogin(cookies);

		const data = await request.formData();
		const id = String(data.get('id') ?? '');
		if (!id) return fail(400, { actionError: 'Missing user id.' });

		let rotated: VpnUserWithSecret;
		try {
			rotated = await rotateVpnUserSecret(locals.token, id);
		} catch (err) {
			if (err instanceof AdminApiError && err.status === 401) {
				clearSessionAndRedirectToLogin(cookies);
			}
			return fail(err instanceof AdminApiError ? err.status : 500, {
				actionError: err instanceof AdminApiError ? err.message : 'Unexpected error'
			});
		}

		return { rotated };
	},

	delete: async ({ request, locals, cookies }) => {
		if (!locals.token) clearSessionAndRedirectToLogin(cookies);

		const data = await request.formData();
		const id = String(data.get('id') ?? '');
		if (!id) return fail(400, { actionError: 'Missing user id.' });

		try {
			await deleteVpnUser(locals.token, id);
		} catch (err) {
			if (err instanceof AdminApiError && err.status === 401) {
				clearSessionAndRedirectToLogin(cookies);
			}
			return fail(err instanceof AdminApiError ? err.status : 500, {
				actionError: err instanceof AdminApiError ? err.message : 'Unexpected error'
			});
		}

		return { deleted: true };
	}
};

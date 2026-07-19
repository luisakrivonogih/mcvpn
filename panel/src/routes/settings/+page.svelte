<script lang="ts">
	import { enhance } from '$app/forms';
	import type { ActionData, PageData } from './$types';

	let { data, form }: { data: PageData; form: ActionData } = $props();

	let changing = $state(false);
</script>

<svelte:head>
	<title>Settings — mcvpn admin</title>
</svelte:head>

<div class="page-head">
	<h1>Settings</h1>
	<p class="lede">Signed in as <strong>{data.admin.username}</strong>.</p>
</div>

<section class="card password-card">
	<h2>Change password</h2>
	<form
		method="POST"
		action="?/changePassword"
		use:enhance={() => {
			changing = true;
			return async ({ update }) => {
				await update({ reset: true });
				changing = false;
			};
		}}
	>
		<label>
			Current password
			<input type="password" name="currentPassword" autocomplete="current-password" required />
		</label>
		<label>
			New password
			<input type="password" name="newPassword" autocomplete="new-password" required />
		</label>
		<label>
			Confirm new password
			<input type="password" name="confirmPassword" autocomplete="new-password" required />
		</label>
		<button type="submit" class="primary" disabled={changing}>
			{changing ? 'Changing…' : 'Change password'}
		</button>
	</form>
	{#if form && 'changeError' in form && form.changeError}
		<p class="error" role="alert">{form.changeError}</p>
	{/if}
	{#if form && 'changed' in form && form.changed}
		<p class="success" role="status">Password changed.</p>
	{/if}
</section>

<style>
	.page-head {
		margin-bottom: 1.5rem;
	}

	h1 {
		margin: 0 0 0.3rem;
	}

	.lede {
		margin: 0;
		color: var(--text-muted);
		font-size: 0.9rem;
	}

	.password-card {
		max-width: 26rem;
		padding: 1.15rem 1.25rem;
	}

	.password-card h2 {
		margin: 0 0 0.85rem;
		font-size: 0.92rem;
	}

	.password-card form {
		display: flex;
		flex-direction: column;
		gap: 0.85rem;
		align-items: stretch;
	}

	.password-card label {
		display: flex;
		flex-direction: column;
		gap: 0.35rem;
		font-size: 0.82rem;
		font-weight: 500;
		color: var(--text-muted);
	}

	.password-card button {
		align-self: flex-start;
	}

	.error {
		color: var(--danger-text);
		background: var(--danger-bg);
		padding: 0.55rem 0.75rem;
		border-radius: var(--radius-sm);
		font-size: 0.85rem;
		margin-top: 0.85rem;
	}

	.success {
		color: var(--success-text);
		background: var(--success-bg);
		padding: 0.55rem 0.75rem;
		border-radius: var(--radius-sm);
		font-size: 0.85rem;
		margin-top: 0.85rem;
	}
</style>

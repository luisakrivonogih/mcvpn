<script lang="ts">
	import { enhance } from '$app/forms';
	import type { ActionData, PageData } from './$types';

	let { data, form }: { data: PageData; form: ActionData } = $props();

	let creating = $state(false);

	function formatDate(value: string) {
		const d = new Date(value);
		return Number.isNaN(d.getTime()) ? value : d.toLocaleString();
	}
</script>

<svelte:head>
	<title>Admins — mcvpn admin</title>
</svelte:head>

<div class="page-head">
	<h1>Admins</h1>
	<p class="lede">Accounts that can sign in to this panel.</p>
</div>

<section class="create-admin card">
	<h2>Add admin</h2>
	<form
		method="POST"
		action="?/create"
		use:enhance={() => {
			creating = true;
			return async ({ update }) => {
				await update();
				creating = false;
			};
		}}
	>
		<label>
			Username
			<input
				type="text"
				name="username"
				value={form && 'username' in form ? (form.username ?? '') : ''}
				autocomplete="off"
				required
			/>
		</label>
		<label>
			Password
			<input type="password" name="password" autocomplete="new-password" required />
		</label>
		<button type="submit" class="primary" disabled={creating}>
			{#if !creating}
				<svg viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg">
					<path d="M8 3.5v9M3.5 8h9" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" />
				</svg>
			{/if}
			{creating ? 'Creating…' : 'Create admin'}
		</button>
	</form>
	{#if form && 'createError' in form && form.createError}
		<p class="error" role="alert">{form.createError}</p>
	{/if}
	{#if form && 'created' in form && form.created}
		<p class="success" role="status">Admin "{form.created.username}" created.</p>
	{/if}
</section>

<section class="admins-table">
	{#if data.admins.length === 0}
		<p class="empty">No admins yet.</p>
	{:else}
		<div class="table-scroll">
			<table>
				<thead>
					<tr>
						<th>Username</th>
						<th>Created</th>
					</tr>
				</thead>
				<tbody>
					{#each data.admins as admin (admin.id)}
						<tr>
							<td>{admin.username}</td>
							<td>{formatDate(admin.createdAt)}</td>
						</tr>
					{/each}
				</tbody>
			</table>
		</div>
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

	.create-admin {
		margin: 0 0 2rem;
		padding: 1.15rem 1.25rem;
	}

	.create-admin h2 {
		margin: 0 0 0.85rem;
		font-size: 0.92rem;
	}

	.create-admin form {
		display: flex;
		align-items: flex-end;
		gap: 0.75rem;
		flex-wrap: wrap;
	}

	.create-admin label {
		display: flex;
		flex-direction: column;
		gap: 0.35rem;
		font-size: 0.82rem;
		font-weight: 500;
		color: var(--text-muted);
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

	.empty {
		color: var(--text-muted);
	}
</style>

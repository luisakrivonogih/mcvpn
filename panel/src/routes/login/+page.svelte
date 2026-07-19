<script lang="ts">
	import { enhance } from '$app/forms';
	import type { ActionData } from './$types';

	let { form }: { form: ActionData } = $props();

	let submitting = $state(false);
</script>

<svelte:head>
	<title>Log in — mcvpn admin</title>
</svelte:head>

<div class="login-screen">
	<div class="login-glow" aria-hidden="true"></div>

	<div class="login-stack">
		<div class="wordmark">
			<span class="mark" aria-hidden="true">
				<svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
					<path
						d="M12 2.5 20.5 7v10L12 21.5 3.5 17V7L12 2.5Z"
						stroke="currentColor"
						stroke-width="1.6"
						stroke-linejoin="round"
					/>
					<path
						d="M8 11.2 12 13.4l4-2.2M12 13.4v4.6"
						stroke="currentColor"
						stroke-width="1.6"
						stroke-linecap="round"
						stroke-linejoin="round"
					/>
				</svg>
			</span>
			<span class="wordmark-text">mcvpn <span>admin</span></span>
		</div>

		<form
			class="login-card"
			method="POST"
			use:enhance={() => {
				submitting = true;
				return async ({ update }) => {
					await update();
					submitting = false;
				};
			}}
		>
			<div class="card-heading">
				<h1>Sign in</h1>
				<p class="subtitle">Enter your credentials to manage the tunnel.</p>
			</div>

			{#if form?.error}
				<p class="error" role="alert">{form.error}</p>
			{/if}

			<label>
				Username
				<input
					type="text"
					name="username"
					value={form?.username ?? ''}
					autocomplete="username"
					required
				/>
			</label>

			<label>
				Password
				<input type="password" name="password" autocomplete="current-password" required />
			</label>

			<button type="submit" class="primary" disabled={submitting}>
				{submitting ? 'Signing in…' : 'Sign in'}
			</button>
		</form>
	</div>
</div>

<style>
	.login-screen {
		position: relative;
		min-height: 100vh;
		display: flex;
		align-items: center;
		justify-content: center;
		padding: 1.5rem;
		overflow: hidden;
		background: var(--bg);
	}

	.login-glow {
		position: absolute;
		inset: 0;
		background:
			radial-gradient(
				60rem 32rem at 50% -10%,
				color-mix(in srgb, var(--accent) 16%, transparent),
				transparent 60%
			),
			radial-gradient(
				40rem 24rem at 100% 100%,
				color-mix(in srgb, var(--accent) 8%, transparent),
				transparent 55%
			);
		pointer-events: none;
	}

	.login-stack {
		position: relative;
		width: 100%;
		max-width: 23rem;
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 1.75rem;
	}

	.wordmark {
		display: flex;
		align-items: center;
		gap: 0.6rem;
	}

	.mark {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 40px;
		height: 40px;
		border-radius: 11px;
		background: var(--accent-soft);
		color: var(--accent);
		box-shadow: var(--shadow-sm);
	}

	.mark svg {
		width: 23px;
		height: 23px;
	}

	.wordmark-text {
		font-size: 1.15rem;
		font-weight: 650;
		letter-spacing: -0.015em;
		color: var(--text);
	}

	.wordmark-text span {
		color: var(--text-muted);
		font-weight: 500;
	}

	.login-card {
		width: 100%;
		display: flex;
		flex-direction: column;
		gap: 1.1rem;
		padding: 2rem;
		border: 1px solid var(--border);
		border-radius: var(--radius-lg);
		background: var(--surface);
		box-shadow: var(--shadow-lg);
	}

	.card-heading {
		margin-bottom: 0.1rem;
	}

	h1 {
		margin: 0 0 0.3rem;
		font-size: 1.25rem;
	}

	.subtitle {
		margin: 0;
		font-size: 0.85rem;
		color: var(--text-muted);
	}

	label {
		display: flex;
		flex-direction: column;
		gap: 0.35rem;
		font-size: 0.82rem;
		font-weight: 500;
		color: var(--text-muted);
	}

	input {
		font-size: 0.95rem;
	}

	.error {
		margin: 0;
		padding: 0.55rem 0.75rem;
		border-radius: var(--radius-sm);
		background: var(--danger-bg);
		color: var(--danger-text);
		font-size: 0.85rem;
	}

	button {
		margin-top: 0.3rem;
		justify-content: center;
		padding: 0.6rem 0.9rem;
		font-size: 0.9rem;
	}
</style>

<script lang="ts">
	import '../app.css';
	import favicon from '$lib/assets/favicon.svg';
	import { page } from '$app/state';
	import type { LayoutProps } from './$types';

	let { children, data }: LayoutProps = $props();

	let isLoginPage = $derived(page.url.pathname === '/login');
</script>

<svelte:head>
	<link rel="icon" href={favicon} />
</svelte:head>

{#if data.authenticated && !isLoginPage}
	<div class="app-shell">
		<header class="topnav">
			<div class="brand">
				<span class="brand-mark" aria-hidden="true">
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
				<span class="brand-word">mcvpn <span class="brand-sub">admin</span></span>
			</div>
			<nav>
				<a href="/" aria-current={page.url.pathname === '/' ? 'page' : undefined}>Users</a>
				<a
					href="/admins"
					aria-current={page.url.pathname === '/admins' ? 'page' : undefined}>Admins</a
				>
				<a
					href="/settings"
					aria-current={page.url.pathname === '/settings' ? 'page' : undefined}>Settings</a
				>
			</nav>
			<form method="POST" action="/logout">
				<button type="submit" class="ghost">
					<svg viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg">
						<path
							d="M6 14H3.5A1.5 1.5 0 0 1 2 12.5v-9A1.5 1.5 0 0 1 3.5 2H6M10.5 11.5 14 8l-3.5-3.5M14 8H6"
							stroke="currentColor"
							stroke-width="1.4"
							stroke-linecap="round"
							stroke-linejoin="round"
						/>
					</svg>
					Log out
				</button>
			</form>
		</header>
		<main>
			{@render children()}
		</main>
	</div>
{:else}
	{@render children()}
{/if}

<style>
	.app-shell {
		min-height: 100vh;
		display: flex;
		flex-direction: column;
	}

	.topnav {
		display: flex;
		align-items: center;
		gap: 1.75rem;
		padding: 0.85rem 1.5rem;
		border-bottom: 1px solid var(--border);
		background: color-mix(in srgb, var(--surface) 92%, transparent);
		backdrop-filter: blur(8px);
		position: sticky;
		top: 0;
		z-index: 10;
	}

	.brand {
		display: flex;
		align-items: center;
		gap: 0.55rem;
	}

	.brand-mark {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 28px;
		height: 28px;
		border-radius: 8px;
		background: var(--accent-soft);
		color: var(--accent);
	}

	.brand-mark svg {
		width: 17px;
		height: 17px;
	}

	.brand-word {
		font-weight: 650;
		font-size: 0.95rem;
		letter-spacing: -0.01em;
		color: var(--text);
	}

	.brand-sub {
		color: var(--text-muted);
		font-weight: 500;
	}

	nav {
		display: flex;
		gap: 1.25rem;
		flex: 1;
	}

	nav a {
		color: var(--text-muted);
		text-decoration: none;
		font-size: 0.87rem;
		font-weight: 500;
		padding: 0.3rem 0;
		border-bottom: 2px solid transparent;
		transition:
			color 0.15s ease,
			border-color 0.15s ease;
	}

	nav a:hover {
		color: var(--text);
		text-decoration: none;
	}

	nav a[aria-current='page'] {
		color: var(--text);
		border-bottom-color: var(--accent);
	}

	main {
		flex: 1;
		width: 100%;
		max-width: 64rem;
		margin: 0 auto;
		padding: 2rem 1.5rem 3.5rem;
	}
</style>

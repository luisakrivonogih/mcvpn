import adapter from '@sveltejs/adapter-node';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

export default defineConfig({
	plugins: [
		sveltekit({
			compilerOptions: {
				// Force runes mode for the project, except for libraries. Can be removed in svelte 6.
				runes: ({ filename }) =>
					filename.split(/[/\\]/).includes('node_modules') ? undefined : true
			},

			// adapter-node: this app needs a real persistent Node server (holds a session
			// cookie and does server-to-server fetches to the plugin's admin API), so a
			// static/edge adapter would not work here.
			adapter: adapter()
		})
	]
});

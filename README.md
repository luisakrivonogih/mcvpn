# mcvpn

An application-level encrypted TCP tunnel carried over a real Minecraft protocol session.

mcvpn is **not** a TUN/TAP VPN. It doesn't touch routing tables, doesn't need root/admin, and doesn't create a virtual network interface. It's a multiplexed, encrypted tunnel that happens to move its bytes by actually speaking the Minecraft protocol — a real Handshake, a real (offline-mode) Login, a real Play state, a real plugin channel — against a real Paper server. It's designed so that, to anything watching the network, it looks like someone playing Minecraft, because it *is* a real Minecraft session underneath.

## Features

- No TUN/TAP, no root/admin required — it's a userspace proxy, not a virtual network interface
- HTTP CONNECT **and** SOCKS5 front ends, so it carries any TCP traffic, not just HTTP(S)
- Multiplexed streams over a single Minecraft connection, with per-stream flow control
- Wire traffic is a real Minecraft 1.20.1 handshake/login/play session, not a lookalike protocol
- Forward-secret handshake (X25519 + HKDF-SHA256) and ChaCha20-Poly1305 per-frame encryption, with periodic session-key rotation
- Per-user credentials (not one shared passphrase), on a pluggable store: memory, Postgres, MariaDB, or MongoDB
- Web admin panel: manage users/credentials, live online status, one-click client config download

```
    app
     │
     ▼
HTTP CONNECT / SOCKS5  (proxy_listen / socks_listen)
     │
     ▼
  mcvpn client (Rust)
     │
     ▼
Minecraft protocol, port 25565
     │
     ▼
Paper server + mcvpn plugin
     │
     ▼
  target TCP service
```

## Why

Traffic that looks like an encrypted VPN protocol is an easy pattern to flag. Traffic that looks like a video game is not. mcvpn pushes an ordinary multiplexed, authenticated, encrypted tunnel through a transport that is, byte for byte, a legitimate Minecraft connection — handshake, login, keep-alives, plugin channel registration and all.

### How this compares

|  | mcvpn | Plain VPN (WireGuard, OpenVPN) | Generic obfuscated tunnel (Shadowsocks, V2Ray) |
|---|---|---|---|
| Wire format | A real Minecraft session | Its own recognizable protocol | Encrypted, protocol-agnostic-looking traffic |
| Looks like a specific, everyday app | Yes — a game client | No | No — looks like "something encrypted," not like a specific app |
| Requires TUN/TAP or root | No | Usually yes | No |
| Proxy interface | HTTP CONNECT + SOCKS5 | N/A (routes at the OS network layer) | Usually SOCKS5 |

Plain VPN protocols aren't trying to disguise *what* they are — they're built for performance and correctness, and rely on being permitted or on separate obfuscation layers when they're not. Generic obfuscators hide content but still tend to produce traffic that just looks like "something encrypted," which is itself a pattern some inspection can key on. mcvpn's bet is narrower and different: instead of looking like nothing in particular, look like a specific, extremely common, ordinary consumer application.

## How it's built

Four pieces, one repo:

| Directory | What | Stack |
|---|---|---|
| [`client/`](client/) | The tunnel client: HTTP CONNECT + SOCKS5 proxies in front, real Minecraft client behind | Rust, Tokio, `valence_protocol` |
| [`plugin/`](plugin/) | Server-side Paper plugin: authenticates, decrypts, demultiplexes to real TCP targets | Java 17+, Paper API 1.20.1 |
| [`panel/`](panel/) | Admin web UI for managing users/credentials against the plugin's HTTP API | SvelteKit 2, Svelte 5, TypeScript |
| `server/` | *(gitignored, not shipped)* a local Paper server used for manual end-to-end testing during development | — |

### Client (`client/`)

Drives the actual Minecraft session and exposes local HTTP CONNECT + SOCKS5 proxies:

- `mc/` — Handshake → Login → (no-op Configuration stub, since protocol 763/1.20.1 predates that state) → Play, then registers the tunnel's plugin channel like a real modded client would (`mc/session.rs`, `mc/play.rs`).
- `net/` — pure wire framing: a `tokio_util` `Decoder`/`Encoder` wrapping `valence_protocol`'s packet (de)serialization, compression-aware, with zero game-state knowledge (`net/codec.rs`).
- `crypto/cipher.rs` — the security core (see [Security design](#security-design) below).
- `tunnel/` — the multiplexer: frames streams over the one Minecraft connection with per-stream flow control and jittered session-key rotation.
- `proxy/http.rs` and `proxy/socks5.rs` — two local front doors onto the same tunnel, run concurrently: an HTTP CONNECT proxy and a no-auth SOCKS5 proxy (RFC 1928, `CONNECT` command only). Neither knows why any of this exists; both just ask the multiplexer for a stream to `host:port` and relay bytes (shared `proxy::relay`). HTTP CONNECT covers proxy-aware apps configured with an HTTP(S) proxy; SOCKS5 covers everything else (torrent clients, chat apps, `curl --socks5`, anything that doesn't speak HTTP at all) — between the two, the tunnel carries **any TCP traffic**, not just HTTP(S).

Only supports offline-mode servers by design (`mc/login.rs` fails loudly if the server asks for online-mode encryption) — the plugin does its own, separate application-layer encryption regardless (see below), so Mojang session auth buys nothing here and was skipped to keep the client simple.

**Run it:**

```sh
cd client
cp config.example.toml config.toml
# fill in server_host/server_port and the key_id/key_secret issued below
cargo run --release -- config.toml
```

Point any HTTP(S)-proxy-aware application at `proxy_listen` (default `127.0.0.1:8080`), or anything that speaks SOCKS5 at `socks_listen` (default `127.0.0.1:1080`) — use whichever matches what the app you're tunneling actually supports.

### Plugin (`plugin/`)

Drop the built jar into your Paper 1.20.1 server's `plugins/` folder. On first boot it:

- Registers the tunnel's plugin channel (`channel:` in `config.yml`, default `mcvpn:tunnel`).
- Bootstraps a default `admin`/`admin` account if no admin exists yet, and keeps warning loudly on every restart until that account is renamed or deleted.
- Starts an admin HTTP API (default `127.0.0.1:8081`) for the panel, and registers `/mcvpn` for **console-only** use without needing the panel at all — no player, not even an op, can see or run it (it's invisible in tab-completion and `/help`, and the command rejects any non-console sender outright, mimicking vanilla's "unknown command" instead of a permission-denied message that would itself reveal it exists):

```
/mcvpn admin create <username> <password>
/mcvpn admin list
/mcvpn user create <label>      # prints key_id + secret ONCE
/mcvpn user list
/mcvpn user revoke <keyId>
```

Per-user credentials (not one shared passphrase) are stored via a pluggable backend — `memory` (zero-config, non-persistent, the default), `postgres`, `mariadb`, or `mongodb` — selected under `database:` in `config.yml`. All three real-database backends have been run and verified end-to-end against live instances (every `UserStore` method, including reconnecting against an already-initialized schema).

The admin HTTP API also exposes, per vpn user, whether they currently have an authenticated tunnel connection open (`online`) alongside `lastSeenAt` — the panel polls this every 5 seconds so the users table stays live. Admins can change their own password from the panel's Settings page (current-password-verified, PBKDF2-hashed like every other stored password here).

Build: `cd plugin && mvn package` → `target/mcvpn-plugin-0.1.0.jar`.

### Admin panel (`panel/`)

A SvelteKit front end for the plugin's admin API: log in, create/rotate/revoke per-user tunnel credentials, manage admin accounts, change your own password. It's a thin, stateless proxy — the panel itself holds no session store or database, just an httpOnly cookie carrying the token the plugin issued.

Right after creating or rotating a user's secret (the only moments the plaintext secret is ever available at all), a **Download config.toml** button generates and downloads a ready-to-use client config file client-side — filled in with that user's `key_id`/`key_secret` and the server address from `PUBLIC_MC_HOST`/`PUBLIC_MC_PORT` (see `.env.example`; this is the client-facing Minecraft address, separate from `PLUGIN_API_URL`, which is the private admin API).

```sh
cd panel
cp .env.example .env   # set PLUGIN_API_URL to the plugin's admin API
npm install
npm run dev            # or: npm run build && node build
```

Needs at least one admin account to exist first — use the plugin's default `admin`/`admin` (then change it immediately) or `/mcvpn admin create`.

## Security design

Every connection does an authenticated X25519 handshake before anything else is trusted:

```
client → plugin:  connection_id(16B) || key_id(16B) || epk_c(32B) || mac1(32B)
plugin → client:  epk_s(32B) || mac2(32B)
```

- `mac1`/`mac2` are `HMAC-SHA256` keyed by the secret belonging to `key_id` — a party that doesn't know the secret can't forge either leg, and a wrong/unknown `key_id` or a bad MAC gets **no reply at all**. Not an error, not a kick — silence, identical to how a real Paper server behaves toward an unrecognized plugin channel. The client's only signal that a handshake failed is a timeout.
- Session keys are derived with HKDF-SHA256 from the X25519 DH output *mixed with the long-term secret*, so a flaw in the MAC alone still wouldn't let an attacker derive session keys.
- Ephemeral X25519 keys are generated fresh per connection and never reused — forward secrecy: leaking the long-term secret later doesn't decrypt anything captured earlier.
- Every frame is sealed with ChaCha20-Poly1305 under a strictly increasing per-direction counter, which doubles as replay protection.
- Session keys rotate on their own every ~510–690 seconds (jittered on purpose, so the rotation cadence isn't itself a fingerprintable timing signal), authenticated implicitly by being sealed under the current session key.
- MAC comparisons are constant-time, to avoid turning "is this MAC almost right" into a timing oracle.

### Stealth behavior

This is designed to resist casual and automated inspection, not to guarantee anonymity against a determined, targeted analyst — the design goal is "closely resembles ordinary Minecraft traffic to anything watching the wire," not an unfalsifiable claim that no observable difference exists anywhere.

A connection that never completes the handshake — wrong key, no key, or just a stray TCP client poking the port — is designed to look like a completely ordinary Minecraft login. It joins, it's a normal player, and the server's behavior aims to give no sign the plugin is even installed: no kick, no error packet, no log line visible to the network.

A connection that *does* authenticate gets hidden the instant the handshake completes — switched to spectator mode and removed from every other online player's tab list and view distance (and vice versa — real players don't see it either), whether or not it's already sent any real traffic yet. Authenticating at all is proof enough it's not a real player; it never gets a chance to sit visible in anyone's tab list first.

This also covers the unauthenticated `ServerListPing` (the MOTD/player-sample query any Minecraft client sends before joining, no connection required) — active tunnel connections are stripped out of both the player-count and the name sample, so an outside observer who just pings the server sees a normal-looking player count and name sample, with no tunnel account in it.

`/list` is overridden the same way (Bukkit lets a plugin's `plugin.yml` command take over a vanilla command by name) to exclude active tunnel connections too — identically whether it's run by a player or from console, since there's no separate "real" answer being hidden from one but not the other.

**Known gap:** any *other* plugin that reads `Bukkit.getOnlinePlayers()` directly (dynmap-style web maps, other management/monitoring plugins) still sees tunnel connections — there's no general way to filter that without patching the server's actual online-player list at the NMS level, which would be fragile across Paper versions and risks breaking real game mechanics that correctly depend on an accurate player list. If you run plugins like that alongside mcvpn, treat them as another thing (like the operator/console) that can see tunnel connections exist.

## Status

Working end-to-end against a real local Paper 1.20.1 (offline-mode) server: connect, authenticated handshake, multiplexed streams over both HTTP CONNECT and SOCKS5, per-user credentials via all four store backends (the three real-database ones verified against live Postgres/MariaDB/MongoDB instances, not just read), admin API + panel including password change and live status. Not yet done:

- No live reconnect — if the underlying Minecraft connection drops, open streams die and the client needs a restart.
- Client only targets protocol 763 (Minecraft 1.20.1); `valence_protocol` 0.2.0-alpha.1 doesn't yet support the Configuration state newer versions require, so bumping past 1.20.1 is blocked upstream, not by design here.
- Client only supports offline-mode servers (see above).

## Disclaimer

This is a network-obfuscation research/engineering project, built and documented the same way tools like Shadowsocks or v2ray are: openly, with the crypto and protocol design laid out above for anyone to audit. Running it against infrastructure you don't own or control, or in violation of a network's or game server's terms of service, is on you — use it only where you have the right to.

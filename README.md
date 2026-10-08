# mcvpn

An application-level encrypted TCP tunnel carried over a real Minecraft protocol session.

At its core, mcvpn is **not** a TUN/TAP VPN. The tunnel itself doesn't touch routing tables, doesn't need root/admin, and doesn't create a virtual network interface — it's a multiplexed, encrypted tunnel that happens to move its bytes by actually speaking the Minecraft protocol — a real Handshake, a real (offline-mode) Login, a real Play state, a real plugin channel — against a real Paper server. It's designed so that, to anything watching the network, it looks like someone playing Minecraft, because it *is* a real Minecraft session underneath. The GUI app (below) adds an optional whole-device TUN mode on top of that same tunnel, for platforms/users that want every app's traffic covered instead of configuring each app's proxy setting individually.

## Features

- No TUN/TAP, no root/admin required for the core tunnel — it's a userspace proxy, not a virtual network interface
- HTTP CONNECT **and** SOCKS5 front ends, so it carries any TCP traffic, not just HTTP(S)
- SOCKS5 UDP ASSOCIATE support, so the tunnel also carries UDP (DNS, QUIC, games), not just TCP
- Multiplexed streams over a single Minecraft connection, with per-stream flow control
- Wire traffic is a real Minecraft 1.20.1 handshake/login/play session, not a lookalike protocol
- Idle camouflage traffic (client settings, teleport acks, jittered look/swing/sneak) so the session doesn't sit silent between real requests
- Auto-reconnect with exponential backoff for the life of the process, not just on startup
- Forward-secret handshake (X25519 + HKDF-SHA256) and ChaCha20-Poly1305 per-frame encryption, with periodic session-key rotation
- Per-user credentials (not one shared passphrase), on a pluggable store: memory, Postgres, MariaDB, or MongoDB
- Web admin panel: manage users/credentials, live online status, one-click client config download
- Cross-platform GUI app (Android, iOS, macOS, Windows, Linux), with an optional whole-device TUN mode on Android/Windows/Linux alongside the scriptable Rust CLI

```
    app
     │
     ▼
HTTP CONNECT / SOCKS5  (proxy_listen / socks_listen)
     │
     ▼
  mcvpn client (Rust, or the app's built-in Dart client)
     │
     ▼
Minecraft protocol, port 25565
     │
     ▼
Paper server + mcvpn plugin
     │
     ▼
  target TCP/UDP service
```

In whole-device mode, the app puts its own TUN interface (via `tun-engine` on Windows/Linux, `VpnService` + JNI `tun2socks` on Android) in front of that same HTTP CONNECT/SOCKS5 step, so every app's traffic is captured, not just apps configured to use the proxy.

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

Six pieces, one repo:

| Directory | What | Stack |
|---|---|---|
| [`client/`](client/) | The tunnel client: HTTP CONNECT + SOCKS5 proxies in front, real Minecraft client behind | Rust, Tokio, `valence_protocol` |
| [`app/`](app/) | Cross-platform GUI client: same tunnel protocol, plus proxy-mode and whole-device TUN mode, server profile management, live stats | Flutter/Dart |
| [`tun-engine/`](tun-engine/) | Whole-device TUN helper the app drives on Windows/Linux (and, as a JNI build, Android) | Go, wraps `tun2socks` |
| [`plugin/`](plugin/) | Server-side Paper plugin: authenticates, decrypts, demultiplexes to real TCP/UDP targets | Java 17+, Paper API 1.20.1 |
| [`panel/`](panel/) | Admin web UI for managing users/credentials against the plugin's HTTP API | SvelteKit 2, Svelte 5, TypeScript |
| `server/` | *(gitignored, not shipped)* a local Paper server used for manual end-to-end testing during development | — |

### Client (`client/`)

Drives the actual Minecraft session and exposes local HTTP CONNECT + SOCKS5 proxies:

- `mc/` — Handshake → Login → (no-op Configuration stub, since protocol 763/1.20.1 predates that state) → Play, then registers the tunnel's plugin channel like a real modded client would (`mc/session.rs`, `mc/play.rs`). Once in Play, it also keeps sending the small amount of traffic a real client sends even when the player is doing nothing — client settings, teleport acks, jittered idle look/swing/sneak (`mc/camouflage.rs`) — and reconnects with exponential backoff for the life of the process if the connection ever drops.
- `net/` — pure wire framing: a `tokio_util` `Decoder`/`Encoder` wrapping `valence_protocol`'s packet (de)serialization, compression-aware, with zero game-state knowledge (`net/codec.rs`).
- `crypto/cipher.rs` — the security core (see [Security design](#security-design) below).
- `tunnel/` — the multiplexer: frames streams over the one Minecraft connection with per-stream flow control and jittered session-key rotation.
- `proxy/http.rs` and `proxy/socks5.rs` — two local front doors onto the same tunnel, run concurrently: an HTTP CONNECT proxy and a no-auth SOCKS5 proxy (RFC 1928, `CONNECT` command only). Neither knows why any of this exists; both just ask the multiplexer for a stream to `host:port` and relay bytes (shared `proxy::relay`). HTTP CONNECT covers proxy-aware apps configured with an HTTP(S) proxy; SOCKS5 covers everything else (torrent clients, chat apps, `curl --socks5`, anything that doesn't speak HTTP at all) — between the two, the tunnel carries **any TCP traffic**, not just HTTP(S).
- `proxy/udp_forward.rs` — optional static UDP forwards (`[[udp_forward]]` in the config): datagrams sent to a local `listen` address reach a fixed `target` through a plugin-side UDP association (`OPEN_UDP`/`DATAGRAM` frames, `tunnel/udp.rs`), and replies come back to the sender. Point a WireGuard peer's `Endpoint` at it and the WireGuard interface carries **any IP traffic** (TCP, UDP, ICMP) inside the Minecraft connection.

Only supports offline-mode servers by design (`mc/login.rs` fails loudly if the server asks for online-mode encryption) — the plugin does its own, separate application-layer encryption regardless (see below), so Mojang session auth buys nothing here and was skipped to keep the client simple.

**Run it:**

```sh
cd client
cp config.example.toml config.toml
# fill in server_host/server_port and the key_id/key_secret issued below
cargo run --release -- config.toml
```

Point any HTTP(S)-proxy-aware application at `proxy_listen` (default `127.0.0.1:8080`), or anything that speaks SOCKS5 at `socks_listen` (default `127.0.0.1:1080`) — use whichever matches what the app you're tunneling actually supports.

### App (`app/`)

The GUI client: a Dart reimplementation of the same handshake/multiplexer/proxy stack as `client/` (`lib/src/core`, `lib/src/crypto`, `lib/src/tunnel`, `lib/src/proxy`), so it doesn't shell out to the Rust binary — plus server-profile management, live connection stats, and two connection modes selectable per profile:

- **Proxy mode** — runs the local HTTP CONNECT/SOCKS5 proxies, same as `client/`; other apps still need to be pointed at them individually.
- **Full tunnel (whole-device TUN) mode** — captures all of the device's traffic and routes it through the tunnel automatically, no per-app configuration:
  - **Android**: `McVpnService.kt` (`VpnService`) hands captured packets to a `tun2socks` engine loaded as a JNI `.so` (`Tun2Socks.kt`), built from `tun-engine/android`.
  - **Windows/Linux**: `lib/src/vpn/desktop_tun.dart` spawns `tun-engine` as an elevated child process (UAC on Windows, `pkexec` on Linux) and talks to it over a status/stop file pair, since an elevated child on Windows loses inherited stdio.
  - **iOS/macOS**: not implemented — needs a `NetworkExtension` system extension, which needs a paid Apple Developer Program account. Those two platforms get proxy mode only for now; `lib/src/vpn/system_proxy.dart` covers the common case there (and is also offered on Windows/Linux as a lighter-weight alternative to full tunnel mode) by pointing the OS's system-wide proxy settings at the app's local proxies.

**Run it:**

```sh
cd app
flutter pub get
flutter run
```

Building distributable packages (desktop installers, the Android APK, with `tun-engine`/JNI libs bundled) goes through `scripts/build.sh` — see `--help` output (or just run it with no arguments for an interactive menu) — or via CI (below) for platforms that can't be cross-compiled locally.

### tun-engine (`tun-engine/`)

The whole-device TUN helper `app/` drives on Windows and Linux desktop (see [`tun-engine/README.md`](tun-engine/README.md) for the full picture). Wraps [xjasonlyu/tun2socks](https://github.com/xjasonlyu/tun2socks) (gVisor netstack, no reimplemented TCP/IP) to turn a TUN interface into a client of the app's local SOCKS5 proxy, and drives OS routing so the whole device goes through the tunnel except the Minecraft connection carrying it. Pure Go, no cgo, so it cross-compiles for every desktop target from any host. The Android build of the same tun2socks core is compiled separately, as a `gomobile bind` JNI library (`tun-engine/android`), rather than spawned as a subprocess.

**This has only been cross-compiled and `go vet`-checked, not run on real Windows/Linux hardware yet** — see the caveat in `tun-engine/README.md` before relying on it.

### CI (`.github/workflows/release.yml`)

Builds every packaged artifact on a tag push (`v*`) or manual dispatch: macOS `.dmg` (universal), Windows `.exe`/`.msi`, Linux `.deb`/`.rpm`, Android `.apk` — across a runner matrix, because Flutter refuses to cross-compile desktop targets (confirmed, not assumed: `flutter build windows`/`flutter build linux` both refuse outright on a non-matching host). `tun-engine` is built once on Linux and handed to both the Windows and Linux jobs.

### Plugin (`plugin/`)

Drop the built jar into your Paper 1.20.1 server's `plugins/` folder. On first boot it:

- Registers the tunnel's plugin channel (`channel:` in `config.yml`, default `mcvpn:tunnel`).
- Demultiplexes both TCP streams and UDP associations per player (`PlayerMultiplex`, `StreamState`/`UdpAssociationState`): an `OPEN_UDP` frame opens an association with one shared `DatagramSocket`, and each `DATAGRAM` frame carries its own destination `host:port`, mirroring how SOCKS5's UDP ASSOCIATE lets one relay port talk to many destinations — this is what lets the app's whole-device TUN mode carry UDP (DNS, QUIC, games), not just TCP.
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

Because this transport is offline-mode and thus fully unencrypted at the Minecraft protocol layer, an authenticated connection's own packet stream is itself something an observer could fingerprint — a session that only ever sends keep-alives and tunnel-channel payloads, and nothing else a real client sends, is a tell of its own. So once in Play the client also behaves like a real client sitting idle: it sends `ClientSettings` on join and acks the server's spawn teleport with `TeleportConfirm` (both things every real client does immediately, whose total absence would be conspicuous), plus a jittered idle tick every 2–6 seconds — look/pitch wobble, occasional arm swings, rare sneak toggles. Deliberately no chat and no simulated walking: this client has no terrain data, so faking position risks tripping vanilla's own speed/distance checks; and since authenticated connections are already hidden from every real player (see below), the only audience for this traffic is network/protocol-level, which look/swing/sneak already satisfy without that risk.

This also covers the unauthenticated `ServerListPing` (the MOTD/player-sample query any Minecraft client sends before joining, no connection required) — active tunnel connections are stripped out of both the player-count and the name sample, so an outside observer who just pings the server sees a normal-looking player count and name sample, with no tunnel account in it.

`/list` is overridden the same way (Bukkit lets a plugin's `plugin.yml` command take over a vanilla command by name) to exclude active tunnel connections too — identically whether it's run by a player or from console, since there's no separate "real" answer being hidden from one but not the other.

**Known gap:** any *other* plugin that reads `Bukkit.getOnlinePlayers()` directly (dynmap-style web maps, other management/monitoring plugins) still sees tunnel connections — there's no general way to filter that without patching the server's actual online-player list at the NMS level, which would be fragile across Paper versions and risks breaking real game mechanics that correctly depend on an accurate player list. If you run plugins like that alongside mcvpn, treat them as another thing (like the operator/console) that can see tunnel connections exist.

## Status

Working end-to-end against a real local Paper 1.20.1 (offline-mode) server: connect, authenticated handshake, multiplexed streams over both HTTP CONNECT and SOCKS5, per-user credentials via all four store backends (the three real-database ones verified against live Postgres/MariaDB/MongoDB instances, not just read), admin API + panel including password change and live status, idle camouflage traffic, and auto-reconnect with backoff (verified via a forced kill and a console `/kick`, including relaying real traffic again post-reconnect). Not yet done:

- Reconnecting can't resume streams that were open on the old connection — they end, and the local proxied sockets close with them, same as any other close.
- Client only targets protocol 763 (Minecraft 1.20.1); `valence_protocol` 0.2.0-alpha.1 doesn't yet support the Configuration state newer versions require, so bumping past 1.20.1 is blocked upstream, not by design here.
- Client only supports offline-mode servers (see above).
- UDP ASSOCIATE (plugin `UdpAssociationState`, app/`tun-engine` full-tunnel mode) is new and hasn't had the same real-server soak testing as the TCP path yet.
- `tun-engine` has only been cross-compiled and `go vet`-checked from a macOS dev machine — not run on real Windows or Linux hardware. Treat first runs there as a test, not a formality; OS routing-table manipulation is the part most likely to need per-distro/per-Windows-version adjustment.
- Full-tunnel (TUN) mode isn't implemented on iOS/macOS — blocked on a paid Apple Developer Program account for the required `NetworkExtension` entitlement. Those two platforms get proxy mode / system-proxy mode only.

## Disclaimer

This is a network-obfuscation research/engineering project, built and documented the same way tools like Shadowsocks or v2ray are: openly, with the crypto and protocol design laid out above for anyone to audit. Running it against infrastructure you don't own or control, or in violation of a network's or game server's terms of service, is on you — use it only where you have the right to.

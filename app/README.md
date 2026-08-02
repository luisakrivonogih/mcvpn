# mcvpn — Flutter client

A stylish, cross-platform client for the **mcvpn** tunnel: an encrypted,
multiplexed TCP tunnel that moves its bytes inside a real Minecraft 1.20.1
protocol session, so on the wire it looks like someone playing Minecraft.

This app is a **full, from-scratch reimplementation of the mcvpn protocol in
Dart** — it speaks the real Minecraft handshake/login/play sequence, runs the
same authenticated X25519 key exchange, ChaCha20-Poly1305 framing and key
rotation as the reference Rust client and Java plugin, and multiplexes logical
streams over one connection. No native tunnel code required for the core.

## Two modes

| Mode | What it does | Platforms |
|---|---|---|
| **Proxy** | Runs a local **HTTP CONNECT** proxy and a **SOCKS5** proxy. Point any app (or your system proxy) at them; all that TCP traffic rides the tunnel. | Everywhere (Android, iOS, macOS, Windows, Linux) |
| **Full tunnel (TUN)** | Captures **all** device traffic via the OS VPN service and routes it through the tunnel — like an ordinary VPN app. | Android (wired); other platforms via a native extension — see below |

Full-tunnel mode reuses the same Dart tunnel: the OS TUN feeds a tun2socks
engine that forwards to the app's own local SOCKS5 proxy. See
[`android/INTEGRATION.md`](android/INTEGRATION.md).

## Getting a credential

The tunnel authenticates with a per-user `key_id` / `key_secret` issued by the
mcvpn server. Create one in the admin panel (or `/mcvpn user create <label>` on
the plugin console), then in the app either type the values into **Servers →
Add server**, or copy the panel's `config.toml` to the clipboard and tap
**Import config**.

- `key_id`: 16 bytes → 32 hex chars
- `key_secret`: 32 bytes → 64 hex chars
- host/port: the Minecraft (Paper + mcvpn plugin) address

## Build & run

Prerequisites: Flutter 3.19+ (Dart 3.3+).

```sh
cd app

# Generate the platform runners (first time only). --org sets the Android
# package to dev.mcvpn.mcvpn, matching the bundled Kotlin VPN service.
flutter create --org dev.mcvpn \
  --platforms android,ios,macos,windows,linux .

flutter pub get

# Run on whatever's connected:
flutter run                 # phone / emulator
flutter run -d macos        # desktop
flutter run -d windows
flutter run -d linux
```

> `flutter create` preserves the existing `lib/`, `pubspec.yaml`, and the
> Android Kotlin files — it only fills in the missing native scaffolding.

For TUN mode on Android, also do the manifest + tun2socks steps in
[`android/INTEGRATION.md`](android/INTEGRATION.md).

### Using proxy mode

Once connected in Proxy mode, the app serves:

- HTTP(S) proxy on `127.0.0.1:8080`
- SOCKS5 proxy on `127.0.0.1:1080`

Point a browser/app's proxy setting there, or set the system proxy on desktop.
Ports and LAN exposure are configurable in **Settings**.

Quick test from a terminal on the same machine:

```sh
curl -x http://127.0.0.1:8080 https://example.com
curl --socks5 127.0.0.1:1080 https://example.com
```

## Architecture

```
lib/src/
  core/     bytes/varint · Minecraft wire codec (+zlib) · packets (763)
            · mc_session (handshake→login→play actor) · camouflage
  crypto/   X25519 · HKDF-SHA256 · HMAC · ChaCha20-Poly1305 · key rotation
  tunnel/   multiplexed frames · per-stream flow control · reconnect supervisor
  proxy/    HTTP CONNECT · SOCKS5 · duplex relay
  vpn/      orchestration controller · OS-VPN platform channel
  model/    server profiles · settings · stats
  ui/       responsive Material 3 app (home · servers · logs · settings)
```

The protocol is a byte-for-byte match with the reference implementations in the
`mcvpn` repo (`client/` in Rust, `plugin/` in Java) — same packet IDs, same
handshake transcript, same AEAD envelope and HKDF labels.

## Notes & limitations

- Offline-mode servers only (same as the reference client): the plugin does its
  own application-layer encryption, so Mojang session auth buys nothing here.
- Reconnect (with backoff) is automatic; streams open on a dropped connection
  end and their local sockets close, same as the reference client.
- Web is not a target for the tunnel (browsers can't open raw TCP); the UI is
  otherwise platform-agnostic.
- Full-tunnel mode needs a tun2socks engine dropped in per platform; Proxy mode
  works everywhere with no native code.

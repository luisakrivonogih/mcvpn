# Android integration (full-tunnel / TUN mode)

The Dart app and its local proxies work on Android as-is. Whole-device **TUN
mode** additionally needs the VPN service wired into the Android project. This
folder already contains the two Kotlin files that do it:

- `app/src/main/kotlin/dev/mcvpn/mcvpn/MainActivity.kt` — hosts the
  `dev.mcvpn/vpn` method channel.
- `app/src/main/kotlin/dev/mcvpn/mcvpn/McVpnService.kt` — the `VpnService` that
  builds the TUN, excludes this app from it, and hands the TUN fd to a
  tun2socks engine pointed at the app's local SOCKS5 proxy.

## 1. Generate the platform project

From `app/`:

```sh
flutter create --org dev.mcvpn --platforms android,ios,macos,windows,linux .
```

`flutter create` will **not** overwrite the Kotlin files above (existing files
are preserved), so your method channel + service survive.

## 2. AndroidManifest.xml

In `android/app/src/main/AndroidManifest.xml` add the permission (top level,
inside `<manifest>`):

```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_SPECIAL_USE" />
```

and register the service inside `<application>`:

```xml
<service
    android:name=".McVpnService"
    android:permission="android.permission.BIND_VPN_SERVICE"
    android:foregroundServiceType="specialUse"
    android:exported="false">
    <intent-filter>
        <action android:name="android.net.VpnService" />
    </intent-filter>
</service>
```

## 3. Drop in a tun2socks engine

`McVpnService.startTun2Socks()` is the single seam. Pick one engine and
implement that method against it:

- **hev-socks5-tunnel** (recommended, small, actively maintained). Add its
  prebuilt `.so` / AAR, write a tiny config file with
  `socks5.address: 127.0.0.1` and `socks5.port: <socksPort>`, then call its
  native `start(tunFd, configPath)`.
- **badvpn / go-tun2socks JNI**: call `start(tunFd, "127.0.0.1", socksPort, mtu)`.

Everything downstream of the SOCKS5 proxy (the Minecraft tunnel itself) is
already implemented in Dart and shared with Proxy mode — the engine only has to
turn captured IP packets into SOCKS5 connections to `127.0.0.1:<socksPort>`.

Until an engine is wired in, `start` establishes the interface but relays no
packets; **Proxy mode is the fully-working path out of the box on every
platform.**

## Why exclude the app from the VPN?

`McVpnService` calls `builder.addDisallowedApplication(packageName)`. The app's
own Minecraft socket must ride the real network — if it went through the TUN
it would route through itself. Excluding the app is what breaks that loop
without needing to `protect()` individual sockets.

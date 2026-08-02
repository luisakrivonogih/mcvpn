# tun-engine

Whole-device TUN helper for mcvpn on Windows and Linux. Wraps
[xjasonlyu/tun2socks](https://github.com/xjasonlyu/tun2socks) (gVisor
netstack, no reimplemented TCP/IP) to turn a TUN interface into a client of
the Flutter app's local SOCKS5 proxy, and drives OS routing so the whole
device goes through the tunnel except the Minecraft connection that carries
it (see the package doc comment in `main.go` for why).

Not used on macOS/iOS -- those need a NetworkExtension system extension
instead (blocked on an Apple Developer Program account), and not used on
Android -- that platform gets the engine compiled in as a JNI `.so` via
`gomobile bind` rather than spawned as a subprocess (see `../android-tun/`
once that lands).

## Building

Pure Go, no cgo, no platform SDK required -- cross-compiles from any host:

```sh
CGO_ENABLED=0 GOOS=linux   GOARCH=amd64 go build -o dist/tun-engine_linux_amd64       .
CGO_ENABLED=0 GOOS=linux   GOARCH=arm64 go build -o dist/tun-engine_linux_arm64       .
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -o dist/tun-engine_windows_amd64.exe .
CGO_ENABLED=0 GOOS=windows GOARCH=arm64 go build -o dist/tun-engine_windows_arm64.exe .
```

## Running

Needs elevated privileges (root / Administrator) to create the TUN device
and edit routes -- the caller must launch it elevated (`pkexec` on Linux,
`Start-Process -Verb RunAs` on Windows), this binary does not self-elevate.

```
tun-engine -proxy 127.0.0.1:1080 -exclude-ip <mc-server-ip>
```

Prints `MCVPN_TUN_READY` on stdout once the tunnel is live, or
`MCVPN_TUN_ERROR: <message>` and exits non-zero on failure. Shuts down and
reverts routing on SIGINT/SIGTERM or when stdin closes (i.e. the parent
process died) -- see `flag.PrintDefaults` / `main.go` for the full flag set.

**This has only been cross-compiled and `go vet`-checked, not run** -- it
was written and verified from a macOS-only development machine with no
Windows or Linux host available. Treat first runs on real hardware as a
test pass, not a formality: routing table manipulation is the part most
likely to need adjustment per distro/Windows version.

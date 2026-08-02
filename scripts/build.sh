#!/usr/bin/env bash
# Interactive build menu, plus a non-interactive mode for scripting/CI:
#
#   ./scripts/build.sh              interactive menu
#   ./scripts/build.sh android      build just the Android APK
#   ./scripts/build.sh macos        build just the macOS app (+ .dmg if create-dmg is installed)
#   ./scripts/build.sh linux        build just the Linux package (only works ON Linux)
#   ./scripts/build.sh engine       cross-compile tun-engine only
#   ./scripts/build.sh all          everything this host can build
#
# Flutter does not support cross-compiling desktop targets -- confirmed by
# trying `flutter build windows`/`flutter build linux` on macOS, both refuse
# outright ("only supported on Windows/Linux hosts"). So on macOS this can
# only ever produce macOS + Android; Windows/Linux app bundles need a
# matching host or .github/workflows/release.yml's CI matrix. tun-engine
# (tun-engine) is the one target that's genuinely host-independent --
# pure Go, no cgo -- so it's always offered regardless of host OS.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

OUT="dist"
APP_VERSION="1.0.0"
HOST_OS="$(uname -s)"

# ---------------------------------------------------------------------------
# Individual build targets
# ---------------------------------------------------------------------------

build_engine() {
  echo "== tun-engine (cross-compiled, all desktop targets) =="
  mkdir -p "$OUT" tun-engine/dist
  (
    cd tun-engine
    CGO_ENABLED=0 GOOS=linux   GOARCH=amd64 go build -o dist/tun-engine_linux_amd64       .
    CGO_ENABLED=0 GOOS=linux   GOARCH=arm64 go build -o dist/tun-engine_linux_arm64       .
    CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -o dist/tun-engine_windows_amd64.exe .
    CGO_ENABLED=0 GOOS=windows GOARCH=arm64 go build -o dist/tun-engine_windows_arm64.exe .
  )
  cp tun-engine/dist/* "$OUT/"
  echo "  -> $OUT/tun-engine_*"
}

# Cross-compiles the tun2socks JNI libraries for android/app/src/main/jniLibs
# if an NDK is installed -- needed for Full tunnel mode on Android. Returns
# non-zero (caller decides whether that's fatal) if no NDK is found.
build_android_jni() {
  local ndk_root="$1"
  [ -d "$ndk_root" ] || return 1
  local ndk_version
  ndk_version=$(ls "$ndk_root" 2>/dev/null | sort -V | tail -1)
  [ -n "$ndk_version" ] || return 1
  local host_tag
  case "$HOST_OS" in
    Darwin) host_tag="darwin-x86_64" ;;
    Linux)  host_tag="linux-x86_64" ;;
    *) return 1 ;;
  esac
  local toolchain="$ndk_root/$ndk_version/toolchains/llvm/prebuilt/$host_tag/bin"
  [ -d "$toolchain" ] || return 1

  echo "== tun2socks JNI libraries (NDK $ndk_version) =="
  local jni_out="app/android/app/src/main/jniLibs"
  mkdir -p "$jni_out/arm64-v8a" "$jni_out/armeabi-v7a" "$jni_out/x86_64"
  (
    cd tun-engine
    CGO_ENABLED=1 GOOS=android GOARCH=arm64 CC="$toolchain/aarch64-linux-android24-clang" \
      go build -buildmode=c-shared -o "../../$jni_out/arm64-v8a/libtun2socks.so" ./android
    CGO_ENABLED=1 GOOS=android GOARCH=arm GOARM=7 CC="$toolchain/armv7a-linux-androideabi24-clang" \
      go build -buildmode=c-shared -o "../../$jni_out/armeabi-v7a/libtun2socks.so" ./android
    CGO_ENABLED=1 GOOS=android GOARCH=amd64 CC="$toolchain/x86_64-linux-android24-clang" \
      go build -buildmode=c-shared -o "../../$jni_out/x86_64/libtun2socks.so" ./android
  )
  echo "  -> $jni_out/*/libtun2socks.so"
}

build_macos() {
  if [ "$HOST_OS" != "Darwin" ]; then
    echo "macOS builds only work when run on macOS." >&2
    return 1
  fi
  mkdir -p "$OUT"
  echo "== macOS app (universal arm64+x86_64, whatever Xcode's default ARCHS produces) =="
  (cd app && flutter pub get && flutter build macos --release)
  local app_path="app/build/macos/Build/Products/Release/mcvpn.app"
  rm -rf "$OUT/mcvpn.app"
  cp -R "$app_path" "$OUT/"
  echo "  -> $OUT/mcvpn.app"
  if command -v create-dmg >/dev/null 2>&1; then
    rm -f "$OUT/mcvpn-macos.dmg"
    create-dmg --volname mcvpn --window-size 600 400 --app-drop-link 450 200 \
      "$OUT/mcvpn-macos.dmg" "$app_path" || true
    [ -f "$OUT/mcvpn-macos.dmg" ] && echo "  -> $OUT/mcvpn-macos.dmg"
  else
    echo "  (skipping .dmg: 'brew install create-dmg' to also get one)"
  fi
}

build_android() {
  mkdir -p "$OUT"
  local ndk_root=""
  case "$HOST_OS" in
    Darwin) ndk_root="$HOME/Library/Android/sdk/ndk" ;;
    Linux)  ndk_root="${ANDROID_HOME:-$HOME/Android/Sdk}/ndk" ;;
  esac
  echo "== Android apk =="
  build_android_jni "$ndk_root" || \
    echo "  (no NDK found under $ndk_root -- Full tunnel mode won't route packets on this build)"
  (cd app && flutter pub get && flutter build apk --release)
  cp app/build/app/outputs/flutter-apk/app-release.apk "$OUT/mcvpn-android.apk"
  echo "  -> $OUT/mcvpn-android.apk"
}

build_linux() {
  if [ "$HOST_OS" != "Linux" ]; then
    echo "Linux app bundles only work when run on Linux -- Flutter refuses to" >&2
    echo "cross-compile desktop targets. Use .github/workflows/release.yml instead." >&2
    return 1
  fi
  mkdir -p "$OUT"
  build_engine
  echo "== Linux app (.deb/.rpm if fpm is installed) =="
  (cd app && flutter pub get && flutter build linux --release)
  local bundle="app/build/linux/x64/release/bundle"
  cp "$OUT/tun-engine_linux_amd64" "$bundle/tun-engine"
  chmod +x "$bundle/tun-engine"
  if command -v fpm >/dev/null 2>&1; then
    fpm -s dir -t deb -n mcvpn -v "$APP_VERSION" --prefix /opt/mcvpn -C "$bundle" \
      --after-install scripts/linux/postinstall.sh -p "$OUT/mcvpn.deb" -f .
    fpm -s dir -t rpm -n mcvpn -v "$APP_VERSION" --prefix /opt/mcvpn -C "$bundle" \
      --after-install scripts/linux/postinstall.sh -p "$OUT/mcvpn.rpm" -f .
    echo "  -> $OUT/mcvpn.deb, $OUT/mcvpn.rpm"
  else
    echo "  (skipping .deb/.rpm: 'gem install fpm' to also get them)"
    rm -rf "$OUT/mcvpn-linux-bundle"
    cp -R "$bundle" "$OUT/mcvpn-linux-bundle"
    echo "  -> $OUT/mcvpn-linux-bundle (raw, unpackaged)"
  fi
}

note_windows() {
  echo "Windows builds only work when run on Windows -- Flutter refuses to" >&2
  echo "cross-compile desktop targets. Use .github/workflows/release.yml instead" >&2
  echo "(push a v* tag, or 'gh workflow run release.yml' after pushing)." >&2
  return 1
}

build_all() {
  build_engine
  case "$HOST_OS" in
    Darwin)
      build_macos
      build_android
      echo
      echo "Windows (.exe/.msi) and Linux (.deb/.rpm) app bundles cannot be built"
      echo "from macOS. Use .github/workflows/release.yml, or build on an actual"
      echo "Windows/Linux machine."
      ;;
    Linux)
      build_linux
      build_android
      echo
      echo "macOS (.app/.dmg) and Windows (.exe/.msi) app bundles cannot be built"
      echo "from Linux. Use .github/workflows/release.yml, or build on an actual"
      echo "macOS/Windows machine."
      ;;
    *)
      echo "Unrecognized host OS $HOST_OS; only macOS/Linux hosts are handled here." >&2
      echo "On Windows: cd app && flutter build windows --release" >&2
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# CLI entry point: run directly if an argument was given, else show a menu.
# ---------------------------------------------------------------------------

run_target() {
  case "$1" in
    all)     build_all ;;
    macos)   build_macos ;;
    android) build_android ;;
    linux)   build_linux ;;
    windows) note_windows ;;
    engine)  build_engine ;;
    *)
      echo "Unknown target: $1" >&2
      echo "Valid targets: all macos android linux windows engine" >&2
      exit 2
      ;;
  esac
}

if [ "$#" -gt 0 ]; then
  run_target "$1"
  echo
  echo "Done. Artifacts in $OUT/"
  exit 0
fi

echo "mcvpn build"
echo "==========="
echo "Host: $HOST_OS"
echo
echo "  1) Everything this host can build"
echo "  2) macOS app (.app / .dmg)$( [ "$HOST_OS" = Darwin ] || echo '  [only works on macOS]' )"
echo "  3) Android APK"
echo "  4) Linux package (.deb / .rpm)$( [ "$HOST_OS" = Linux ] || echo '  [only works on Linux]' )"
echo "  5) Windows installer (.exe / .msi)  [only works on Windows]"
echo "  6) tun-engine only (cross-compiled Go binaries)"
echo "  0) Quit"
echo
read -r -p "Choice [1]: " choice
choice="${choice:-1}"

case "$choice" in
  1) build_all ;;
  2) build_macos ;;
  3) build_android ;;
  4) build_linux ;;
  5) note_windows ;;
  6) build_engine ;;
  0) echo "Bye."; exit 0 ;;
  *) echo "Unrecognized choice: $choice" >&2; exit 2 ;;
esac

echo
echo "Done. Artifacts in $OUT/"

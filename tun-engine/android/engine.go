// Package main builds as a JNI-callable shared library (libtun2socks.so)
// for Android, unlike the sibling ../main.go (a standalone process for
// Windows/Linux). Android apps can't open /dev/net/tun or exec arbitrary
// binaries from app-private storage, but VpnService.Builder.establish()
// hands the app an already-open TUN file descriptor -- tun2socks' fdbased
// driver ("fd://<n>") consumes that directly, no device creation needed on
// this side at all, and no routing table work either (VpnService.Builder's
// addRoute/addDisallowedApplication in McVpnService.kt already did that).
//
// Cross-compiles with cgo (unlike the desktop engine) because Android's
// JNI ABI requires it -- needs the NDK's clang, not just `go build`:
//
//	NDK=$HOME/Library/Android/sdk/ndk/<version>
//	TOOLCHAIN=$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin
//	CGO_ENABLED=1 GOOS=android GOARCH=arm64 \
//	  CC=$TOOLCHAIN/aarch64-linux-android24-clang \
//	  go build -buildmode=c-shared -o libtun2socks_arm64.so .
//
// Repeat per Android ABI (armeabi-v7a: armv7a-linux-androideabi24-clang,
// x86_64: x86_64-linux-android24-clang) and drop each .so into
// android/app/src/main/jniLibs/<abi>/libtun2socks.so, named exactly that --
// dev.mcvpn.mcvpn.Tun2Socks loads it via System.loadLibrary("tun2socks").
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"fmt"
	"unsafe"

	"github.com/xjasonlyu/tun2socks/v2/engine"
)

// Named for JNI's implicit-registration convention
// (Java_<package_with_underscores>_<Class>_<method>) rather than
// RegisterNatives, so Kotlin's `external fun` just needs a matching
// `external` declaration in dev.mcvpn.mcvpn.Tun2Socks -- no manual JNI
// registration call anywhere. `env`/`thiz` are unused but must stay first:
// that's the fixed calling convention the JNI dispatcher uses to invoke
// this symbol. They're typed as unsafe.Pointer (-> C's void*) rather than
// the real JNIEnv*/jobject to avoid needing jni.h in this cgo build --
// every JNI type here is a pointer, so the ABI is identical either way.
//
//export Java_dev_mcvpn_mcvpn_Tun2Socks_nativeStart
func Java_dev_mcvpn_mcvpn_Tun2Socks_nativeStart(env, thiz unsafe.Pointer, fd, mtu, socksPort C.int) C.int {
	key := &engine.Key{
		MTU:    int(mtu),
		Device: fmt.Sprintf("fd://%d", int(fd)),
		Proxy:  fmt.Sprintf("socks5://127.0.0.1:%d", int(socksPort)),
	}
	engine.Insert(key)
	engine.Start()
	return 0
}

//export Java_dev_mcvpn_mcvpn_Tun2Socks_nativeStop
func Java_dev_mcvpn_mcvpn_Tun2Socks_nativeStop(env, thiz unsafe.Pointer) {
	engine.Stop()
}

func main() {}

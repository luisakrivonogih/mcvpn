package dev.mcvpn.mcvpn

/**
 * JNI binding to `libtun2socks.so`, built from `tun-engine/android`
 * (a gVisor-netstack-based tun2socks, see that module's doc comment).
 *
 * Method names/signatures must match the Go side's `//export
 * Java_dev_mcvpn_mcvpn_Tun2Socks_native*` symbols exactly -- JNI resolves
 * them by name via System.loadLibrary, there's no registration step.
 */
object Tun2Socks {
    init {
        System.loadLibrary("tun2socks")
    }

    /** Starts relaying [fd]'s packets to the local SOCKS5 proxy at 127.0.0.1:[socksPort]. */
    external fun nativeStart(fd: Int, mtu: Int, socksPort: Int): Int

    external fun nativeStop()
}

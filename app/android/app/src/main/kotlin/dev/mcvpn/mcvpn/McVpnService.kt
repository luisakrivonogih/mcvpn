package dev.mcvpn.mcvpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log

/**
 * The full-tunnel (TUN) engine for Android.
 *
 * It builds a VPN interface that captures all device traffic, **excludes this
 * app** from the tunnel (so the Dart tunnel's own Minecraft socket rides the
 * real network, not the VPN — otherwise you'd get an infinite loop), and hands
 * the TUN file descriptor to [Tun2Socks] (JNI into `libtun2socks.so`, built
 * from `tun-engine/android`), which turns each captured TCP/UDP flow
 * into a SOCKS5 connection to the Dart app's local proxy at
 * 127.0.0.1:<socksPort>. From there the existing tunnel carries it over
 * Minecraft exactly as in Proxy mode.
 */
class McVpnService : VpnService() {

    companion object {
        const val ACTION_START = "dev.mcvpn.START"
        const val ACTION_STOP = "dev.mcvpn.STOP"
        const val EXTRA_SOCKS_PORT = "socksPort"
        const val EXTRA_SESSION = "session"
        private const val TAG = "McVpnService"
        private const val NOTIF_CHANNEL = "mcvpn_vpn"
        private const val NOTIF_ID = 0x6d63
        private const val MTU = 1500

        @Volatile
        var isRunning: Boolean = false
            private set

        /**
         * Set by [MainActivity] right before it starts this service, so
         * [startTunnel] can report back whether the TUN actually came up --
         * `startService()` alone only confirms the Intent was dispatched, not
         * that `establish()` (or `startForeground()`, which throws on API 34+
         * without the right permission/type) actually succeeded.
         */
        var onStartResult: ((Boolean, String?) -> Unit)? = null
    }

    private var tunInterface: ParcelFileDescriptor? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopTunnel()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_START -> {
                val socksPort = intent.getIntExtra(EXTRA_SOCKS_PORT, 1080)
                val session = intent.getStringExtra(EXTRA_SESSION) ?: "mcvpn"
                startTunnel(socksPort, session)
            }
        }
        return START_STICKY
    }

    private fun startTunnel(socksPort: Int, session: String) {
        if (isRunning) return
        val reportResult = onStartResult
        onStartResult = null
        try {
            val builder = Builder()
                .setSession(session)
                .setMtu(MTU)
                .addAddress("10.10.10.2", 32)
                .addDnsServer("1.1.1.1")
                .addDnsServer("8.8.8.8")
                .addRoute("0.0.0.0", 0) // capture all IPv4

            // Critical: keep this app's own sockets (the Minecraft tunnel) off
            // the VPN, or the tunnel would route through itself.
            try {
                builder.addDisallowedApplication(packageName)
            } catch (e: Exception) {
                Log.w(TAG, "could not exclude self from VPN", e)
            }

            val tun = builder.establish() ?: run {
                Log.e(TAG, "establish() returned null")
                stopSelf()
                reportResult?.invoke(false, "VpnService.Builder.establish() returned null")
                return
            }
            tunInterface = tun

            // Throws on API 34+ if foregroundServiceType="specialUse" is
            // declared without the matching FOREGROUND_SERVICE_SPECIAL_USE
            // permission -- caught below, which used to fail silently from
            // the Dart side's point of view (startService() had already
            // "succeeded" by then).
            startForeground(NOTIF_ID, buildNotification(session))
            isRunning = true

            startTun2Socks(tun, socksPort)
            Log.i(TAG, "TUN up; forwarding to socks5 127.0.0.1:$socksPort")
            reportResult?.invoke(true, null)
        } catch (e: Exception) {
            Log.e(TAG, "failed to start TUN", e)
            stopTunnel()
            stopSelf()
            reportResult?.invoke(false, e.message ?: e.toString())
        }
    }

    private fun startTun2Socks(tun: ParcelFileDescriptor, socksPort: Int) {
        val rc = Tun2Socks.nativeStart(tun.fd, MTU, socksPort)
        if (rc != 0) {
            Log.e(TAG, "tun2socks nativeStart returned $rc")
        }
    }

    private fun stopTunnel() {
        isRunning = false
        try {
            // nativeStop() (tun2socks' engine.Stop()) already closes the raw
            // fd itself -- see core/device/fdbased's FD.Close(), which calls
            // unix.Close(f.fd) on exactly the int we handed to nativeStart().
            // Calling ParcelFileDescriptor.close() again afterward would be a
            // double-close on that same fd number, which in a process this
            // busy (Flutter/Dart sockets, the gVisor netstack's own fds) can
            // get reused in between the two closes -- silently tearing down
            // an unrelated live fd instead, which is exactly the kind of
            // native crash Kotlin's catch here can't intercept. detachFd()
            // just disarms this object's own close-on-finalize without
            // touching the (already closed) underlying fd.
            Tun2Socks.nativeStop()
            tunInterface?.detachFd()
        } catch (_: Exception) {
        }
        tunInterface = null
        stopForeground(STOP_FOREGROUND_REMOVE)
    }

    private fun buildNotification(session: String): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIF_CHANNEL,
                "mcvpn tunnel",
                NotificationManager.IMPORTANCE_LOW,
            )
            nm.createNotificationChannel(channel)
        }
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val pi = PendingIntent.getActivity(
            this, 0, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, NOTIF_CHANNEL)
            .setContentTitle("mcvpn connected")
            .setContentText("Tunnelling “$session” over Minecraft")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
    }

    override fun onDestroy() {
        stopTunnel()
        super.onDestroy()
    }
}

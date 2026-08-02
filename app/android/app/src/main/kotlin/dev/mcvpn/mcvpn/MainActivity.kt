package dev.mcvpn.mcvpn

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the `dev.mcvpn/vpn` method channel that drives full-tunnel (TUN) mode.
 *
 * `prepare` shows Android's system VPN-consent dialog; `start`/`stop` control
 * [McVpnService], which builds the TUN, excludes this app from it (so the
 * tunnel's own Minecraft socket bypasses the VPN), and runs a tun2socks engine
 * that forwards every captured flow to the Dart app's local SOCKS5 proxy.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "dev.mcvpn/vpn"
    private var pendingPrepare: MethodChannel.Result? = null

    companion object {
        private const val REQUEST_VPN = 0x1001
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result -> onMethodCall(call, result) }
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepare" -> {
                val intent = VpnService.prepare(this)
                if (intent != null) {
                    pendingPrepare = result
                    startActivityForResult(intent, REQUEST_VPN)
                } else {
                    result.success(true)
                }
            }
            "start" -> {
                val socksPort = (call.argument<Int>("socksPort")) ?: 1080
                val sessionName = call.argument<String>("sessionName") ?: "mcvpn"

                // Wait for McVpnService to actually confirm the TUN came up --
                // startService() alone only proves the Intent was dispatched;
                // establish()/startForeground() can still fail inside the
                // service (e.g. a missing manifest permission on newer
                // Android versions), which used to be invisible from here.
                val handler = Handler(Looper.getMainLooper())
                var resolved = false
                val timeout = Runnable {
                    if (!resolved) {
                        resolved = true
                        McVpnService.onStartResult = null
                        result.error("vpn_start_timeout", "VPN service did not respond in time", null)
                    }
                }
                McVpnService.onStartResult = { ok, error ->
                    handler.post {
                        if (!resolved) {
                            resolved = true
                            handler.removeCallbacks(timeout)
                            if (ok) result.success(true) else result.error("vpn_start_failed", error, null)
                        }
                    }
                }
                handler.postDelayed(timeout, 5000)

                val intent = Intent(this, McVpnService::class.java).apply {
                    action = McVpnService.ACTION_START
                    putExtra(McVpnService.EXTRA_SOCKS_PORT, socksPort)
                    putExtra(McVpnService.EXTRA_SESSION, sessionName)
                }
                startService(intent)
            }
            "stop" -> {
                val intent = Intent(this, McVpnService::class.java).apply {
                    action = McVpnService.ACTION_STOP
                }
                startService(intent)
                result.success(null)
            }
            "isRunning" -> result.success(McVpnService.isRunning)
            else -> result.notImplemented()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_VPN) {
            pendingPrepare?.success(resultCode == Activity.RESULT_OK)
            pendingPrepare = null
        }
        super.onActivityResult(requestCode, resultCode, data)
    }
}

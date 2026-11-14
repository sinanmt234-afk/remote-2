package com.aether.remote

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.media.AudioManager
import android.net.wifi.WifiManager
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.ServerSocket
import kotlin.math.abs
import java.net.Socket

class RemoteService : AccessibilityService() {
    private val main = Handler(Looper.getMainLooper())
    private var server: ServerSocket? = null
    private var udp: DatagramSocket? = null
    private var lock: WifiManager.MulticastLock? = null
    @Volatile private var running = false

    override fun onServiceConnected() {
        super.onServiceConnected()
        running = true
        val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        lock = wm.createMulticastLock("aether").apply { setReferenceCounted(false); acquire() }
        Thread { runTcp() }.start()
        Thread { runUdp() }.start()
    }

    override fun onDestroy() {
        running = false
        try { server?.close() } catch (_: Exception) {}
        try { udp?.close() } catch (_: Exception) {}
        try { lock?.release() } catch (_: Exception) {}
        super.onDestroy()
    }

    override fun onAccessibilityEvent(e: AccessibilityEvent?) {
        if (e?.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) { lastRect = null; useLast = false }
    }
    override fun onInterrupt() {}

    private fun runUdp() {
        try {
            udp = DatagramSocket(null).apply { reuseAddress = true; bind(java.net.InetSocketAddress(8766)); broadcast = true }
            val buf = ByteArray(64)
            while (running) {
                val p = DatagramPacket(buf, buf.size)
                udp!!.receive(p)
                if (String(p.data, 0, p.length).trim() == "AETHER?") {
                    val r = "AETHER!${Cfg.name()}".toByteArray()
                    udp!!.send(DatagramPacket(r, r.size, p.address, p.port))
                }
            }
        } catch (_: Exception) {}
    }

    private fun runTcp() {
        try {
            server = ServerSocket(8765)
            while (running) {
                val c = server!!.accept()
                Thread { handle(c) }.start()
            }
        } catch (_: Exception) {}
    }

    private fun handle(c: Socket) {
        try {
            c.soTimeout = 3000
            val line = BufferedReader(InputStreamReader(c.getInputStream())).readLine() ?: ""
            val i = line.indexOf(':')
            val pin = if (i > 0) line.substring(0, i) else ""
            val key = if (i > 0) line.substring(i + 1).trim() else ""
            val out = c.getOutputStream()
            if (pin != Cfg.pin(this)) {
                Thread.sleep(1000) // slow down PIN guessing
                out.write("BAD\n".toByteArray())
            } else {
                if (key != "PING") main.post { press(key) }
                out.write("OK\n".toByteArray())
            }
            out.flush()
        } catch (_: Exception) {
        } finally {
            try { c.close() } catch (_: Exception) {}
        }
    }

    private fun press(key: String) {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        when (key) {
            "UP" -> dpad(0, 16)
            "DOWN" -> dpad(1, 17)
            "LEFT" -> dpad(2, 18)
            "RIGHT" -> dpad(3, 19)
            "OK" -> ok()
            "BACK" -> performGlobalAction(GLOBAL_ACTION_BACK)
            "HOME" -> performGlobalAction(GLOBAL_ACTION_HOME)
            "RECENTS" -> performGlobalAction(GLOBAL_ACTION_RECENTS)
            "POWER" -> performGlobalAction(GLOBAL_ACTION_POWER_DIALOG)
            "VOL_UP" -> am.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_RAISE, AudioManager.FLAG_SHOW_UI)
            "VOL_DOWN" -> am.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_LOWER, AudioManager.FLAG_SHOW_UI)
            "MUTE" -> am.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_TOGGLE_MUTE, AudioManager.FLAG_SHOW_UI)
            "PLAY" -> media(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
            "NEXT" -> media(KeyEvent.KEYCODE_MEDIA_NEXT)
            "PREV" -> media(KeyEvent.KEYCODE_MEDIA_PREVIOUS)
            "FF" -> media(KeyEvent.KEYCODE_MEDIA_FAST_FORWARD)
            "RW" -> media(KeyEvent.KEYCODE_MEDIA_REWIND)
        }
    }

    private fun media(code: Int) {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, code))
        am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, code))
    }

    private var lastRect: Rect? = null
    private var useLast = false

    private fun collect(n: AccessibilityNodeInfo?, out: MutableList<AccessibilityNodeInfo>, screenArea: Long) {
        if (n == null) return
        if (n.isVisibleToUser && n.isEnabled && (n.isFocusable || n.isClickable)) {
            val r = Rect(); n.getBoundsInScreen(r)
            if (!r.isEmpty && r.width().toLong() * r.height() < screenArea * 6 / 10) out.add(n)
        }
        for (i in 0 until n.childCount) collect(n.getChild(i), out, screenArea)
    }

    private fun moveTo(n: AccessibilityNodeInfo) {
        val r = Rect(); n.getBoundsInScreen(r)
        lastRect = r
        val ok = n.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
        n.performAction(AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS)
        useLast = !ok
    }

    // idx: 0=UP 1=DOWN 2=LEFT 3=RIGHT. Geometry based: picks nearest focusable/clickable item in that direction.
    private fun dpad(idx: Int, globalAction: Int) {
        if (Build.VERSION.SDK_INT >= 33 && performGlobalAction(globalAction)) return
        val root = rootInActiveWindow ?: return
        val dm = resources.displayMetrics
        val nodes = ArrayList<AccessibilityNodeInfo>()
        collect(root, nodes, dm.widthPixels.toLong() * dm.heightPixels)
        val cur = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            ?: root.findFocus(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY)
        if (nodes.isEmpty()) { scroll(cur ?: root, idx == 1 || idx == 3); return }
        var from: Rect? = null
        if (useLast && lastRect != null) from = lastRect
        else if (cur != null) { from = Rect(); cur.getBoundsInScreen(from) }
        if (from == null) {
            var first = nodes[0]; var fk = Long.MAX_VALUE
            for (n in nodes) {
                val r = Rect(); n.getBoundsInScreen(r)
                val k = r.top * 10000L + r.left
                if (k < fk) { fk = k; first = n }
            }
            moveTo(first); return
        }
        val fx = from.exactCenterX(); val fy = from.exactCenterY()
        var best: AccessibilityNodeInfo? = null
        var bestScore = Float.MAX_VALUE
        for (n in nodes) {
            val r = Rect(); n.getBoundsInScreen(r)
            if (r == from) continue
            val dx = r.exactCenterX() - fx
            val dy = r.exactCenterY() - fy
            val main: Float; val cross: Float
            when (idx) {
                0 -> { main = -dy; cross = abs(dx) }
                1 -> { main = dy; cross = abs(dx) }
                2 -> { main = -dx; cross = abs(dy) }
                else -> { main = dx; cross = abs(dy) }
            }
            if (main < 8f) continue
            val score = main + cross * 2f
            if (score < bestScore) { bestScore = score; best = n }
        }
        if (best != null) moveTo(best) else scroll(cur ?: root, idx == 1 || idx == 3)
    }

    private fun scroll(n: AccessibilityNodeInfo, fwd: Boolean) {
        var p: AccessibilityNodeInfo? = n
        while (p != null) {
            if (p.isScrollable) {
                p.performAction(if (fwd) AccessibilityNodeInfo.ACTION_SCROLL_FORWARD else AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD)
                return
            }
            p = p.parent
        }
    }

    private fun tap(n: AccessibilityNodeInfo) {
        val r = Rect(); n.getBoundsInScreen(r)
        val path = Path().apply { moveTo(r.exactCenterX(), r.exactCenterY()) }
        val g = GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(path, 0, 60)).build()
        dispatchGesture(g, null, null)
    }

    private fun ok() {
        if (Build.VERSION.SDK_INT >= 33 && performGlobalAction(20)) return
        val root = rootInActiveWindow ?: return
        var n: AccessibilityNodeInfo? = null
        if (!(useLast && lastRect != null)) {
            n = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: root.findFocus(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY)
        }
        if (n == null && lastRect != null) {
            val dm = resources.displayMetrics
            val nodes = ArrayList<AccessibilityNodeInfo>()
            collect(root, nodes, dm.widthPixels.toLong() * dm.heightPixels)
            for (c in nodes) { val r = Rect(); c.getBoundsInScreen(r); if (r == lastRect) { n = c; break } }
        }
        if (n == null) return
        var t: AccessibilityNodeInfo? = n
        while (t != null) {
            if (t.isClickable && t.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return
            t = t.parent
        }
        tap(n)
    }
}

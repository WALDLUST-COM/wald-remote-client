package com.carriez.flutter_hbb

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Binder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.RemoteException
import android.util.Log
import co.kr.waldlust.remote.inject.IWaldInjector
import java.io.IOException
import java.security.MessageDigest

/**
 * Waldlust(DSK-02 — 부록 A-69, 결정 D47): 터치 패널이 없는 화면(일반 모니터를 붙인 보드)에서도 원격 클릭이 되게 입력 주입 플러그인으로
 * 포인터 입력을 보낸다.
 *
 * Android 11+ 는 화면에 실제 터치 패널이 없으면 접근성 제스처(dispatchGesture)를 바로 취소한다(AccessibilityServiceConnection
 * — isTouchableDisplay). 플러그인(co.kr.waldlust.remote.inject)은 보드 플랫폼 키로 서명해 INJECT_EVENTS 로 터치를 직접 넣는다
 * (AnyDesk aosp2 와 같은 방식).
 * - 이 기기 플랫폼 키로 서명된 플러그인이 깔려 있고(= 권한이 실제로 있다) 주입할 수 있다고 답할 때만 쓴다. 그러면 터치 패널이 있어도 이쪽.
 * - 왼쪽 버튼·이동·오른쪽 클릭(길게 누르기)·휠·터치만 보낸다. 뒤로·홈·최근 앱은 지금처럼 도우미(또는 이 앱) 접근성 전역 동작으로 간다
 *   (터치 패널이 없어도 된다). 키 입력·화면 공유 자동 승인도 접근성이 그대로 맡는다.
 * - 설치(결정 D48): 수신 전용 빌드는 플러그인을 assets/wald-inject.apk 로 넣고, 그 플랫폼 인증서 SHA-256 을 assets/wald-inject.cert 에
 *   적는다. 이 기기 플랫폼 키(`android` 패키지 서명)와 같을 때만 홈 카드·권유 창이 설치를 권한다(터치가 있어도 — 키가 다르면 깔아도
 *   INJECT_EVENTS 가 허가되지 않으니 권하지 않는다). 설치 기계는 도우미와 같다([WaldBundledApp]).
 */
object WaldInjector {
    private const val logTag = "WaldInjector"
    const val PKG = "co.kr.waldlust.remote.inject"
    private const val ACTION_INJECT = "co.kr.waldlust.remote.inject.INJECT"
    private const val REQUIRED_PROTOCOL = 1
    private const val CERT_ASSET = "wald-inject.cert"

    val bundle = WaldBundledApp(PKG, "wald-inject.apk", "inject")

    @Volatile
    private var applicable: Boolean? = null

    @Volatile
    private var remote: IWaldInjector? = null
    @Volatile
    private var appContext: Context? = null
    private var bound = false
    // 플러그인 서비스에 연결됐다(쓸 수 있는지와 별개 — 쓸 수 없는 플러그인에 되풀이해 다시 바인딩하지 않게)
    @Volatile
    private var connected = false
    private var bindCheckToken = 0
    private var receiverRegistered = false
    private var retryDelayMs = 1_000L
    private val mainHandler = Handler(Looper.getMainLooper())
    // 이 프로세스 표식 — 이 앱이 죽으면 플러그인이 진행 중인 획을 취소한다.
    private val token = Binder()

    /** 이 기기 플랫폼 키로 서명된 플러그인이 있는가(서명이 다르면 INJECT_EVENTS 가 허가되지 않는다). */
    private fun isUsable(context: Context): Boolean {
        val pm = context.packageManager
        if (pm.resolveService(Intent(ACTION_INJECT).setPackage(PKG), 0) == null) return false
        if (pm.checkSignatures("android", PKG) != PackageManager.SIGNATURE_MATCH) {
            Log.w(logTag, "inject plugin is not signed with this device's platform key — not used")
            return false
        }
        return true
    }

    private fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    /** 이 기기 플랫폼 키 인증서(`android` 패키지 서명)의 SHA-256. */
    @Suppress("DEPRECATION")
    private fun platformCertSha256(context: Context): String? = try {
        val pm = context.packageManager
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            pm.getPackageInfo("android", PackageManager.GET_SIGNING_CERTIFICATES).signingInfo?.apkContentsSigners
        } else {
            pm.getPackageInfo("android", PackageManager.GET_SIGNATURES).signatures
        }
        signatures?.firstOrNull()?.let { sha256Hex(it.toByteArray()) }
    } catch (e: PackageManager.NameNotFoundException) {
        null
    }

    /** 이 앱에 든 플러그인이 이 기기 플랫폼 키로 서명돼 있다(= 깔면 쓸 수 있다). 플러그인이 없는 빌드는 false. */
    fun applicable(context: Context): Boolean {
        applicable?.let { return it }
        val want = try {
            context.assets.open(CERT_ASSET).bufferedReader().use { it.readText() }.trim().lowercase()
        } catch (e: IOException) {
            null
        }
        val result = want != null && want.isNotEmpty() && want == platformCertSha256(context)
        if (want != null && !result) Log.i(logTag, "bundled inject plugin is for another platform key — not offered")
        applicable = result
        return result
    }

    /** 이 화면에 터치 패널이 없다(Android 11+ 는 접근성 제스처가 취소된다 — 플러그인이 없으면 원격 클릭이 안 된다). */
    fun noTouch(context: Context): Boolean =
        context.resources.configuration.touchscreen == Configuration.TOUCHSCREEN_NOTOUCH

    /** 플러그인으로 포인터 입력을 보내고 있다. */
    fun isUsed(): Boolean = remote != null

    /** 이 기기에 맞는 플러그인이 들어 있는데 아직 없거나 옛 버전이다. */
    fun needsInstall(context: Context): Boolean =
        applicable(context) && (!bundle.isInstalled(context) || bundle.needsUpdate(context))

    /** 홈 카드 [플러그인 설치] — [WaldBundledApp.install]. 이 기기와 맞지 않으면 "not_applicable". */
    fun install(activity: Activity): String =
        if (applicable(activity)) bundle.install(activity) else "not_applicable"

    /** 앱을 열 때·앱 업데이트 뒤 — 이 기기에 맞는 플러그인만 창 없이 업데이트한다(Android 12+·이 앱이 깐 것). */
    fun updateSilentlyIfNeeded(context: Context) {
        if (applicable(context)) bundle.updateSilentlyIfNeeded(context)
    }

    /** 플러그인에 바인딩한다(한 번만 — 프로세스가 사는 동안 유지). 플러그인 설치·업데이트·삭제도 지켜본다. */
    @Synchronized
    fun ensureBound(context: Context) {
        val app = context.applicationContext
        appContext = app
        if (!receiverRegistered) {
            val filter = IntentFilter().apply {
                addAction(Intent.ACTION_PACKAGE_ADDED)
                addAction(Intent.ACTION_PACKAGE_REPLACED)
                addAction(Intent.ACTION_PACKAGE_REMOVED)
                addDataScheme("package")
            }
            app.registerReceiver(packageReceiver, filter)
            receiverRegistered = true
        }
        if (bound || !isUsable(app)) return
        bound = try {
            app.bindService(Intent(ACTION_INJECT).setPackage(PKG), connection, Context.BIND_AUTO_CREATE)
        } catch (e: SecurityException) {
            Log.w(logTag, "bind refused: ${e.message}")
            false
        }
        if (bound) {
            scheduleBindCheck(10_000L)
        } else {
            unbindQuietly(app)
            Log.i(logTag, "inject plugin bind failed, retry in ${retryDelayMs}ms")
            rebindLater(retryDelayMs)
            retryDelayMs = (retryDelayMs * 2).coerceAtMost(60_000L)
        }
    }

    @Synchronized
    private fun unbind() {
        val app = appContext ?: return
        if (bound) unbindQuietly(app)
        bound = false
        connected = false
        remote = null
    }

    private fun unbindQuietly(app: Context) {
        try {
            app.unbindService(connection)
        } catch (e: IllegalArgumentException) {
            // 바인딩되지 않은 연결
        }
    }

    private fun rebindLater(delayMs: Long) {
        mainHandler.postDelayed({ appContext?.let { ensureBound(it) } }, delayMs)
    }

    /** delayMs 안에 연결되지 않으면 죽은 바인딩으로 보고 다시 한다(Android 7 이하는 onBindingDied 가 없다 — WaldInputBridge 와 같다). */
    private fun scheduleBindCheck(delayMs: Long) {
        val check = ++bindCheckToken
        mainHandler.postDelayed({
            if (check == bindCheckToken && bound && !connected) {
                unbind()
                rebindLater(retryDelayMs)
                retryDelayMs = (retryDelayMs * 2).coerceAtMost(60_000L)
            }
        }, delayMs)
    }

    private val packageReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.data?.schemeSpecificPart != PKG) return
            if (intent.action == Intent.ACTION_PACKAGE_REMOVED && intent.getBooleanExtra(Intent.EXTRA_REPLACING, false)) return
            Log.d(logTag, "inject plugin package ${intent.action}")
            unbind()
            if (intent.action != Intent.ACTION_PACKAGE_REMOVED) rebindLater(500)
        }
    }

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            connected = true
            val r = IWaldInjector.Stub.asInterface(service)
            remote = try {
                if (r == null || r.protocolVersion() < REQUIRED_PROTOCOL) {
                    Log.w(logTag, "inject plugin protocol too old")
                    null
                } else if (!r.canInject()) {
                    Log.w(logTag, "inject plugin has no INJECT_EVENTS permission")
                    null
                } else {
                    r.attach(token)
                    retryDelayMs = 1_000L
                    r
                }
            } catch (e: Exception) {
                // RemoteException·SecurityException(이 앱 서명을 고정하지 않은 플러그인)
                Log.w(logTag, "inject plugin setup failed: $e")
                null
            }
            Log.i(logTag, "inject plugin connected, used=${remote != null}")
            WaldHelper.notifyFlutter("inject") // 홈 카드 '화면 입력' 줄을 다시 읽는다
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            // 플러그인 프로세스가 죽었다 — 시스템이 다시 띄우면 onServiceConnected 가 다시 온다.
            Log.i(logTag, "inject plugin disconnected")
            connected = false
            remote = null
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) scheduleBindCheck(5_000L)
        }

        override fun onBindingDied(name: ComponentName?) {
            unbind()
            rebindLater(retryDelayMs)
            retryDelayMs = (retryDelayMs * 2).coerceAtMost(60_000L)
        }

        override fun onNullBinding(name: ComponentName?) {
            unbind()
        }
    }

    /** 플러그인으로 보냈으면 true. 아니면 호출한 쪽이 지금처럼 도우미·이 앱 InputService 로 보낸다(Rust 연결 스레드 — oneway). */
    fun pointer(kind: Int, mask: Int, x: Int, y: Int): Boolean {
        val r = remote ?: return false
        // 뒤로·홈·최근 앱은 접근성 전역 동작으로(터치 패널이 없어도 된다)
        if (kind == 1 && (mask == BACK_UP || mask == WHEEL_BUTTON_DOWN || mask == WHEEL_BUTTON_UP)) return false
        val scale = SCREEN_INFO.scale
        return try {
            r.pointer(kind, mask, x * scale, y * scale)
            true
        } catch (e: RemoteException) {
            Log.w(logTag, "inject plugin call failed: $e")
            remote = null
            false
        }
    }
}

package com.oneplusdream.flutter_realtime_processed_video

import android.app.Activity
import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Display
import android.view.WindowManager
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.function.Consumer

/**
 * Manages Android window capture protection (`FLAG_SECURE`), Android 15+
 * screen-recording callbacks, and presentation/wireless-mirror display
 * detection while excluding in-app room screen-sharing sessions.
 */
internal class AndroidScreenCaptureProtection(
    private val context: Context,
    private val channel: MethodChannel,
    private val isOwnCaptureActive: () -> Boolean,
) : MethodChannel.MethodCallHandler {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var activity: Activity? = null
    private var protectionEnabled = false
    private var suspendSecureWindow = false
    private var addedFlagSecureToActivity: Activity? = null
    private var osRecordingVisible = false
    private var lastReportedCaptured = false
    private var displayListenerRegistered = false
    private var recordingCallbackConsumer: Consumer<Int>? = null
    private var recordingCallbackWindowManager: WindowManager? = null

    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) = evaluateAndEmitIfNeeded()
        override fun onDisplayRemoved(displayId: Int) = evaluateAndEmitIfNeeded()
        override fun onDisplayChanged(displayId: Int) = evaluateAndEmitIfNeeded()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setProtectionEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") == true
                val suspendSecure = call.argument<Boolean>("suspendSecureWindow") == true
                runOnMain {
                    updateConfiguration(enabled, suspendSecure)
                    result.success(lastReportedCaptured)
                }
            }
            "isExternalScreenCaptured" -> {
                runOnMain {
                    result.success(computeExternalCaptured())
                }
            }
            else -> result.notImplemented()
        }
    }

    fun setActivity(nextActivity: Activity?) {
        runOnMain {
            if (activity === nextActivity) return@runOnMain
            detachFromCurrentActivity()
            activity = nextActivity
            if (protectionEnabled && nextActivity != null) {
                attachToCurrentActivity(nextActivity)
                evaluateAndEmitIfNeeded(forceEmitIfCaptured = true)
            }
        }
    }

    fun notifyOwnCaptureChanged() {
        runOnMain {
            if (!protectionEnabled) return@runOnMain
            syncFlagSecure()
            evaluateAndEmitIfNeeded()
        }
    }

    fun dispose() {
        runOnMain {
            protectionEnabled = false
            suspendSecureWindow = false
            stopDisplayObserver()
            detachFromCurrentActivity()
            activity = null
            osRecordingVisible = false
            lastReportedCaptured = false
        }
    }

    private fun updateConfiguration(enabled: Boolean, suspendSecure: Boolean) {
        val wasEnabled = protectionEnabled
        protectionEnabled = enabled
        suspendSecureWindow = suspendSecure
        if (!enabled) {
            stopDisplayObserver()
            detachFromCurrentActivity()
            osRecordingVisible = false
            lastReportedCaptured = false
            return
        }
        startDisplayObserver()
        val currentActivity = activity
        if (!wasEnabled && currentActivity != null) {
            attachToCurrentActivity(currentActivity)
        } else {
            syncFlagSecure()
        }
        val current = computeExternalCaptured()
        if (!wasEnabled) {
            lastReportedCaptured = current
            if (current) emit(current)
        } else {
            evaluateAndEmitIfNeeded()
        }
    }

    private fun attachToCurrentActivity(target: Activity) {
        syncFlagSecure()
        if (Build.VERSION.SDK_INT >= 35) {
            registerScreenRecordingCallbackApi35(target)
        }
    }

    private fun detachFromCurrentActivity() {
        clearOwnedFlagSecure()
        if (Build.VERSION.SDK_INT >= 35) {
            unregisterScreenRecordingCallbackApi35()
        }
        osRecordingVisible = false
    }

    private fun syncFlagSecure() {
        val target = activity ?: return
        val shouldApplySecure =
            protectionEnabled && !suspendSecureWindow && !isOwnCaptureActive()
        if (shouldApplySecure) {
            if (addedFlagSecureToActivity === target) return
            clearOwnedFlagSecure()
            val existingFlags = target.window?.attributes?.flags ?: 0
            val alreadySecure = (existingFlags and WindowManager.LayoutParams.FLAG_SECURE) != 0
            if (!alreadySecure) {
                target.window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                addedFlagSecureToActivity = target
            }
        } else {
            clearOwnedFlagSecure()
        }
    }

    private fun clearOwnedFlagSecure() {
        val owned = addedFlagSecureToActivity ?: return
        addedFlagSecureToActivity = null
        try {
            owned.window?.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        } catch (_: Throwable) {}
    }

    @RequiresApi(35)
    private fun registerScreenRecordingCallbackApi35(target: Activity) {
        unregisterScreenRecordingCallbackApi35()
        val wm = target.windowManager ?: return
        val callback = Consumer<Int> { state ->
            runOnMain {
                if (!protectionEnabled) return@runOnMain
                osRecordingVisible = (state == WindowManager.SCREEN_RECORDING_STATE_VISIBLE)
                evaluateAndEmitIfNeeded()
            }
        }
        try {
            val initialState = wm.addScreenRecordingCallback(target.mainExecutor, callback)
            recordingCallbackConsumer = callback
            recordingCallbackWindowManager = wm
            osRecordingVisible = (initialState == WindowManager.SCREEN_RECORDING_STATE_VISIBLE)
        } catch (_: Throwable) {
            osRecordingVisible = false
        }
    }

    @RequiresApi(35)
    private fun unregisterScreenRecordingCallbackApi35() {
        val wm = recordingCallbackWindowManager
        val callback = recordingCallbackConsumer
        recordingCallbackWindowManager = null
        recordingCallbackConsumer = null
        if (wm != null && callback != null) {
            try {
                wm.removeScreenRecordingCallback(callback)
            } catch (_: Throwable) {}
        }
    }

    private fun startDisplayObserver() {
        if (displayListenerRegistered) return
        val dm = context.getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager ?: return
        dm.registerDisplayListener(displayListener, mainHandler)
        displayListenerRegistered = true
    }

    private fun stopDisplayObserver() {
        if (!displayListenerRegistered) return
        displayListenerRegistered = false
        val dm = context.getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager ?: return
        try {
            dm.unregisterDisplayListener(displayListener)
        } catch (_: Throwable) {}
    }

    private fun hasExternalMirrorOrPresentationDisplay(): Boolean {
        val dm = context.getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager
            ?: return false
        val presentationDisplays = dm.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION)
        if (presentationDisplays.any { isActiveExternalDisplay(it) }) {
            return true
        }
        return dm.displays.any { isActiveExternalDisplay(it) }
    }

    private fun isActiveExternalDisplay(display: Display): Boolean {
        if (display.displayId == Display.DEFAULT_DISPLAY) return false
        if (display.state == Display.STATE_OFF) return false
        if (display.name == AndroidSystemScreenCapture.VIRTUAL_DISPLAY_NAME) return false
        val flags = display.flags
        // Private app-owned virtual displays do not mirror the system screen.
        if ((flags and Display.FLAG_PRIVATE) != 0) return false
        return true
    }

    private fun computeExternalCaptured(): Boolean {
        if (isOwnCaptureActive()) return false
        return osRecordingVisible || hasExternalMirrorOrPresentationDisplay()
    }

    private fun evaluateAndEmitIfNeeded(forceEmitIfCaptured: Boolean = false) {
        if (!protectionEnabled) return
        val current = computeExternalCaptured()
        if (current != lastReportedCaptured) {
            lastReportedCaptured = current
            emit(current)
        } else if (forceEmitIfCaptured && current) {
            emit(true)
        }
    }

    private fun emit(captured: Boolean) {
        channel.invokeMethod("screenCaptureStateChanged", mapOf("captured" to captured))
    }

    private fun runOnMain(action: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            action()
        } else {
            mainHandler.post(action)
        }
    }
}

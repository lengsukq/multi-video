package com.oneplusdream.flutter_realtime_processed_video

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class FlutterRealtimeProcessedVideoPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware {
    private lateinit var channel: MethodChannel
    private lateinit var screenCaptureChannel: MethodChannel
    private lateinit var screenProtectionChannel: MethodChannel
    private lateinit var context: Context
    private var screenCapture: AndroidSystemScreenCapture? = null
    private var screenProtection: AndroidScreenCaptureProtection? = null
    private var activityBinding: ActivityPluginBinding? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "flutter_realtime_processed_video/sources")
        channel.setMethodCallHandler(this)

        screenCaptureChannel = MethodChannel(
            binding.binaryMessenger,
            "flutter_realtime_processed_video/android_system_screen_capture",
        )
        screenProtectionChannel = MethodChannel(
            binding.binaryMessenger,
            "flutter_realtime_processed_video/screen_capture_protection",
        )
        val capture = AndroidSystemScreenCapture(context, screenCaptureChannel) {
            screenProtection?.notifyOwnCaptureChanged()
        }
        val protection = AndroidScreenCaptureProtection(context, screenProtectionChannel) {
            screenCapture?.isCapturing == true
        }
        screenCapture = capture
        screenProtection = protection
        screenProtectionChannel.setMethodCallHandler(protection)
        screenCaptureChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "androidScreenCaptureAvailable" -> result.success(capture.isAvailable)
                "androidScreenCaptureStart" -> {
                    capture.start(result)
                    protection.notifyOwnCaptureChanged()
                }
                "androidScreenCaptureStop" -> {
                    capture.stop()
                    protection.notifyOwnCaptureChanged()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            val id = call.argument<String>("sourceId").orEmpty()
            when (call.method) {
                "setEnabled" -> {
                    ProcessedVideoSourceControls.setEnabled(id, call.argument<Boolean>("enabled") == true)
                    result.success(null)
                }
                "selectCamera" -> {
                    ProcessedVideoSourceControls.selectCamera(id, call.argument<String>("deviceId"))
                    result.success(null)
                }
                "listCameras" -> {
                    val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
                    val directions = manager.cameraIdList.map {
                        manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING)
                    }.toSet()
                    result.success(
                        listOfNotNull(
                            if (directions.contains(CameraCharacteristics.LENS_FACING_FRONT)) {
                                mapOf("id" to "front", "label" to "Front camera", "isFrontFacing" to true)
                            } else {
                                null
                            },
                            if (directions.contains(CameraCharacteristics.LENS_FACING_BACK)) {
                                mapOf("id" to "back", "label" to "Back camera", "isFrontFacing" to false)
                            } else {
                                null
                            },
                        ),
                    )
                }
                else -> result.notImplemented()
            }
        } catch (_: Throwable) {
            result.error("processed_source_failed", "processed.source.${call.method}", null)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        screenCaptureChannel.setMethodCallHandler(null)
        screenProtectionChannel.setMethodCallHandler(null)
        screenProtection?.dispose()
        screenProtection = null
        screenCapture?.stop()
        screenCapture = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        bindActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        unbindActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        bindActivity(binding)
    }

    override fun onDetachedFromActivity() {
        unbindActivity()
    }

    private fun bindActivity(binding: ActivityPluginBinding) {
        unbindActivity()
        activityBinding = binding
        screenCapture?.let { capture ->
            capture.setActivity(binding.activity)
            binding.addActivityResultListener(capture)
        }
        screenProtection?.setActivity(binding.activity)
    }

    private fun unbindActivity() {
        val currentBinding = activityBinding
        val capture = screenCapture
        if (currentBinding != null && capture != null) {
            currentBinding.removeActivityResultListener(capture)
        }
        capture?.setActivity(null)
        screenProtection?.setActivity(null)
        activityBinding = null
    }
}

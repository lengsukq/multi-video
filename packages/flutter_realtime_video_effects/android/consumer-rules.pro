# MediaPipe Tasks Vision uses Protobuf-lite reflection (NewMessageInfo) to
# look up generated proto fields (e.g. `platform_`) and JNI callbacks in
# R8-minified Release builds.
-keepclassmembers class * extends com.google.protobuf.GeneratedMessageLite {
    <fields>;
}
-keep class com.google.mediapipe.** { *; }
-dontwarn com.google.mediapipe.**

# MediaPipe's Graph static initializer uses Google Flogger
# (`FluentLogger.forEnclosingClass()`), which walks the stack by class name.
-keep class com.google.common.flogger.** { *; }
-dontwarn com.google.common.flogger.**

# Amazon IVS Broadcast SDK looks up Java classes and JNI helpers at runtime.
-keep class com.amazonaws.ivs.** { *; }
-keep class org.jni_zero.** { *; }
-dontwarn com.amazonaws.ivs.**
-dontwarn org.jni_zero.**

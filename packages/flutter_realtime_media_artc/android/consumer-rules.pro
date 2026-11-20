# Alibaba ARTC native SDK looks up Java classes by original name via JNI.
-keep class com.alivc.** { *; }
-keep class com.aliyun.** { *; }
-dontwarn com.alivc.**
-dontwarn com.aliyun.**

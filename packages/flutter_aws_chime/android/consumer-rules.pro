# Amazon Chime SDK native libraries invoke Java/Kotlin callbacks via JNI.
-keep class com.amazonaws.** { *; }
-keep class software.aws.chimesdk.** { *; }
-dontwarn com.amazonaws.**
-dontwarn software.aws.chimesdk.**

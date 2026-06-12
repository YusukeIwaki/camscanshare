# CamScanShare ProGuard Rules

# Room
-keep class * extends androidx.room.RoomDatabase
-keep @androidx.room.Entity class *

# ONNX Runtime's JNI layer constructs and inspects ai.onnxruntime classes by
# their original Java names. R8 can otherwise strip classes that are only
# referenced from native code, causing release-only crashes in OrtSession.run().
-keep class ai.onnxruntime.** { *; }
-keep class ai.onnxruntime.providers.** { *; }

# ── Flutter / embedding ────────────────────────────────────────────────────
# R8 cannot see these being called: the Flutter engine invokes them over JNI,
# and plugin registrants are looked up reflectively.
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

# Generated plugin registrant.
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }

# ── AndroidX ───────────────────────────────────────────────────────────────
-dontwarn androidx.**

# ── Play Core (deferred components) ─────────────────────────────────────────
# Flutter's engine ships code that references com.google.android.play.core.* for
# deferred components and split APKs. Those classes are only on the classpath
# when deferred components are enabled, which this app does not use, so R8 sees
# them as missing and fails the build. The references are never reached, so
# suppressing the warnings is correct rather than a workaround.
-dontwarn com.google.android.play.core.**

# ── Kotlin metadata ────────────────────────────────────────────────────────
# Kotlin reflection is used by coroutines and by several plugin implementations.
-keepattributes *Annotation*, InnerClasses, Signature, RuntimeVisible*Annotations

# ── Debug info ──────────────────────────────────────────────────────────────
# Keep line numbers so release crash reports remain actionable, while still
# obfuscating class and method names.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

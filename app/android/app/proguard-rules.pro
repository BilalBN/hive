# Release builds shrink and rename Kotlin code with R8. Some Flutter plugins
# (shared_preferences 2.5+) are called from Dart over JNI by method name, which
# R8 can't see, so it renames or removes those methods and the app fails at
# startup with NoSuchMethodError. Keep the plugin classes whole.
-keep class io.flutter.plugins.sharedpreferences.** { *; }

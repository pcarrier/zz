# Default ProGuard/R8 rules for the :app module.
# Minification is disabled for release in v1 (see app/build.gradle.kts), so this
# file is intentionally minimal. Add keep rules here if/when R8 is enabled.

# kotlinx.serialization: keep generated serializers for @Serializable classes.
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.**
-keepclassmembers class **$$serializer { *; }
-keepclasseswithmembers class kotlinx.serialization.json.** {
    kotlinx.serialization.KSerializer serializer(...);
}

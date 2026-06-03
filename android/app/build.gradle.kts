plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

android {
    namespace = "surf.zz"
    compileSdk = 35

    defaultConfig {
        applicationId = "surf.zz"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

dependencies {
    // Compose — pinned via the BOM (ANDROID_ARCH.md §2).
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    androidTestImplementation(composeBom)

    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.material3:material3-window-size-class")

    // Lifecycle / Activity.
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-process:2.8.7")
    // ViewModel + viewModel() composable helper for the self-contained Settings screen
    // (the only ViewModel in the app — see ANDROID_ARCH.md §3 and SettingsViewModel).
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")

    // Serialization.
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")

    // Coroutines.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    // DataStore (scalar prefs only).
    implementation("androidx.datastore:datastore-preferences:1.1.1")

    // Encrypted storage for HTTP-auth credentials (HttpAuthCredentialStore).
    // Replaces the iOS Keychain (SecItem*) with EncryptedSharedPreferences backed
    // by a hardware-backed (where available) master key from the Android Keystore.
    implementation("androidx.security:security-crypto:1.1.0-alpha06")

    // Images (favicons).
    implementation("io.coil-kt:coil-compose:2.7.0")

    // Compose tooling (debug-only).
    debugImplementation("androidx.compose.ui:ui-tooling")

    // Test.
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
}

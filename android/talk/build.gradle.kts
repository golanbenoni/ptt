plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
}

android {
    namespace = "app.ptt.talk"
    compileSdk = 36
    defaultConfig {
        applicationId = "app.ptt.talk"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.0.1"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }
    buildTypes {
        getByName("debug") { isMinifyEnabled = false }
        getByName("release") { isMinifyEnabled = false }
    }
    lint { abortOnError = false }
    sourceSets {
        getByName("main") {
            kotlin.srcDir(rootProject.projectDir.resolve("android/crypto/src/main/kotlin"))
            kotlin.srcDir(rootProject.projectDir.resolve("android/media/src/main/kotlin"))
            kotlin.srcDir(rootProject.projectDir.resolve("tools/net/src/main/kotlin"))
        }
    }
}

kotlin { jvmToolchain(17) }

dependencies {
    implementation(libs.libsignal.android)
    implementation(libs.kotlinx.coroutines.core)
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}

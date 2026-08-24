plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
}

val uploadStorePath = providers.environmentVariable("PTT_UPLOAD_STORE_FILE").orNull
val uploadStorePassword = providers.environmentVariable("PTT_UPLOAD_STORE_PASSWORD").orNull
val uploadKeyAlias = providers.environmentVariable("PTT_UPLOAD_KEY_ALIAS").orNull
val uploadKeyPassword = providers.environmentVariable("PTT_UPLOAD_KEY_PASSWORD").orNull
val hasUploadSigning =
    listOf(uploadStorePath, uploadStorePassword, uploadKeyAlias, uploadKeyPassword).all { it != null }

fun quotedBuildConfig(value: String): String =
    "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

android {
    namespace = "app.ptt.talk"
    compileSdk = 36
    buildFeatures { buildConfig = true }
    defaultConfig {
        applicationId = "app.ptt.talk"
        minSdk = 26
        targetSdk = 36
        versionCode = 4
        versionName = "0.1.3"
        buildConfigField("String", "FIREBASE_APPLICATION_ID", quotedBuildConfig(System.getenv("PTT_FIREBASE_APPLICATION_ID") ?: ""))
        buildConfigField("String", "FIREBASE_API_KEY", quotedBuildConfig(System.getenv("PTT_FIREBASE_API_KEY") ?: ""))
        buildConfigField("String", "FIREBASE_PROJECT_ID", quotedBuildConfig(System.getenv("PTT_FIREBASE_PROJECT_ID") ?: ""))
        buildConfigField("String", "FIREBASE_SENDER_ID", quotedBuildConfig(System.getenv("PTT_FIREBASE_SENDER_ID") ?: ""))
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64") }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }
    signingConfigs {
        if (hasUploadSigning) {
            create("upload") {
                storeFile = file(requireNotNull(uploadStorePath))
                storePassword = requireNotNull(uploadStorePassword)
                keyAlias = requireNotNull(uploadKeyAlias)
                keyPassword = requireNotNull(uploadKeyPassword)
            }
        }
    }
    buildTypes {
        getByName("debug") {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
            isMinifyEnabled = false
        }
        getByName("release") {
            isMinifyEnabled = false
            if (hasUploadSigning) {
                signingConfig = signingConfigs.getByName("upload")
            }
        }
    }
    lint {
        abortOnError = true
        checkReleaseBuilds = true
        lintConfig = file("lint.xml")
    }
    packaging {
        jniLibs {
            excludes += "**/libsignal_jni_testing.so"
        }
        resources {
            excludes += setOf(
                "**/*.dylib",
                "**/*.dll",
                "**/acknowledgments/libsignal-testing.md",
            )
        }
    }
}

kotlin { jvmToolchain(17) }

dependencies {
    implementation(project(":crypto"))
    implementation(project(":crypto-persistence"))
    implementation(project(":audio"))
    implementation(project(":media"))
    implementation(project(":floor"))
    implementation(project(":hardware"))
    implementation(libs.libsignal.android)
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.firebase.messaging)
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}

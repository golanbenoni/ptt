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

android {
    namespace = "app.ptt.talk"
    compileSdk = 36
    defaultConfig {
        applicationId = "app.ptt.talk"
        minSdk = 26
        targetSdk = 36
        versionCode = 4
        versionName = "0.1.3"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
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
        getByName("debug") { isMinifyEnabled = false }
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
    implementation(project(":crypto-persistence"))
    implementation(libs.libsignal.android)
    implementation(libs.kotlinx.coroutines.core)
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}

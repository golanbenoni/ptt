plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
}

android {
    namespace = "app.ptt.audio"
    compileSdk = 36
    defaultConfig { minSdk = 26 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin { jvmToolchain(17) }

val buildNativeCodec by tasks.registering(Exec::class) {
    group = "build"
    description = "Build the Rust/libopus JNI library for supported Android ABIs"
    commandLine(rootProject.projectDir.resolve("scripts/build-android-native.sh"))
    inputs.files(
        rootProject.fileTree("native/crates/audio-engine/src"),
        rootProject.fileTree("native/crates/android-jni/src"),
        rootProject.file("native/crates/audio-engine/Cargo.toml"),
        rootProject.file("native/crates/android-jni/Cargo.toml"),
        rootProject.file("native/Cargo.toml"),
        rootProject.file("native/Cargo.lock"),
    )
    listOf("arm64-v8a", "armeabi-v7a", "x86_64").forEach { abi ->
        outputs.file(project.file("src/main/jniLibs/$abi/libptt_media.so"))
    }
}

tasks.named("preBuild").configure { dependsOn(buildNativeCodec) }

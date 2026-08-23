plugins {
    alias(libs.plugins.kotlin.jvm)
}

kotlin {
    jvmToolchain(21)
}

dependencies {
    api(libs.libsignal.client)
    implementation(libs.kotlinx.coroutines.core)
    testImplementation(libs.junit.jupiter)
    testRuntimeOnly(libs.junit.platform.launcher)
    testImplementation(libs.kotlinx.coroutines.test)
}

tasks.jar {
    // Desktop natives must not ship in an Android AAR later (KD packaging).
    exclude("libsignal_jni*.dylib")
    exclude("signal_jni*.dll")
}

// Host JNI: published libsignal-client only embeds linux-amd64 + mac aarch64/amd64.
// On linux aarch64, tests load a locally built libsignal_jni.so (see scripts/build-libsignal-jni.sh).
val jniDir = file("${rootProject.projectDir}/native/jni")
tasks.test {
    val so = File(jniDir, "libsignal_jni.so")
    if (so.exists()) {
        jvmArgs("-Djava.library.path=${jniDir.absolutePath}")
    }
}

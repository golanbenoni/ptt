plugins {
    alias(libs.plugins.kotlin.jvm)
    application
}

kotlin { jvmToolchain(21) }

dependencies {
    implementation(project(":crypto"))
    implementation(project(":floor"))
    implementation(project(":media"))
    implementation(libs.kotlinx.coroutines.core)
    testImplementation(libs.junit.jupiter)
    testRuntimeOnly(libs.junit.platform.launcher)
}

application {
    mainClass.set("app.ptt.loopback.LoopbackMainKt")
}

val jniDir = file("${rootProject.projectDir}/native/jni")
fun org.gradle.api.tasks.JavaExec.applyJni() {
    val so = File(jniDir, "libsignal_jni.so")
    if (so.exists()) {
        jvmArgs("-Djava.library.path=${jniDir.absolutePath}")
    }
}

tasks.named<JavaExec>("run") { applyJni() }

tasks.register<JavaExec>("channelLoopback") {
    group = "application"
    classpath = sourceSets.main.get().runtimeClasspath
    mainClass.set("app.ptt.loopback.ChannelLoopbackKt")
    applyJni()
}

tasks.test {
    val so = File(jniDir, "libsignal_jni.so")
    if (so.exists()) {
        jvmArgs("-Djava.library.path=${jniDir.absolutePath}")
    }
    useJUnitPlatform()
}

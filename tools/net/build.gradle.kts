plugins {
    alias(libs.plugins.kotlin.jvm)
    application
}

kotlin { jvmToolchain(21) }

sourceSets {
    main {
        kotlin.srcDir("src/cli/kotlin")
    }
}

dependencies {
    implementation(project(":crypto"))
    implementation(project(":media"))
    implementation(libs.kotlinx.coroutines.core)
    testImplementation(libs.junit.jupiter)
    testRuntimeOnly(libs.junit.platform.launcher)
}

application {
    mainClass.set("app.ptt.net.MainKt")
}

val jniDir = file("${rootProject.projectDir}/native/jni")
fun org.gradle.api.tasks.JavaExec.applyJni() {
    val so = File(jniDir, "libsignal_jni.so")
    if (so.exists()) jvmArgs("-Djava.library.path=${jniDir.absolutePath}")
}

tasks.named<JavaExec>("run") { applyJni() }

tasks.test {
    val so = File(jniDir, "libsignal_jni.so")
    if (so.exists()) jvmArgs("-Djava.library.path=${jniDir.absolutePath}")
    useJUnitPlatform()
}

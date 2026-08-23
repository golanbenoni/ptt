plugins { alias(libs.plugins.kotlin.jvm) }
kotlin { jvmToolchain(21) }
dependencies {
    implementation(project(":crypto"))
    implementation(libs.kotlinx.coroutines.core)
    testImplementation(libs.junit.jupiter)
    testRuntimeOnly(libs.junit.platform.launcher)
    testImplementation(libs.kotlinx.coroutines.test)
}

plugins { alias(libs.plugins.kotlin.jvm) }
kotlin { jvmToolchain(21) }
dependencies {
    implementation(project(":crypto"))
    testImplementation(libs.junit.jupiter)
    testRuntimeOnly(libs.junit.platform.launcher)
}

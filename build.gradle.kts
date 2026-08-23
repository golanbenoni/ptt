plugins {
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.android.application) apply false
}

allprojects {
    group = "app.ptt"
    version = "0.0.1-SNAPSHOT"
}

subprojects {
    tasks.withType<Test> {
        useJUnitPlatform()
    }
}

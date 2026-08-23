plugins { alias(libs.plugins.kotlin.jvm) }
kotlin { jvmToolchain(21) }
dependencies {
    implementation(project(":crypto"))
    implementation(project(":session"))
    implementation(project(":audio"))
    implementation(project(":floor"))
    implementation(project(":media"))
    implementation(project(":control"))
    implementation(project(":hardware"))
}

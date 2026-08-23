pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
        google()
    }
}

plugins {
    id("org.gradle.toolchains.foojay-resolver-convention") version "0.10.0"
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        maven {
            name = "SignalBuildArtifacts"
            url = uri("https://build-artifacts.signal.org/libraries/maven/")
        }
        mavenCentral()
        google()
    }
}

rootProject.name = "ptt"

fun androidModule(name: String) {
    include(name)
    project(name).projectDir = file("android/${name.removePrefix(":")}")
}

androidModule(":crypto")
androidModule(":session")
androidModule(":audio")
androidModule(":floor")
androidModule(":media")
androidModule(":control")
androidModule(":hardware")
androidModule(":app")

include(":loopback")
project(":loopback").projectDir = file("tools/loopback")

include(":net")
project(":net").projectDir = file("tools/net")

val androidSdk =
    sequenceOf(
            System.getenv("ANDROID_HOME"),
            System.getenv("ANDROID_SDK_ROOT"),
            "${System.getProperty("user.home")}/Library/Android/sdk",
            "${System.getProperty("user.home")}/Android/Sdk",
        )
        .filterNotNull()
        .map { java.io.File(it) }
        .firstOrNull { it.resolve("platform-tools").isDirectory }
if (androidSdk != null) {
    include(":talkandroid")
    project(":talkandroid").projectDir = file("android/talk")
}


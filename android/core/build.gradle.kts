import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// The portable server logic: a Kotlin mirror of apple/Packages/RackoonCore. Pure Kotlin/JVM (no Android imports) so the
// same code runs in unit tests on the JVM, in the probe CLI and inside the app. `spec/` is the contract it must meet.
plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
}

dependencies {
    api(libs.kotlinx.serialization.json)
    api(libs.kotlinx.coroutines.core)
    testImplementation(kotlin("test"))
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.junit.jupiter)
    testRuntimeOnly(libs.junit.platform.launcher)
}

// The shell commands themselves live only in spec/commands.json (the language-neutral contract). They ship inside this
// module as a resource, so there is no second copy in Kotlin that could drift.
tasks.processResources {
    from(rootProject.projectDir.parentFile.resolve("spec")) {
        include("commands.json", "command-library.json", "attention-rules.json", "security-checks.json", "config-transfer.json")
        into("spec")
    }
}

// The terminal themes stay where the Mac app bundles them (SwiftPM cannot copy files from outside its target), and are
// shared from there, so there is still only one themes.json.
tasks.processResources {
    from(rootProject.projectDir.parentFile.resolve("apple/Apps/RackoonMac/Resources")) {
        include("themes.json")
        into("spec")
    }
}

tasks.test {
    useJUnitPlatform()
    // Tests read the language-neutral contract directly: spec/commands.json and spec/fixtures/**.
    systemProperty("rackoon.spec", rootProject.projectDir.parentFile.resolve("spec").path)
    testLogging { events("failed"); exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL }
}

import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// SSH for Android and the probe: sshj behind core's SSHTransport. Pure JVM (no Android imports) so the app and the probe CLI
// both use it. The one Android-specific step (swapping the platform's cut-down BouncyCastle) is `SshProviders.install()`.
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
    api(project(":core"))
    api(libs.sshj)
    api(libs.bouncycastle.prov)
    api(libs.bouncycastle.pkix)
    implementation(libs.slf4j.api)
    runtimeOnly(libs.slf4j.nop)
    testImplementation(kotlin("test"))
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.junit.jupiter)
    testRuntimeOnly(libs.junit.platform.launcher)
}

tasks.test {
    useJUnitPlatform()
    // Tests that need a real server only run when RACKOON_SSH_HOST is set (never in CI).
    environment("RACKOON_SSH_HOST", System.getenv("RACKOON_SSH_HOST") ?: "")
    // The integration lab (tools/lab up; eval "$(tools/lab env)"). Without it LabIntegrationTests skip themselves.
    for (name in listOf("RACKOON_LAB", "RACKOON_LAB_HOST", "RACKOON_LAB_PORT", "RACKOON_LAB_USER", "RACKOON_LAB_KEY", "RACKOON_LAB_KNOWN_HOSTS")) {
        environment(name, System.getenv(name) ?: "")
    }
    systemProperty("rackoon.spec", rootProject.projectDir.parentFile.resolve("spec").path)
    inputs.dir(rootProject.projectDir.parentFile.resolve("spec")).withPropertyName("spec")
    testLogging { events("failed"); exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL }
}

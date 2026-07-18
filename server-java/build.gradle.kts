// Java port of the baby monitor server (docs/PROTOCOL.md): WS signaling on /ws + REST on /api.
plugins {
    java
    application
}

group = "com.babymonitor"
version = "0.1.0"

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

repositories {
    mavenCentral()
}

dependencies {
    implementation("io.javalin:javalin:6.7.0")               // HTTP + WebSocket (embedded Jetty)
    implementation("com.fasterxml.jackson.core:jackson-databind:2.17.2")
    implementation("org.xerial:sqlite-jdbc:3.46.1.3")
    implementation("org.slf4j:slf4j-simple:2.0.16")

    testImplementation(platform("org.junit:junit-bom:5.10.2"))
    testImplementation("org.junit.jupiter:junit-jupiter")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

application {
    mainClass.set("com.babymonitor.Main")
}

tasks.test {
    useJUnitPlatform()
    testLogging {
        events("passed", "failed", "skipped")
    }
}

// Self-contained runnable jar: build/libs/babymonitor-server-<version>-all.jar
val fatJar = tasks.register<Jar>("fatJar") {
    group = "build"
    description = "Builds a self-contained runnable jar."
    archiveClassifier.set("all")
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE
    manifest {
        attributes["Main-Class"] = "com.babymonitor.Main"
        attributes["Multi-Release"] = "true"
    }
    from(sourceSets.main.get().output)
    dependsOn(configurations.runtimeClasspath)
    from(configurations.runtimeClasspath.get().map { if (it.isDirectory) it else zipTree(it) }) {
        exclude("META-INF/*.SF", "META-INF/*.DSA", "META-INF/*.RSA", "module-info.class")
    }
}

tasks.assemble {
    dependsOn(fatJar)
}

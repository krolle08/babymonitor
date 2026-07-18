# Multi-stage build: Gradle + JDK 17 to build, slim JRE 17 to run.
FROM gradle:8-jdk17 AS build
WORKDIR /app
COPY settings.gradle.kts build.gradle.kts ./
COPY src ./src
RUN gradle --no-daemon fatJar

FROM eclipse-temurin:17-jre-alpine
WORKDIR /app
COPY --from=build /app/build/libs/*-all.jar app.jar
ENV PORT=8080
EXPOSE 8080
# Cap the heap relative to the container limit so the JVM behaves in a small VM.
CMD ["java", "-XX:MaxRAMPercentage=75.0", "-jar", "app.jar"]

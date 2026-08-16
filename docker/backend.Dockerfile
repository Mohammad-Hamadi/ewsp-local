FROM eclipse-temurin:21-jdk-jammy AS builder

WORKDIR /workspace

COPY .mvn/ .mvn/
COPY mvnw pom.xml ./
RUN sed -i 's/\r$//' mvnw \
    && chmod +x mvnw \
    && ./mvnw -B -ntp -DskipTests dependency:go-offline

COPY src/ src/
RUN ./mvnw -B -ntp clean package -DskipTests

FROM eclipse-temurin:21-jre-jammy AS runtime

RUN command -v curl >/dev/null \
    && groupadd --system ewsp \
    && useradd --system --gid ewsp --no-create-home --home-dir /app ewsp

WORKDIR /app
COPY --from=builder --chown=ewsp:ewsp /workspace/target/ewsp-backend-0.0.1-SNAPSHOT.jar application.jar

USER ewsp
EXPOSE 8080

ENTRYPOINT ["java", "-jar", "/app/application.jar"]

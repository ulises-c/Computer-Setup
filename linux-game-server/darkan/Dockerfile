# syntax=docker/dockerfile:1
ARG JDK_IMAGE=eclipse-temurin:26-jdk-noble
ARG JRE_IMAGE=eclipse-temurin:26-jre-noble

FROM ${JDK_IMAGE} AS build
WORKDIR /src
# Only the build inputs: the cache-source submodule is several GB and the
# build reads just its gamevals/ catalogs (core/build.gradle.kts).
COPY --from=darkan_src gradlew settings.gradle.kts build.gradle.kts gradle.properties ./
COPY --from=darkan_src gradle gradle
COPY --from=darkan_src buildSrc buildSrc
COPY --from=darkan_src core core
COPY --from=darkan_src cs2 cs2
COPY --from=darkan_src lobby lobby
COPY --from=darkan_src world world
COPY --from=darkan_src tools tools
COPY --from=darkan_src migration migration
COPY --from=darkan_src plugins plugins
COPY --from=darkan_src data data
COPY --from=darkan_src cache-source/gamevals cache-source/gamevals
# Host networking would otherwise put the admin API on every interface,
# tailscale0 included (Tailscale's netfilter rules accept tailnet traffic
# ahead of UFW). Only the world, on loopback, needs it.
RUN f=lobby/src/main/kotlin/org/darkan/lobby/Lobby.kt \
    && grep -qF 'embeddedServer(Netty, port = EnvVars.lobbyApiPort,' "$f" \
    || { printf 'error: lobby API bind patch no longer matches upstream %s\n' "$f" >&2; exit 1; }; \
    sed -i 's/embeddedServer(Netty, port = EnvVars.lobbyApiPort,/embeddedServer(Netty, host = "127.0.0.1", port = EnvVars.lobbyApiPort,/' "$f"
RUN --mount=type=cache,target=/root/.gradle \
    ./gradlew --no-daemon --console=plain :lobby:shadowJar :world:shadowJar \
    && cp lobby/build/libs/lobby-server-*.jar /lobby-server.jar \
    && cp world/build/libs/world-server-*.jar /world-server.jar

FROM ${JRE_IMAGE}
ARG DARKAN_SOURCE_COMMIT=unknown
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/darkan
COPY --from=build /lobby-server.jar /world-server.jar ./
COPY --from=darkan_src data data
COPY --from=darkan_src plugins plugins
COPY entrypoint.sh /usr/local/bin/darkan-entrypoint
# The one file the world persists under data/ (WorldPersistentData) is
# redirected into the state mount; the rest of data/ is read-only content.
RUN chmod 0755 /usr/local/bin/darkan-entrypoint \
    && ln -sfn /state/world.json data/world.json \
    && chmod -R a+rX /opt/darkan
LABEL org.opencontainers.image.source="https://gitlab.com/darkanrs/server" \
      org.opencontainers.image.revision="${DARKAN_SOURCE_COMMIT}"
ENV CHECKOUT_COMMIT=${DARKAN_SOURCE_COMMIT} \
    BUILD_VERSION=${DARKAN_SOURCE_COMMIT} \
    AUTO_UPDATE=false
ENTRYPOINT ["/usr/local/bin/darkan-entrypoint"]

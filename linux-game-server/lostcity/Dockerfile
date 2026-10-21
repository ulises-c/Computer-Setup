FROM oven/bun:debian AS bun-runtime

FROM node:24-bookworm-slim

COPY --from=bun-runtime /usr/local/bin/bun /usr/local/bin/bun

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/server
USER 1000:1000

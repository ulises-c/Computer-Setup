ARG RS_SDK_BASE_IMAGE=rs_sdk_upstream
FROM ${RS_SDK_BASE_IMAGE}

COPY restore-xp.js /usr/local/lib/restore-xp.js
RUN bun /usr/local/lib/restore-xp.js /opt \
    && cd /opt/server/webclient \
    && bun run build

WORKDIR /opt/server

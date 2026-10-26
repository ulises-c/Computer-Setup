ARG RS_SDK_BASE_IMAGE=rs_sdk_upstream
FROM ${RS_SDK_BASE_IMAGE}

COPY restore-xp.js /usr/local/lib/restore-xp.js
COPY restore-client.js /usr/local/lib/restore-client.js
COPY hiscore-pages.js /usr/local/lib/hiscore-pages.js
COPY hiscore-prune.js /usr/local/lib/hiscore-prune.js
RUN bun /usr/local/lib/restore-xp.js /opt \
    && bun /usr/local/lib/restore-client.js /opt \
    && bun /usr/local/lib/hiscore-pages.js /opt \
    && bun /usr/local/lib/hiscore-prune.js /opt \
    && cd /opt/server/webclient \
    && bun run build

WORKDIR /opt/server

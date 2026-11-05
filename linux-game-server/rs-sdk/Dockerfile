ARG RS_SDK_BASE_IMAGE=rs_sdk_upstream
FROM ${RS_SDK_BASE_IMAGE}

COPY clan-storage.patch /usr/local/lib/clan-storage.patch
COPY restore-xp.js /usr/local/lib/restore-xp.js
COPY restore-client.js /usr/local/lib/restore-client.js
COPY hiscore-pages.js /usr/local/lib/hiscore-pages.js
COPY hiscore-prune.js /usr/local/lib/hiscore-prune.js
COPY hop-timer-utc.js /usr/local/lib/hop-timer-utc.js
# Clans + clan storage + clan hiscores (fork branch feat/clan-storage, off unless
# CLAN_STORAGE_ENABLED / CLAN_HISCORES_ENABLED). Applied first, so the patch scripts
# below run on the patched tree. An image that already carries it (a later build on
# top of world 1's image) is detected by the reverse check; anything else that does
# not apply fails the build: never drop the patch silently.
RUN cd /opt \
    && if git apply --reverse --check /usr/local/lib/clan-storage.patch 2>/dev/null; then \
         echo "clan-storage.patch already applied"; \
       else \
         git apply --verbose /usr/local/lib/clan-storage.patch; \
       fi \
    && bun /usr/local/lib/restore-xp.js /opt \
    && bun /usr/local/lib/restore-client.js /opt \
    && bun /usr/local/lib/hiscore-pages.js /opt \
    && bun /usr/local/lib/hiscore-prune.js /opt \
    && bun /usr/local/lib/hop-timer-utc.js /opt \
    && cd /opt/server/engine \
    && BUILD_VERIFY=false bun run build \
    && cd /opt/server/webclient \
    && bun run build

WORKDIR /opt/server

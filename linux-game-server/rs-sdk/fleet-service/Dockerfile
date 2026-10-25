# Fleet service: one bundled file built from the bot repo (2004Scape-Botting fleet-service/,
# scripts/fleet-service-bundle.sh). Pinned by digest: the same bun as the bot hosts (1.4.3).
FROM oven/bun:debian@sha256:ec06c3b6cea04192ae6770c434f668ca41d343ad19fa6472216c7b48be39c598
WORKDIR /app
COPY fleet-service.js /app/fleet-service.js
ENV FLEET_DB=/data/fleet.sqlite FLEET_PORT=8100 FLEET_BIND=0.0.0.0
EXPOSE 8100
CMD ["bun", "/app/fleet-service.js"]

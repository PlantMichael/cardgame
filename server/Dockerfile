# Relay + Godot match host (specs/003-authoritative-ranked-server, T005).
# NOT BUILT YET: Docker was not available where this was written. Verify the
# build, image size and cold start (research.md §7) before relying on it.
FROM node:20-bookworm-slim

ARG GODOT_VERSION=4.7.2-stable
ENV GODOT_BIN=/usr/local/bin/godot

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl unzip \
    libfontconfig1 libgl1 libx11-6 libxcursor1 libxinerama1 libxrandr1 libxi6 \
 && rm -rf /var/lib/apt/lists/*

# Pinned Godot Linux headless-capable editor binary (same version the project is authored in).
RUN curl -fsSL -o /tmp/godot.zip \
      "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_linux.x86_64.zip" \
 && unzip -q /tmp/godot.zip -d /tmp \
 && mv /tmp/Godot_v${GODOT_VERSION}_linux.x86_64 ${GODOT_BIN} \
 && chmod +x ${GODOT_BIN} && rm /tmp/godot.zip

WORKDIR /app
COPY server/package.json server/package-lock.json ./server/
RUN cd server && npm ci --omit=dev

# Rules-only project subset: scripts, data and the minimum assets the scripts preload.
COPY project.godot icon.svg ./
COPY scripts ./scripts
COPY data ./data
COPY assets ./assets
COPY scenes ./scenes
COPY server ./server

# Import once at build time so resource references resolve headlessly.
RUN ${GODOT_BIN} --headless --path /app --import || true

ENV PROJECT_DIR=/app
WORKDIR /app/server
CMD ["node", "relay.js"]

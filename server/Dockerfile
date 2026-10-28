# Relay + Godot match host (specs/003-authoritative-ranked-server, T005).
#
# Built and exercised: 1.3 GB, ~3.5 s from process start to a match host ready
# for commands, and the whole server suite (42 tests) passes inside the image.
# Numbers and the remaining size levers are in research.md §7.
FROM node:20-bookworm-slim

ARG GODOT_VERSION=4.7.2-stable
ENV GODOT_BIN=/usr/local/bin/godot

# curl/unzip fetch Godot below. No X or GL libraries: the headless binary runs
# without them, and installing them cost 300 MB (measured — the suite passes
# either way), so do not add them back without checking that they are needed.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl unzip \
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
COPY catalog/public/data ./catalog/public/data

# Import once at build time so resource references resolve headlessly.
RUN ${GODOT_BIN} --headless --path /app --import || true

ENV PROJECT_DIR=/app
WORKDIR /app/server
CMD ["node", "relay.js"]

# syntax=docker/dockerfile:1
ARG OPENCLAW_EXTENSIONS=""
ARG OPENCLAW_VARIANT=default
ARG OPENCLAW_BUNDLED_PLUGIN_DIR=extensions
ARG OPENCLAW_DOCKER_APT_UPGRADE=1
ARG OPENCLAW_NODE_BOOKWORM_IMAGE="node:24-bookworm"

# ── Stage 1: Extension Dependencies ──────────────────────────────
FROM ${OPENCLAW_NODE_BOOKWORM_IMAGE} AS ext-deps
ARG OPENCLAW_EXTENSIONS
ARG OPENCLAW_BUNDLED_PLUGIN_DIR
COPY ${OPENCLAW_BUNDLED_PLUGIN_DIR} /tmp/${OPENCLAW_BUNDLED_PLUGIN_DIR}
RUN mkdir -p /out && \
    for ext in $OPENCLAW_EXTENSIONS; do \
      if [ -f "/tmp/${OPENCLAW_BUNDLED_PLUGIN_DIR}/$ext/package.json" ]; then \
        mkdir -p "/out/$ext" && \
        cp "/tmp/${OPENCLAW_BUNDLED_PLUGIN_DIR}/$ext/package.json" "/out/$ext/package.json"; \
      fi; \
    done

# ── Stage 2: Build ──────────────────────────────────────────────
FROM ${OPENCLAW_NODE_BOOKWORM_IMAGE} AS build
ARG OPENCLAW_BUNDLED_PLUGIN_DIR

# Install Bun
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable
WORKDIR /app

# Copy manifests
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY openclaw.mjs ./
COPY ui/package.json ./ui/package.json
COPY patches ./patches
COPY scripts/postinstall-bundled-plugins.mjs scripts/npm-runner.mjs scripts/windows-cmd-helpers.mjs ./scripts/
COPY --from=ext-deps /out/ ./${OPENCLAW_BUNDLED_PLUGIN_DIR}/

# REMOVED CACHE MOUNTS TO PREVENT RAILWAY BUILD ERRORS
RUN NODE_OPTIONS=--max-old-space-size=2048 pnpm install --frozen-lockfile

COPY . .

RUN for dir in /app/${OPENCLAW_BUNDLED_PLUGIN_DIR} /app/.agent /app/.agents; do \
      if [ -d "$dir" ]; then \
        find "$dir" -type d -exec chmod 755 {} +; \
        find "$dir" -type f -exec chmod 644 {} +; \
      fi; \
    done

RUN pnpm build:docker
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:build
RUN pnpm qa:lab:build

# ── Stage 3: Runtime ────────────────────────────────────────────
FROM ${OPENCLAW_NODE_BOOKWORM_IMAGE}
WORKDIR /app

# Standard Apt Install (No Cache Mounts)
RUN apt-get update && \
    apt-get upgrade -y --no-install-recommends && \
    apt-get install -y --no-install-recommends procps hostname curl git lsof openssl

# Ensure /data exists for volume mounting
RUN mkdir -p /data/state /data/workspace && chown -R node:node /app /data

COPY --from=build --chown=node:node /app/dist ./dist
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/package.json .
COPY --from=build --chown=node:node /app/openclaw.mjs .
COPY --from=build --chown=node:node /app/extensions ./extensions
COPY --from=build --chown=node:node /app/skills ./skills

RUN corepack enable && \
    corepack prepare pnpm@latest --activate

ENV NODE_ENV=production
ENV STATE_DIR=/data/state
ENV WORKSPACE_DIR=/data/workspace

# Railway volumes are often root-owned; this helps avoid permission trash
USER root
RUN chmod -R 777 /data

USER node
EXPOSE 18789

CMD ["node", "openclaw.mjs", "gateway", "--allow-unconfigured", "--bind", "lan", "--port", "18789", "--controlUi.allowedOrigins", "*"]

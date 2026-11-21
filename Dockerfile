# syntax=docker/dockerfile:1.7

# build.sh appends "@sha256:..." when a digest is configured.
ARG NODE_IMAGE=node:24-trixie
ARG RUNTIME_IMAGE=node:24-trixie-slim

FROM ${NODE_IMAGE} AS deps

ARG DSH_VERSION
RUN test -n "${DSH_VERSION}" || (echo "DSH_VERSION build arg is required" >&2; exit 1)

RUN apt-get update \
 && apt-get install --yes --no-install-recommends python3 make g++ \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json package-lock.json ./

# Explicit lifecycle-script allowlist: install without scripts, then rebuild
# only the known native packages.
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund \
 && npm rebuild --foreground-scripts \
      node-pty \
      koffi \
      @deepseek-ai/dsh-subprocess-local \
      @google/genai \
      protobufjs \
 && test "$(/app/node_modules/.bin/dsh --version)" = "${DSH_VERSION}"

FROM ${RUNTIME_IMAGE}

ARG PNPM_VERSION=12.21.0

RUN apt-get update \
 && apt-get install --yes --no-install-recommends \
      ca-certificates \
      docker-buildx \
      docker-cli \
      gh \
      git \
      openssh-client \
      ripgrep \
      tini \
      procps \
 && rm -rf /var/lib/apt/lists/*

RUN npm install --global --ignore-scripts --no-audit --no-fund "pnpm@${PNPM_VERSION}" \
 && pnpm --version >/dev/null

WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY bridge ./bridge

# NODE_ENV is deliberately not set: agent-run commands inherit this
# environment, and NODE_ENV=production would change their install behaviour.
# The root filesystem is read-only, so CLI tools keep their config, caches and
# state in the writable DSH home volume.
ENV HOME=/home/node \
    DSH_HOME=/home/node/.dsh \
    DOCKER_CONFIG=/home/node/.dsh/.docker \
    XDG_CONFIG_HOME=/home/node/.dsh/.config \
    XDG_DATA_HOME=/home/node/.dsh/.local/share \
    XDG_CACHE_HOME=/home/node/.dsh/.cache \
    PNPM_HOME=/home/node/.dsh/pnpm \
    GIT_CONFIG_GLOBAL=/home/node/.dsh/.gitconfig \
    PATH=/home/node/.dsh/pnpm:$PATH \
    DSH_BIN=/app/node_modules/.bin/dsh \
    DSH_CWD=/workspace \
    DSH_TELEMETRY_MODE=DISABLED \
    NARB_DISABLE_NATIVE_CACHE=1 \
    DSH_CONTAINER=1 \
    HTTP_BIND=0.0.0.0 \
    HTTP_PORT=3080 \
    WEB_BIND=0.0.0.0 \
    WEB_PORT=8080 \
    WEB_INTERNAL_HOST=127.0.0.1 \
    WEB_INTERNAL_PORT=8081

# Chown only the writable directories. node_modules is world-readable and the
# bridge never writes to /app; a recursive chown of /app is needlessly slow.
RUN mkdir -p /home/node/.dsh/.docker /home/node/.dsh/.config \
      /home/node/.dsh/.local/share /home/node/.dsh/.cache /home/node/.dsh/pnpm /workspace \
 && chown -R node:node /home/node/.dsh /workspace

USER node
WORKDIR /workspace
EXPOSE 3080 8080

ARG DSH_VERSION
ARG IMAGE_VERSION=dev
ARG IMAGE_REVISION=unknown
LABEL org.opencontainers.image.title="DSH API Runtime" \
      org.opencontainers.image.description="Unauthenticated HTTP/JSON-RPC gateway for the DeepSeek Harness SDK runtime" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${IMAGE_REVISION}" \
      io.example.dsh.version="${DSH_VERSION}"

HEALTHCHECK --interval=30s --timeout=3s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.HTTP_PORT||3080)+'/readyz').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"

ENTRYPOINT ["/usr/bin/tini", "--", "node", "/app/bridge/supervisor.mjs"]

# syntax=docker/dockerfile:1
#
# DeepSeek Harness (DSH) Web, with a reverse proxy that makes it reachable from
# outside the container.
#
# ---------------------------------------------------------------------------
# Why two stages
# ---------------------------------------------------------------------------
# `@deepseek-ai/dsh` depends on node-pty, which ships prebuilt binaries only for
# macOS and Windows. On Linux npm therefore falls back to node-gyp and compiles
# from source, which needs python3 + make + g++. node:24-slim ships none of
# them, so a single-stage build fails with "gyp ERR! find Python".
#
# The builder stage installs and compiles; the runtime stage copies only
# /usr/local (Node, DSH, and the compiled addon) and never carries a compiler.
#
# Node 24 is the runtime upstream verifies against.
# ---------------------------------------------------------------------------

ARG NODE_IMAGE=node:24-slim
# Pinned, never `@latest`: a floating tag makes builds unreproducible and can
# silently move the image to an unreviewed release. CI resolves and overrides it.
ARG DSH_VERSION=0.2.1-rc.2

# ── Stage 1: install DSH and compile native modules ────────────────────────
FROM ${NODE_IMAGE} AS dsh-builder

ARG DSH_VERSION

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 make g++ \
    && rm -rf /var/lib/apt/lists/*

# Fail loudly if the version does not exist rather than building something
# unexpected. --omit=dev keeps npm's own dev deps out of the image.
RUN npm install -g --no-audit --no-fund "@deepseek-ai/dsh@${DSH_VERSION}" \
    && dsh --version

# Report the resolved version so CI can tag the image with it.
RUN node -p "'APP_VERSION=' + require('/usr/local/lib/node_modules/@deepseek-ai/dsh/package.json').version" \
    > /tmp/app_version.env

# pnpm is installed here (compiled stage, npm cache discarded) rather than in
# the runtime stage, so the final image carries the binary but not the cache.
RUN npm install -g --no-audit --no-fund pnpm

# ── Stage 2: runtime ──────────────────────────────────────────────────────
FROM ${NODE_IMAGE}

ARG DSH_VERSION

LABEL org.opencontainers.image.title="dsh-web" \
      org.opencontainers.image.description="DeepSeek Harness Web with loopback bypass proxy"

# Node 24, DSH, compiled node-pty, and pnpm all live under /usr/local.
COPY --from=dsh-builder /usr/local/ /usr/local/
COPY --from=dsh-builder /tmp/app_version.env /etc/dsh-version

# Tool set: enough to work inside the container, including compiling native
# modules at runtime (npm install of a package with a node-gyp addon, pip
# build, etc.). python3/make/g++ therefore live in the runtime stage too, not
# only in the builder -- the cost is image size, the benefit is that a user can
# actually build inside the container.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        git \
        jq \
        nano \
        procps \
        python3 \
        unzip \
        wget \
    && rm -rf /var/lib/apt/lists/* \
    && git --version \
    && jq --version \
    && python3 --version \
    && make --version | head -1 \
    && g++ --version | head -1

# uv for Python tooling (MCP servers launch via `uvx`/`uv run`).
RUN curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR=/usr/local/bin sh \
    && uv --version

ENV HOME=/root \
    DSH_PORT=3079 \
    PROXY_PORT=3080 \
    PROXY_BIND=0.0.0.0 \
    DSH_WEB_LOG=/root/.dsh-web.log \
    DSH_TELEMETRY_DISABLED=1

# DSH runs from /root as root, by request. /root/.dsh holds profiles, settings
# and sessions, and is the path worth persisting as a volume.
WORKDIR /root
RUN mkdir -p /root/.dsh

# Proxy dependencies. http-proxy is the only runtime dependency; the build then
# syntax-checks each module so a typo fails the image build rather than the
# container start.
COPY proxy/ /app/proxy/
RUN cd /app/proxy && npm install --omit=dev --no-audit --no-fund \
    && node --check index.js \
    && node --check compression.js \
    && node --check upstream-token.js

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh && sh -n /app/entrypoint.sh

# Only the proxy port is published. DSH itself stays on 127.0.0.1:3079 inside
# the container and is deliberately not exposed.
EXPOSE 3080

# Healthy means "this container can serve end to end": the proxy is listening
# AND upstream DSH is answering. Checking only the proxy was a trap -- the proxy
# answers 502 forever once DSH dies, so the container stayed "healthy" while the
# UI was unreachable. Probing DSH's own port makes that state unhealthy, and the
# restart policy then brings the container back.
#
# DSH may answer 401 (browser auth in play) or 3xx; any answer means it is up.
# A refused connection means it is not running: exit 1.
HEALTHCHECK --interval=15s --timeout=5s --start-period=60s --retries=4 \
    CMD node -e '\
      const port = process.env.DSH_PORT || 3079; \
      fetch("http://127.0.0.1:" + port + "/", { redirect: "manual" }) \
        .then(() => process.exit(0)) \
        .catch(() => { \
          console.error("upstream dsh is not answering on 127.0.0.1:" + port); \
          process.exit(1); \
        });'

STOPSIGNAL SIGTERM
ENTRYPOINT ["/app/entrypoint.sh"]

# dsh-web

Docker image for **[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (DSH) Web**, packaged so it can actually be reached from outside the container.

DSH is excellent, but it deliberately refuses to listen on `0.0.0.0`. This image keeps that security property intact and puts a small reverse proxy in front as the single inbound door.

Based on [smanx/deepseek-harness-docker](https://github.com/smanx/deepseek-harness-docker) and the build conventions of [okxlin/release-factory](https://github.com/okxlin/release-factory).

---

## Why a proxy is required

DSH blocks a wildcard bind in **two independent places**, and the second one is why patching is not an option:

| Layer | Source | Behaviour |
|---|---|---|
| CLI flag | `packages/bundle/web-app/src/startup.ts:95-97` | `--host 0.0.0.0` → `error: ... is an unspecified (wildcard) address` |
| Plugin config | `packages/host/webserver/src/index.ts:360-364` | schema validation throws at load |

Patching the CLI would still hit the schema rejection. Upstream's reasoning is sound: the web UI can execute code inside the container, so binding every interface would expose remote code execution to the whole network, unauthenticated.

So DSH stays on `127.0.0.1:3079` inside the container, and this image adds a proxy on `0.0.0.0:3080`:

```
browser ──▶ proxy 0.0.0.0:3080 ──▶ dsh web 127.0.0.1:3079
             │  Basic Auth
             │  Host/Origin passed through unchanged
             │  decompress → shim → recompress
             └─ root 401 → retry with ?token=<scraped from dsh log>
```

The proxy is not a transparent pipe. Three things it has to do correctly:

1. **Keep `Host` and `Origin` untouched.** DSH's `/api` fence (`packages/client/connection/src/api-request-trust.ts:121-176`) compares `Origin` against `Host` — not against the upstream address — so rewriting either one breaks every API call with a 403.
2. **Mint a session per authority.** The session cookie's name is a hash of `host:port` (`browser-auth.ts:116`) and the payload must carry a matching authority. A session created at `127.0.0.1:3080` is not valid at `192.168.1.5:3080`. The proxy trades DSH's launch token for a fresh cookie when the root request returns 401.
3. **Shim two browser APIs.** `crypto.randomUUID` does not exist outside secure contexts, and reaching the UI over a LAN IP is not a secure context — without the shim the realtime channel hangs forever. `isLoopbackHostname` is forced true so settings and plugin panels are not hidden.

## Quick start

### Docker

```bash
docker run -d \
  --name dsh-web \
  -p 3080:3080 \
  -e PROXY_USERNAME=admin \
  -e PROXY_PASSWORD='change-me' \
  -v dsh-data:/root/.dsh \
  --restart unless-stopped \
  ghcr.io/6zev/dsh-web-docker:dsh-0.2.2-rc.5
```

Open <http://localhost:3080> and log in with the credentials above.

### Docker Compose

```bash
cp .env.example .env   # then edit it
docker compose up -d
```

### Build it yourself

```bash
docker build -t dsh-web:local --build-arg DSH_VERSION=0.2.2-rc.5 .
./scripts/smoke-test.sh IMAGE=dsh-web:local
```

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `PROXY_USERNAME` | *(empty)* | Basic Auth user. Auth is enabled only when **both** user and password are set. |
| `PROXY_PASSWORD` | *(empty)* | Basic Auth password. |
| `PROXY_PORT` | `3080` | Port the proxy listens on inside the container. |
| `PROXY_BIND` | `0.0.0.0` | Interface the proxy binds. |
| `DSH_PORT` | `3079` | Port DSH listens on, loopback only inside the container. Must differ from `PROXY_PORT`. |
| `DSH_TRUSTED_HOSTS` | *(empty)* | Comma-separated authorities this deployment is reached at, e.g. `app.example.com` or `app.example.com:8443`. A scheme prefix (`https://…`) is stripped with a warning, since `Host` has no scheme. When set, the proxy refuses any other Host with `421`, on every path. **Required whenever you reach the UI through a hostname** — see below. |
| `DSH_PUBLIC_URL` | *(derived)* | Advertised browser-facing root, e.g. `https://app.example.com/`. Passed to dsh as `--public-url`. **Required behind any reverse proxy (Cloudflare, Traefik, nginx)** — without it dsh advertises its loopback URL and the browser-side channel tries to reach `127.0.0.1` from your machine, so the UI reconnects forever. When empty it is derived as `https://<first DSH_TRUSTED_HOSTS entry>/`; set it explicitly for http, a non-standard port, or a mount prefix. Its authority is also added to `--trusted-host` automatically. `--public-url` only advertises; it grants no trust. |
| `PROXY_WS_PING_INTERVAL_MS` | `30000` | Downstream WebSocket ping, in ms. Cloudflare (~100s) and Traefik/nginx (~60s) reap an idle realtime channel, so the proxy sends a WS ping to the browser every interval to keep the channel alive. `0` disables it. This is *not* what fixes the continuous reconnect — see `PROXY_WS_UPSTREAM_PONG_INTERVAL_MS`. |
| `PROXY_WS_UPSTREAM_PONG_INTERVAL_MS` | `1500` | Upstream WebSocket pong, in ms. dsh's realtime server pings every 2s and kills the socket after 2 missed pongs, so an idle UI behind Cloudflare reconnects every ~6s. The proxy answers that heartbeat itself with a masked pong to dsh every interval, so dsh never sees a missed heartbeat. Must stay well under 4000ms. `0` disables it. |
| `DSH_WEB_LOG` | `/root/.dsh-web.log` | Where DSH's output goes; the proxy scrapes the launch token from here. |
| `DSH_TELEMETRY_DISABLED` | `1` | Any non-empty value opts out of DSH telemetry. |

Only port **3080** is exposed. DSH's own port is never published — do not add a mapping for `3079`.

## Persistence

`/root/.dsh` holds profiles, settings and sessions. Mount it if you want to survive `docker rm`:

```yaml
volumes:
  - dsh-data:/root/.dsh
```

Everything else in the image is disposable. Recreating without this volume gives you a clean install.

## What is in the image

Base is `node:24-slim` (Debian), so `node` and `npm` come from the base.

| Tool | Notes |
|---|---|
| `@deepseek-ai/dsh` | Pinned by the `DSH_VERSION` build arg |
| `pnpm` | Global npm install, for plugins that expect it |
| `uv`, `uvx` | Python package manager; MCP servers commonly launch via `uvx` |
| `git`, `gh`, `curl`, `wget` | `gh` comes from GitHub's official apt repository |
| `chromium` | Headless/CLI Chromium with `fonts-liberation` and root `--no-sandbox` via `/etc/chromium.d/no-sandbox` |
| `jq`, `procps`, `unzip`, `ca-certificates` | |
| `nano` | |
| `python3`, `build-essential` | `make` and `g++` included, so native modules compile inside the container |

There is no `vim`, `htop`, `tmux`, `tree`, `zip`, or `openssh-client`. Add them to
the `apt-get install` line in the `Dockerfile` if you need them; the layer is small.

`build-essential` and `python3` are deliberate: `npm install` of a package with a
node-gyp addon, or a `pip install` that builds from source, works out of the box.
They cost roughly 200 MB of image size.

## Reaching the UI through a hostname

DSH binds the session cookie to the authority the browser uses. Behind a proxy
that becomes a problem: the proxy talks to DSH over loopback, so DSH would mint
a cookie for `127.0.0.1:3079`, and the browser's copy is then rejected on every
request — the page reloads forever and the session never sticks.

Two things have to work, and one setting covers both:

```bash
-e DSH_TRUSTED_HOSTS=app.example.com
```

- It becomes `--trusted-host`, DSH's supported way to accept a non-loopback
  `Host` on `/api`. Without it the trust fence rejects the proxy.
- The proxy also refuses any **other** Host with `421`, on every path.

That second part matters: DSH applies its trust fence to `/api` only, so the
page, its bundles and the WebSocket upgrades would otherwise be served to any
Host header — a hostname pointed at this server would get a working UI. Listing
the authority makes the proxy reject everything else, at `/` included.

**Loopback is always allowed** (`127.0.0.1`, `localhost`, `[::1]`, any port).
It cannot be reached by DNS rebinding, and it is how the container healthcheck
probes the proxy.

Leaving the variable empty disables the host check entirely; the UI is then
reachable at any Host, and only `--trusted-host` is left unset. Use that only
alongside Basic Auth on a trusted network.

Include the port when it is not the scheme default: `app.example.com:8443`.
List several accepted authorities as `a.example.com,b.example.com`; the first
one is the one browsers should use.

**Pasting a full URL works.** `https://app.example.com/` is reduced to
`app.example.com` with a warning in the log. Do not rely on it — DSH itself
rejects a scheme outright (its trust check parses a bare `host[:port]`), and the
scheme is meaningless there because the check compares the `Host` header, which
never carries one.

**Not needed for `http://localhost:3080`** — loopback is already trusted, and
the client's own Host is correct.

### Behind Cloudflare (proxied DNS)

A Cloudflare-proxied host needs three things, and missing any one of them
looks like a reconnect loop:

1. **`DSH_PUBLIC_URL=https://<your domain>/` and `DSH_TRUSTED_HOSTS=<your domain>`**
   (or just the trusted host — the public URL is derived from it as `https://…/`).
   `--public-url` is what tells dsh where the UI lives; `--trusted-host` only
   admits the Host. Without the public URL dsh advertises `http://127.0.0.1:3079/`
   and the realtime channel tries to reach loopback from your browser.
2. **Cloudflare dashboard, for this hostname:** turn **Rocket Loader off**
   (it defers the `randomUUID` shim, so RPC ids are never created — the shim
   now also carries `data-cfasync="false"` as a second line of defence),
   **Auto Minify off** for HTML/JS, and a **Cache Rule: Bypass** for the host
   (a cached `/` would serve a page without its session cookie). Leave
   **WebSockets on**, and use **SSL Full (Strict)** if Traefik terminates TLS.
3. **The continuous reconnect is dsh's own heartbeat, not Cloudflare's idle
   timeout.** dsh's realtime server pings every 2s and *terminates the socket
   after 2 missed pongs* — an idle UI dies in ~6s whenever the ping→pong
   round trip doesn't survive the proxy chain. The proxy now answers that
   heartbeat itself: it sends a masked pong to dsh every 1.5s
   (`PROXY_WS_UPSTREAM_PONG_INTERVAL_MS`, `0` disables) on the upstream leg,
   so dsh never sees a missed heartbeat no matter what Cloudflare does with
   real ping/pong traffic. The downstream ping every 30s
   (`PROXY_WS_PING_INTERVAL_MS`) is still there for Cloudflare's ~100s idle
   reap. If the UI still reconnects, the proxy logs the decisive clue:
   `ws close /api/remote.mux after Ns` — ~6s means the heartbeat kill,
   ~100s means an idle timeout, ~0s or no `ws upstream open` means the
   handshake itself failed (check `DSH_TRUSTED_HOSTS` on a `403`, the
   launch-token exchange on a `401`, and the `Upgrade` headers on a `101`
   that closes at once). The line also says how the socket ended: a
   `ws close-frame browser code <n>` / `ws close-frame dsh code <n>` line
   just before it names who closed the connection and with what code (1000
   clean, 1001 going away, 1011 server error); `no close frame from
   browser` means the TCP connection vanished mid-flight with no WS close
   handshake — the 1006 case, i.e. something between the browser and the
   origin (Cloudflare, Traefik, or the network itself) cut it.

## Security notes

- **The container runs as root, by design.** That is what this image was asked to do, and DSH is a coding agent — it needs to write files. It also means a compromise inside the container is a root compromise *inside the container*. Do not mount the Docker socket into it.
- **Set `PROXY_USERNAME` and `PROXY_PASSWORD` before exposing it to any network.** With both empty, the proxy forwards everything without a check, and the UI behind it can execute code.
- **Terminate TLS in front of this** if traffic crosses a network you do not control. The proxy speaks plain HTTP.
- **Basic Auth is not a user system.** It is one shared credential for the door; DSH's own browser session sits behind it.

## Troubleshooting

**The realtime channel stays "pending" / RPC never connects.**
The `randomUUID` shim did not reach the page. Confirm the shim is present:

```bash
curl -s -u user:pass http://localhost:3080/ | grep -c randomUUID
```

A `0` here means the rewrite pipeline did not run — check `docker logs` for proxy errors, and file an issue with the DSH version you are running.

**Repeated 401, or a login loop.**
Usually one of: wrong credentials; or DSH's launch token could not be scraped (check `/root/.dsh-web.log` exists and contains a `token=` line); or you are switching between `localhost` and a LAN IP.

**Sessions disappear when you change the URL.**
Expected. Cookies are bound to `host:port`, so `localhost:3080` and `192.168.1.5:3080` are two separate sessions. Pick one URL and stick to it.

**`502 Bad Gateway`.**
The proxy is up but DSH is not answering yet, or has exited. Check `docker logs dsh-web` — the entrypoint prints DSH's last 40 log lines when it fails to start.

**`listen EADDRINUSE: address already in use 127.0.0.1:3079` after a plugin restart.**
The old dsh process exited, but one of its children inherited the listening
socket and kept the port bound, so the supervisor's next dsh died the same way
on every retry. The entrypoint now starts dsh in its own process group
(`setsid`), kills the whole tree plus any leftover dsh process on restart,
and waits until the port is actually free before starting the next one — it
never boots into an occupied port. If you still see this loop, the holder is
outside the container's process tree: check `ss -ltnp` on the host for
something else listening on 3079.

**`tail: /root/.dsh-web.log: file truncated` in the container log.**
Harmless: the supervisor truncates the log on every dsh restart so a stale
launch token can never be read as the current one, and `tail -F` reports the
truncation. Its stderr is now suppressed; the dsh output itself is unaffected.

## Development

```bash
# Proxy syntax only
node --check proxy/index.js
node --check proxy/compression.js
node --check proxy/upstream-token.js

# Full verification (needs Docker)
IMAGE=dsh-web:local ./scripts/smoke-test.sh
```

`scripts/smoke-test.sh` checks that DSH still refuses wildcard binds, that unauthenticated and wrong-password requests get 401, that the UI and the shim arrive, that DSH listens on `127.0.0.1` only while the proxy listens on `0.0.0.0`, and that the mapped port is reachable from the host.

## Image tags

| Tag | Meaning |
|---|---|
| `dsh-<version>` | Pinned to a specific `@deepseek-ai/dsh` version. Use this if you want a pinned version. |
| `dsh-<version>-<sha>` | Same build, traceable to a commit. |
| `latest` | Automatically updated to the most recent smoke-tested build. |

Every published build (from pushes to `main`, `v*` tags, scheduled upstream checks, or manual dispatches) updates `:latest` automatically after passing the smoke test. For pinned deployments, use a `dsh-<version>` tag.

### Automatic updates

A scheduled run every 6 hours resolves the current `@deepseek-ai/dsh` version and
checks whether `dsh-<version>` already exists on GHCR. It exists → the run stops
before building. It does not → the image is built, smoke tested, and published
with `dsh-<version>`, `dsh-<version>-<sha>`, and `:latest`.

Published to GHCR for `linux/amd64` and `linux/arm64`.

## Credits

- [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) — DSH itself.
- [smanx/deepseek-harness-docker](https://github.com/smanx/deepseek-harness-docker) — the proxy design this builds on.
- [okxlin/release-factory](https://github.com/okxlin/release-factory) — the multi-arch build and publish conventions.

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
  ghcr.io/6zev/dsh-web:dsh-0.2.1-rc.2
```

Open <http://localhost:3080> and log in with the credentials above.

### Docker Compose

```bash
cp .env.example .env   # then edit it
docker compose up -d
```

### Build it yourself

```bash
docker build -t dsh-web:local --build-arg DSH_VERSION=0.2.1-rc.2 .
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
| `DSH_WEB_LOG` | `/root/.dsh-web.log` | Where DSH's output goes; the proxy scrapes the launch token from here. |
| `DSH_TOKEN` | *(empty)* | Set the launch token manually, skipping the log scrape. |
| `DSH_TOKEN_FILE` | *(empty)* | Or read it from a file. |
| `DSH_TELEMETRY_DISABLED` | `1` | Any non-empty value opts out of DSH telemetry. |

Only port **3080** is exposed. DSH's own port is never published — do not add a mapping for `3079`.

## Persistence

`/root/.dsh` holds profiles, settings and sessions. Mount it if you want to survive `docker rm`:

```yaml
volumes:
  - dsh-data:/root/.dsh
```

Everything else in the image is disposable. Recreating without this volume gives you a clean install.

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
| `dsh-<version>` | Pinned to a specific `@deepseek-ai/dsh` version. Use this. |
| `dsh-<version>-<sha>` | Same build, traceable to a commit. |
| `latest` | Only published for **stable** DSH releases, never for a pre-release. |

Published to GHCR for `linux/amd64` and `linux/arm64`.

## Credits

- [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) — DSH itself.
- [smanx/deepseek-harness-docker](https://github.com/smanx/deepseek-harness-docker) — the proxy design this builds on.
- [okxlin/release-factory](https://github.com/okxlin/release-factory) — the multi-arch build and publish conventions.

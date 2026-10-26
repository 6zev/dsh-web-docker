#!/bin/sh
# Container entrypoint: start DSH on loopback, wait for it, then run the proxy
# in the foreground.
#
# Ordering matters: the proxy's launch-token reader scrapes DSH's log, so DSH has
# to be running before the proxy can answer an authenticated root request.
set -eu

DSH_PORT="${DSH_PORT:-3079}"
PROXY_PORT="${PROXY_PORT:-3080}"
DSH_LOG="${DSH_WEB_LOG:-/root/.dsh-web.log}"
DSH_HOME_DIR="${DSH_HOME:-/root/.dsh}"

# DSH runs from /root, as required. Its home holds profiles and sessions.
mkdir -p "$DSH_HOME_DIR" /root
cd /root

# Start from an empty log. Stale tokens from a previous run must never be
# mistaken for the current one -- the reader takes the LAST match in the file,
# and a persisted /root volume can outlive the process that wrote it.
: >"$DSH_LOG"

# --host is intentionally NOT passed: DSH rejects wildcard addresses in both its
# CLI and its webserver schema, and its loopback default is exactly what the
# proxy needs. --no-open skips the browser launcher, which cannot work here.
#
# DSH_TRUSTED_HOSTS is a comma-separated list of the authorities this deployment
# is reached at (e.g. "app.example.com" or "app.example.com:8443"). Each becomes
# `--trusted-host`, which is DSH's supported way to accept a non-loopback Host
# on /api. Without it, a proxy presenting the public hostname is rejected by the
# trust fence even though the socket is loopback.
DSH_ARGS="web --port ${DSH_PORT} --no-open"
if [ -n "${DSH_TRUSTED_HOSTS:-}" ]; then
  old_ifs="$IFS"
  IFS=','
  for authority in $DSH_TRUSTED_HOSTS; do
    # Trim surrounding whitespace; an empty entry is ignored rather than
    # forwarded, because DSH fails the whole load on a malformed authority.
    authority="$(printf '%s' "$authority" | tr -d '[:space:]')"
    if [ -n "$authority" ]; then
      DSH_ARGS="$DSH_ARGS --trusted-host $authority"
      echo "[start] trusting authority: $authority"
    fi
  done
  IFS="$old_ifs"
fi

echo "[start] launching dsh ${DSH_ARGS}"
# shellcheck disable=SC2086 -- DSH_ARGS is a deliberate word list.
dsh $DSH_ARGS >"$DSH_LOG" 2>&1 &
DSH_PID=$!

# Mirror the log to the container output. Deliberately not `dsh ... | tee`:
# in a pipeline $! is tee's PID, so cleanup would kill the wrong process.
tail -n +1 -f "$DSH_LOG" &
TAIL_PID=$!

cleanup() {
  echo "[stop] shutting down"
  kill "$TAIL_PID" 2>/dev/null || true
  kill "$DSH_PID" 2>/dev/null || true
  wait "$DSH_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Wait for the listener. A 401 counts as ready: once browser auth is in play the
# root document is protected even when the server is perfectly healthy, so
# requiring a 2xx here would make every start fail after the timeout.
echo "[start] waiting for dsh on 127.0.0.1:${DSH_PORT}"
ready=0
attempt=0
while [ "$attempt" -lt 120 ]; do
  if node -e '
    fetch("http://127.0.0.1:" + process.argv[1] + "/")
      .then(() => process.exit(0))
      .catch(() => process.exit(1));
  ' "$DSH_PORT" 2>/dev/null; then
    ready=1
    break
  fi

  if ! kill -0 "$DSH_PID" 2>/dev/null; then
    echo "[start] error: dsh exited before becoming ready" >&2
    echo "[start] last log lines:" >&2
    tail -n 40 "$DSH_LOG" >&2 || true
    exit 1
  fi

  attempt=$((attempt + 1))
  sleep 1
done

if [ "$ready" != "1" ]; then
  echo "[start] error: dsh did not become ready within 120s" >&2
  tail -n 40 "$DSH_LOG" >&2 || true
  exit 1
fi

echo "[start] dsh ready (pid $DSH_PID); starting proxy on 0.0.0.0:${PROXY_PORT}"

cd /app/proxy
export DSH_PORT PROXY_PORT DSH_WEB_LOG="$DSH_LOG"

# exec: the proxy becomes PID 1's child and receives SIGTERM directly, so
# container stop is immediate rather than waiting out a grace period.
exec node index.js

#!/usr/bin/env bash
# End-to-end verification for the dsh-web image.
#
#   IMAGE=dsh-web:test ./scripts/smoke-test.sh
#
# Checks, in order:
#   0. DSH really does refuse a wildcard bind (i.e. the proxy is necessary).
#   1. Unauthenticated access is rejected with 401.
#   2. A wrong password is rejected with 401.
#   3. Correct credentials return the UI.
#   4. The injected randomUUID shim is present (so the gzip rewrite pipeline worked).
#   5. DSH listens on 127.0.0.1 only, never 0.0.0.0.
#   6. The proxy listens on 0.0.0.0.
#   7. The mapped port is reachable from the host (the actual bypass).
#   8. A WebSocket upgrade is not refused by the proxy.
#
# Ports are allocated by Docker, so a busy host port never breaks a run.
set -uo pipefail

IMAGE="${IMAGE:-dsh-web:test}"
USER_NAME="${SMOKE_USER:-smoke}"
USER_PASS="${SMOKE_PASS:-smoke-pass-123}"
NAME="dsh-web-smoke-$$"
FAILED=0

pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=$((FAILED + 1)); }
info() { printf '\n== %s\n' "$1"; }

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --------------------------------------------------------------------------
info "0. DSH rejects wildcard bind (the reason a proxy is needed)"

wildcard_out="$(docker run --rm "$IMAGE" sh -c 'dsh web --host 0.0.0.0 --port 0 2>&1' || true)"
if printf '%s' "$wildcard_out" | grep -qiE 'wildcard|not supported|unspecified'; then
  pass "dsh refuses --host 0.0.0.0"
else
  fail "dsh no longer refuses a wildcard host -- re-check whether the proxy is still required"
  printf '%s\n' "$wildcard_out" | head -20 | sed 's/^/      /'
fi

# --------------------------------------------------------------------------
info "Starting container"

docker run -d --name "$NAME" \
  -p "127.0.0.1::3080" \
  -e PROXY_USERNAME="$USER_NAME" \
  -e PROXY_PASSWORD="$USER_PASS" \
  "$IMAGE" >/dev/null || { echo "docker run failed"; exit 1; }

# Resolve the host port Docker picked.
host_port="$(docker port "$NAME" 3080/tcp | head -1 | sed 's/.*://')"
if [ -z "$host_port" ]; then
  echo "could not resolve mapped port"; exit 1
fi
echo "  container=$NAME host_port=$host_port"

# Wait for the container to report healthy (or fail fast if it exits).
waited=0
status=""
while [ "$waited" -lt 150 ]; do
  status="$(docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null || echo missing)"
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$NAME" 2>/dev/null || echo none)"

  if [ "$status" = "exited" ] || [ "$status" = "missing" ]; then
    echo "container exited before becoming ready:"
    docker logs "$NAME" 2>&1 | tail -40 | sed 's/^/      /'
    exit 1
  fi
  if [ "$health" = "healthy" ]; then break; fi
  sleep 2
  waited=$((waited + 2))
done

if [ "${health:-}" = "healthy" ]; then
  pass "container is healthy"
else
  fail "container did not become healthy in 150s (last: ${health:-unknown})"
  docker logs "$NAME" 2>&1 | tail -40 | sed 's/^/      /'
fi

base="http://127.0.0.1:${host_port}"
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" || echo 000; }

# --------------------------------------------------------------------------
info "1. Unauthenticated request is rejected"
c="$(code "$base/")"
[ "$c" = "401" ] && pass "no credentials -> 401" || fail "no credentials -> $c (expected 401)"

# --------------------------------------------------------------------------
info "2. Wrong password is rejected"
c="$(code -u "$USER_NAME:wrong-password" "$base/")"
[ "$c" = "401" ] && pass "wrong password -> 401" || fail "wrong password -> $c (expected 401)"

# --------------------------------------------------------------------------
info "3. Correct credentials return the UI"
body_file="$(mktemp)"
c="$(curl -s -o "$body_file" -w '%{http_code}' --max-time 20 -u "$USER_NAME:$USER_PASS" "$base/" || echo 000)"
if [ "$c" = "200" ]; then
  pass "authenticated -> 200"
else
  fail "authenticated -> $c (expected 200)"
fi

if grep -qi '<html' "$body_file"; then
  pass "response body is HTML"
else
  fail "response body does not look like HTML"
fi

# --------------------------------------------------------------------------
info "4. randomUUID shim was injected"
if grep -q 'randomUUID' "$body_file"; then
  pass "polyfill present (gzip rewrite pipeline works)"
else
  fail "polyfill missing -- rewrite pipeline did not run"
fi

# --------------------------------------------------------------------------
info "5. DSH binds loopback only"

# 3079 = 0x0C07. /proc/net/tcp lists local_address as HEXADDR:HEXPORT.
# 127.0.0.1 is 0100007F in the little-endian form the kernel prints.
listen_dump="$(docker exec "$NAME" sh -c 'cat /proc/net/tcp /proc/net/tcp6 2>/dev/null' || true)"

if printf '%s' "$listen_dump" | awk '{print $2}' | grep -qi ':0C07$'; then
  pass "DSH is listening on port 3079"
else
  fail "no listener on 3079 found -- DSH may not be running"
fi

if printf '%s' "$listen_dump" | awk '{print $2}' | grep -qiE '^0100007F:0C07$'; then
  pass "DSH listens on 127.0.0.1:3079"
else
  fail "expected a 127.0.0.1:3079 listener"
fi

if printf '%s' "$listen_dump" | awk '{print $2}' | grep -qiE '^(00000000|00000000000000000000000000000000):0C07$'; then
  fail "DSH is listening on a wildcard address -- the bypass assumption is broken"
else
  pass "DSH is NOT exposed on 0.0.0.0:3079"
fi

# --------------------------------------------------------------------------
info "6. Proxy binds every interface"
if printf '%s' "$listen_dump" | awk '{print $2}' | grep -qiE '^(00000000|00000000000000000000000000000000):0C08$'; then
  pass "proxy listens on 0.0.0.0:3080 inside the container"
else
  fail "proxy is not listening on 0.0.0.0:3080"
fi

# --------------------------------------------------------------------------
info "7. Host reaches the UI through the mapped port"
# This is the whole point: a request from outside the container reaches DSH,
# which only ever bound loopback.
c="$(code -u "$USER_NAME:$USER_PASS" "$base/")"
[ "$c" = "200" ] && pass "external request -> 200 (bypass works)" || fail "external request -> $c"

# --------------------------------------------------------------------------
info "8. WebSocket upgrade is not refused by the proxy"
# Sending upgrade headers to a non-upgrade endpoint should still produce an
# HTTP exchange. What must not happen is the proxy dropping the connection.
ws_out="$(curl -s -i --max-time 10 \
  -u "$USER_NAME:$USER_PASS" \
  -H 'Connection: Upgrade' \
  -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  "$base/" 2>&1 || true)"

if printf '%s' "$ws_out" | grep -qiE 'HTTP/[0-9.]+ [0-9]{3}'; then
  status_line="$(printf '%s' "$ws_out" | grep -oiE 'HTTP/[0-9.]+ [0-9]{3}' | head -1)"
  pass "upgrade attempt answered ($status_line), connection not dropped"
else
  fail "upgrade attempt got no HTTP response -- proxy may be dropping upgrades"
fi

rm -f "$body_file"

# --------------------------------------------------------------------------
printf '\n'
if [ "$FAILED" -eq 0 ]; then
  printf '\033[32mALL SMOKE TESTS PASSED\033[0m\n'
  exit 0
fi
printf '\033[31m%d SMOKE TEST(S) FAILED\033[0m\n' "$FAILED"
exit 1

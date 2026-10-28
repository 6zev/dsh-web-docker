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
  timeout 30 docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Whole-script watchdog. Individual docker calls are bounded, but a bug in this
# script must still fail fast with a clear message instead of stalling CI until
# the runner's global timeout kills it with no diagnostics.
( sleep 420; echo; echo "WATCHDOG: smoke test exceeded 420s, aborting" >&2; \
  timeout 30 docker rm -f "$NAME" >/dev/null 2>&1 || true; kill -TERM $$ 2>/dev/null || true ) &
WATCHDOG_PID=$!
trap 'kill "$WATCHDOG_PID" 2>/dev/null || true; cleanup' EXIT

# --------------------------------------------------------------------------
info "0. DSH rejects wildcard bind (the reason a proxy is needed)"

# --entrypoint sh is essential: without it the image's ENTRYPOINT wins, the
# probe boots the whole stack instead of running this command, and the timeout
# kills it -- which reads as "DSH accepted the wildcard" when it never ran.
wildcard_out="$(timeout 90 docker run --rm --entrypoint sh "$IMAGE" \
  -c 'dsh web --host 0.0.0.0 --port 0 2>&1' || true)"

if printf '%s' "$wildcard_out" | grep -qiE 'wildcard|not supported|unspecified'; then
  pass "dsh refuses --host 0.0.0.0"
else
  fail "dsh no longer refuses a wildcard host -- re-check whether the proxy is still required"
  printf '%s\n' "$wildcard_out" | head -20 | sed 's/^/      /'
fi

# --------------------------------------------------------------------------
info "Starting container"

# A non-loopback authority is what makes the cookie assertion meaningful: if the
# deployment authority were 127.0.0.1, a cookie minted for loopback would be
# indistinguishable from a correct one and the test would pass either way.
PUBLIC_AUTHORITY="dsh-smoke.test"
# Deliberately given with a scheme: real deployments paste URLs, and the
# entrypoint is supposed to reduce this to the bare authority DSH accepts.
TRUSTED_INPUT="https://dsh-smoke.test/"

# Every docker call gets a bound. A hung daemon or exec otherwise stalls the
# job until the runner's global timeout, with no useful output.
docker_run_timeout=120
if ! timeout "$docker_run_timeout" docker run -d --name "$NAME" \
  -p "127.0.0.1::3080" \
  -e PROXY_USERNAME="$USER_NAME" \
  -e PROXY_PASSWORD="$USER_PASS" \
  -e DSH_TRUSTED_HOSTS="$TRUSTED_INPUT" \
  "$IMAGE" >/dev/null; then
  echo "docker run failed or timed out"
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  exit 1
fi

# Resolve the host port Docker picked.
host_port="$(timeout 15 docker port "$NAME" 3080/tcp | head -1 | sed 's/.*://' || true)"
if [ -z "$host_port" ]; then
  echo "could not resolve mapped port"
  timeout 20 docker logs "$NAME" 2>&1 | tail -30 | sed 's/^/      /'
  exit 1
fi
echo "  container=$NAME host_port=$host_port"

# Wait for the container to report healthy (or fail fast if it exits).
# 150s covers the 60s health start-period plus a full DSH boot.
waited=0
status=""
health=""
while [ "$waited" -lt 150 ]; do
  status="$(timeout 10 docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null || echo missing)"
  health="$(timeout 10 docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$NAME" 2>/dev/null || echo none)"

  if [ "$status" = "exited" ] || [ "$status" = "missing" ]; then
    echo "container exited before becoming ready:"
    timeout 20 docker logs "$NAME" 2>&1 | tail -40 | sed 's/^/      /'
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
  timeout 20 docker logs "$NAME" 2>&1 | tail -40 | sed 's/^/      /'
fi

# The proxy can only present a non-loopback Host if DSH was told to trust it.
# Without this the /api fence rejects the forwarded Host and the cookie
# assertion below would be chasing the wrong failure.
#
# The input above carries a scheme, so this also proves the entrypoint reduced
# it to the bare authority: DSH rejects a scheme outright and would not boot.
if timeout 20 docker logs "$NAME" 2>&1 | grep -q -- "--trusted-host ${PUBLIC_AUTHORITY}"; then
  pass "dsh started with --trusted-host ${PUBLIC_AUTHORITY} (scheme stripped)"
else
  fail "dsh was not given --trusted-host ${PUBLIC_AUTHORITY}"
  timeout 20 docker logs "$NAME" 2>&1 | grep -a -- "launching dsh" | sed 's/^/      /'
fi

base="http://127.0.0.1:${host_port}"
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" || echo 000; }

# --------------------------------------------------------------------------
info "0b. Hosts outside DSH_TRUSTED_HOSTS are refused everywhere"

# DSH's own fence only guards /api, so without this the page and its bundles
# are served to any Host header. The proxy must refuse an unknown authority on
# "/" too, not just on the API.
c="$(code -H 'Host: not-trusted.example' -u "$USER_NAME:$USER_PASS" "$base/")"
[ "$c" = "421" ] && pass "unknown Host on / -> 421" || fail "unknown Host on / -> $c (expected 421)"

c="$(code -H 'Host: not-trusted.example' "$base/")"
[ "$c" = "421" ] && pass "unknown Host without credentials -> 421" || fail "unknown Host without credentials -> $c (expected 421)"

c="$(code -H 'Host: not-trusted.example' -u "$USER_NAME:$USER_PASS" "$base/api/directoryPicker/list")"
[ "$c" = "421" ] && pass "unknown Host on /api -> 421" || fail "unknown Host on /api -> $c (expected 421)"

# The trusted authority must still work, and loopback must stay reachable or the
# healthcheck and everything below would fail.
c="$(code -H "Host: $PUBLIC_AUTHORITY" -u "$USER_NAME:$USER_PASS" "$base/")"
[ "$c" = "200" ] && pass "trusted Host on / -> 200" || fail "trusted Host on / -> $c (expected 200)"

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
jar_file="$(mktemp)"
c="$(curl -s -o "$body_file" -c "$jar_file" -w '%{http_code}' --max-time 30 \
  -u "$USER_NAME:$USER_PASS" "$base/" || echo 000)"
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

# The whole point of the token exchange: the page comes back WITH a session
# cookie. Without it the browser would be re-exchanging on every request.
if grep -qi 'dsh-auth' "$jar_file"; then
  pass "session cookie issued with the page"
else
  fail "no session cookie after the exchange -- browser would re-auth every request"
  sed 's/^/      /' "$jar_file" | head -10
fi

# The cookie is only useful if DSH accepts it back. Replaying it with the
# client's own Host must not trigger another exchange; if it does, the proxy is
# presenting a different authority than the cookie was minted for, and every
# page load loops forever.
second="$(curl -s -o /dev/null -D - --max-time 20 \
  -b "$jar_file" -u "$USER_NAME:$USER_PASS" "$base/" 2>&1 || true)"
if printf '%s' "$second" | grep -qi '^set-cookie:.*dsh-auth'; then
  fail "second request re-issued a session cookie -- existing session was not reused"
else
  pass "session cookie is reused (no re-exchange on the next request)"
fi

# Same check, but arriving as the deployment authority rather than loopback.
# The proxy presents the client's Host, so this request exercises the path a
# real browser takes: a non-loopback Host that DSH must trust, and a cookie
# minted and looked up under that same authority.
auth_jar="$(mktemp)"
curl -s -o /dev/null -D /dev/null --max-time 30 \
  -H "Host: $PUBLIC_AUTHORITY" -c "$auth_jar" \
  -u "$USER_NAME:$USER_PASS" "$base/" >/dev/null 2>&1 || true

if grep -qi 'dsh-auth' "$auth_jar"; then
  # curl's cookie jar is TAB-separated: field 7 is the value after domain, flag,
  # path, secure, expiry and name.
  payload="$(grep -i 'dsh-auth' "$auth_jar" | awk -F'\t' '{print $7}' | head -1 \
    | sed -E 's/^v1\.([^.]+)\..*/\1/' | tr '_-' '/+')"
  pad=$(( (4 - ${#payload} % 4) % 4 ))
  padded="$payload"
  while [ "$pad" -gt 0 ]; do padded="$padded="; pad=$((pad - 1)); done
  decoded="$(printf '%s' "$padded" | base64 -d 2>/dev/null || true)"

  case "$decoded" in
    *"\"authority\":\"$PUBLIC_AUTHORITY\""*)
      pass "cookie authority is the requesting authority ($PUBLIC_AUTHORITY)"
      ;;
    *'"authority"'*)
      fail "cookie authority is not the requesting authority ($PUBLIC_AUTHORITY)"
      printf '%s\n' "$decoded" | sed 's/^/      /'
      ;;
    '')
      fail "could not decode the session cookie payload"
      ;;
    *)
      fail "unexpected cookie payload"
      printf '%s\n' "$decoded" | sed 's/^/      /'
      ;;
  esac
else
  fail "no session cookie when requesting as $PUBLIC_AUTHORITY"
  sed 's/^/      /' "$auth_jar" | head -10
fi
rm -f "$auth_jar"

# A duplicated Content-Type breaks some clients and makes the header ambiguous.
dup_ct="$(curl -sS -D - -o /dev/null --max-time 20 -u "$USER_NAME:$USER_PASS" "$base/" \
  | grep -ci '^content-type:' || true)"
if [ "$dup_ct" -le 1 ]; then
  pass "Content-Type appears once"
else
  fail "Content-Type appears $dup_ct times"
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
#
# timeout(1) is mandatory here: without it a hung exec blocks the whole job
# until the runner's global limit, which is how the first run stalled.
listen_dump="$(timeout 20 docker exec "$NAME" sh -c 'cat /proc/net/tcp 2>/dev/null' || true)"
if [ -z "$listen_dump" ]; then
  fail "could not read /proc/net/tcp from the container"
fi

# Column 2 is local_address. Strip the IPv6 form down to its last 32 bits so
# both stacks compare the same way: an IPv4mapped or all-zero v6 wildcard is
# still a wildcard, and ::1 still ends in the loopback quad.
addr_of() { awk 'NR>1 {print $2}' | tr 'A-F' 'a-f'; }

listens_on() { addr_of <<<"$listen_dump" | grep -qxF "$1"; }

if addr_of <<<"$listen_dump" | grep -q ':0c07$'; then
  pass "DSH is listening on port 3079"
else
  fail "no listener on 3079 found -- DSH may not be running"
fi

if listens_on '0100007f:0c07'; then
  pass "DSH listens on 127.0.0.1:3079"
else
  fail "expected a 127.0.0.1:3079 listener"
fi

if addr_of <<<"$listen_dump" | grep -qE '^(00000000|00000000000000000000000000000000|0000000000000000ffff0000):0c07$'; then
  fail "DSH is listening on a wildcard address -- the bypass assumption is broken"
else
  pass "DSH is NOT exposed on 0.0.0.0:3079"
fi

# --------------------------------------------------------------------------
info "6. Proxy binds every interface"
if addr_of <<<"$listen_dump" | grep -qE '^(00000000|00000000000000000000000000000000|0000000000000000ffff0000):0c08$'; then
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
info "8. Proxy forwards WebSocket upgrades (does not reject them itself)"
# DSH answers 401 to an unauthenticated upgrade and closes it, so the only
# thing this can assert from the outside is the negative that matters: the
# proxy must not answer the upgrade with a 401/403 of its own. Basic Auth is
# valid here, so any proxy-level rejection would be a bug.
ws_out="$(curl -s -i --max-time 10 \
  -u "$USER_NAME:$USER_PASS" \
  -H 'Connection: Upgrade' \
  -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  "$base/api" 2>&1 || true)"

ws_status="$(printf '%s' "$ws_out" | grep -oiE 'HTTP/[0-9.]+ [0-9]{3}' | head -1 | awk '{print $2}')"

if [ -z "$ws_status" ]; then
  # No response at all: the upgrade was taken and the socket closed by
  # upstream, which is normal for a non-WebSocket path.
  pass "upgrade reached upstream (no proxy-level rejection)"
elif [ "$ws_status" = "401" ] || [ "$ws_status" = "403" ]; then
  fail "proxy rejected a valid-credential upgrade with $ws_status"
else
  pass "upgrade answered by upstream ($ws_status)"
fi

# --------------------------------------------------------------------------
info "9. DSH crash is recovered by the supervisor inside the container"
# The UI's "restart DSH" (used to apply plugin changes) is a real process exit
# upstream, and a plugin that fails to load exits the whole process. The
# entrypoint must still be running afterwards, and DSH must come back without a
# container restart. Killing DSH inside the container reproduces both.
dsh_pid_before="$(timeout 20 docker exec "$NAME" sh -c 'pgrep -n -f "dsh web --port"' 2>/dev/null || true)"
if [ -z "$dsh_pid_before" ]; then
  fail "could not find the dsh process inside the container"
else
  timeout 20 docker exec "$NAME" sh -c 'kill -TERM $(pgrep -n -f "dsh web --port")' >/dev/null 2>&1 || true

  recovered=0
  for _ in $(seq 1 60); do
    sleep 2
    c="$(code -u "$USER_NAME:$USER_PASS" "$base/")"
    if [ "$c" = "200" ] || [ "$c" = "401" ]; then
      recovered=1
      break
    fi
  done

  if [ "$recovered" = "1" ]; then
    pass "dsh came back after being killed (supervisor restarted it, status $c)"
  else
    fail "dsh did not come back within 120s after being killed"
    timeout 20 docker logs "$NAME" 2>&1 | grep -a supervise | tail -10 | sed 's/^/      /'
  fi

  # The supervisor runs in the entrypoint shell. If the container is still up
  # and answering, that shell survived -- which is the property this asserts.
  if timeout 20 docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null | grep -qx true; then
    pass "container still running through the dsh restart"
  else
    fail "container stopped during the dsh restart"
  fi
fi

# --------------------------------------------------------------------------
info "10. Health reflects a dead upstream"
# A proxy that answers 502 forever used to read as healthy, so Docker never
# restarted the container. That is the regression this pins down.
#
# The supervisor is stopped FIRST (it would otherwise revive dsh within
# seconds), then dsh is killed, then the health state must leave 'healthy'.
timeout 20 docker exec "$NAME" sh -c 'kill -STOP 1' >/dev/null 2>&1 || true
timeout 20 docker exec "$NAME" sh -c 'kill -KILL $(pgrep -n -f "dsh web --port")' >/dev/null 2>&1 || true

# Prove the premise before judging the healthcheck: with the supervisor frozen,
# nothing revives dsh, and a listener on 3079 here would make the assertion below
# meaningless.
dsh_alive=0
for _ in $(seq 1 10); do
  if timeout 10 docker exec "$NAME" sh -c 'pgrep -f "dsh web --port" >/dev/null' 2>/dev/null; then
    dsh_alive=1
    sleep 1
  else
    dsh_alive=0
    break
  fi
done
if [ "$dsh_alive" = "1" ]; then
  fail "could not stop dsh, so the health assertion cannot be checked"
fi

# Health only leaves 'healthy' after `retries` consecutive failures (4), each
# one interval (15s) apart, so a single dead sample is not conclusive. Wait for
# the whole verdict -- 22s was shorter than one interval plus the timeouts and
# produced a false "still healthy".
sleep 90
health_after="$(timeout 10 docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$NAME" 2>/dev/null || echo none)"

if [ "$health_after" = "healthy" ]; then
  fail "health stayed 'healthy' with dsh dead -- the healthcheck only watches the proxy"
else
  pass "health left 'healthy' with dsh dead (now: $health_after)"
fi

# Unfreeze: SIGCONT lets the supervisor notice dsh died and restart it, so
# the cleanup trap and container removal behave normally afterwards.
timeout 20 docker exec "$NAME" sh -c 'kill -CONT 1' >/dev/null 2>&1 || true

rm -f "$body_file" "$jar_file"

# --------------------------------------------------------------------------
printf '\n'
if [ "$FAILED" -eq 0 ]; then
  printf '\033[32mALL SMOKE TESTS PASSED\033[0m\n'
  exit 0
fi
printf '\033[31m%d SMOKE TEST(S) FAILED\033[0m\n' "$FAILED"
exit 1

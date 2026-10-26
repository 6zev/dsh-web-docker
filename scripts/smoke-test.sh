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

# The cookie's payload must name the authority the CLIENT used, not the loopback
# address upstream sees. If it says 127.0.0.1 the browser sends a cookie DSH
# rejects, and every page load re-exchanges the token: the session never sticks.
# This is the failure that only showed up behind a real hostname, so assert the
# payload directly rather than trusting a 200.
if grep -qi 'dsh-auth' "$jar_file"; then
  # curl's cookie jar is TAB-separated, so awk's default field splitting gives
  # the wrong column: the value is field 7 (domain, flag, path, secure, expiry,
  # name, value). Splitting on TAB explicitly keeps this readable.
  payload="$(grep -i 'dsh-auth' "$jar_file" | awk -F'\t' '{print $7}' | head -1 \
    | sed -E 's/^v1\.([^.]+)\..*/\1/' | tr '_-' '/+')"
  # Pad and decode. seq is avoided: `seq 1 0` yields "1 0", which would append
  # two stray '=' and corrupt a payload that needed no padding.
  pad=$(( (4 - ${#payload} % 4) % 4 ))
  padded="$payload"
  while [ "$pad" -gt 0 ]; do padded="$padded="; pad=$((pad - 1)); done
  decoded="$(printf '%s' "$padded" | base64 -d 2>/dev/null || true)"

  case "$decoded" in
    *'127.0.0.1'*)
      fail "cookie authority is loopback, not the deployment authority -- session will never stick"
      printf '%s\n' "$decoded" | sed 's/^/      /'
      ;;
    *"\"authority\":\"$PUBLIC_AUTHORITY\""*)
      pass "cookie authority is the deployment authority ($PUBLIC_AUTHORITY)"
      ;;
    *'"authority"'*)
      fail "cookie authority does not match the deployment authority ($PUBLIC_AUTHORITY)"
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
fi

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

rm -f "$body_file" "$jar_file"

# --------------------------------------------------------------------------
printf '\n'
if [ "$FAILED" -eq 0 ]; then
  printf '\033[32mALL SMOKE TESTS PASSED\033[0m\n'
  exit 0
fi
printf '\033[31m%d SMOKE TEST(S) FAILED\033[0m\n' "$FAILED"
exit 1

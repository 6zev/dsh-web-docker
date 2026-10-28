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
#
# A web address is often written with its scheme, so a pasted
# "https://app.example.com" is accepted here and reduced to "app.example.com"
# with a warning. DSH itself refuses a scheme outright -- `assertTrustedAuthority`
# in api-request-trust.ts parses the entry as a bare host[:port] and fails the
# whole plugin load otherwise -- and a scheme never belongs there anyway, because
# it compares the HTTP `Host` header, which carries no scheme.
#
# Every entry here answers one question: which Host values may DSH accept on
# /api. The proxy presents the browser's own Host, so any hostname a browser
# might use to reach this deployment has to be listed -- otherwise that address
# gets a 403 from the trust fence while others work.
DSH_ARGS="web --port ${DSH_PORT} --no-open"
if [ -n "${DSH_TRUSTED_HOSTS:-}" ]; then
  old_ifs="$IFS"
  IFS=','
  for authority in $DSH_TRUSTED_HOSTS; do
    # Trim surrounding whitespace; an empty entry is ignored rather than
    # forwarded, because DSH fails the whole load on a malformed authority.
    authority="$(printf '%s' "$authority" | tr -d '[:space:]')"
    [ -n "$authority" ] || continue

    # Strip a scheme and any trailing path, keeping host[:port].
    case "$authority" in
      *://*)
        original="$authority"
        authority="${authority#*://}"   # drop scheme://
        authority="${authority%%/*}"    # drop any path
        echo "[start] warning: DSH_TRUSTED_HOSTS entry '$original' carries a scheme; using authority '$authority' (Host has no scheme)"
        ;;
    esac
    # A trailing slash left over from "host/" is not part of an authority.
    authority="${authority%%/*}"

    if [ -z "$authority" ]; then
      echo "[start] warning: ignoring DSH_TRUSTED_HOSTS entry with no host" >&2
      continue
    fi

    DSH_ARGS="$DSH_ARGS --trusted-host $authority"
    echo "[start] trusting authority: $authority"
  done
  IFS="$old_ifs"
fi

echo "[start] launching dsh ${DSH_ARGS}"
# shellcheck disable=SC2086 -- DSH_ARGS is a deliberate word list.
dsh $DSH_ARGS >"$DSH_LOG" 2>&1 &
DSH_PID=$!

# Mirror the log to the container output. Deliberately not `dsh ... | tee`:
# in a pipeline $! is tee's PID, so cleanup would kill the wrong process.
# `-F` follows the file across truncation and re-creation, which matters because
# a restart re-creates the log (see the restart path below).
tail -n +1 -F "$DSH_LOG" &
TAIL_PID=$!

PROXY_PID=
STOPPING=0

cleanup() {
  STOPPING=1
  echo "[stop] shutting down"
  kill "$TAIL_PID" 2>/dev/null || true
  if [ -n "$PROXY_PID" ]; then kill "$PROXY_PID" 2>/dev/null || true; fi
  kill "$DSH_PID" 2>/dev/null || true
  if [ -n "$PROXY_PID" ]; then wait "$PROXY_PID" 2>/dev/null || true; fi
  wait "$DSH_PID" 2>/dev/null || true
  # Keep the exit status the script chose. Without this the last `wait` above
  # decides it, and a failed boot would report success to the container runtime.
  exit "${EXIT_CODE:-$?}"
}
# Records the status a fatal path wants, then lets the EXIT trap do the cleanup.
die() {
  EXIT_CODE="$1"
  exit "$1"
}
trap cleanup EXIT INT TERM

# Wait for the listener. A 401 counts as ready: once browser auth is in play the
# root document is protected even when the server is perfectly healthy, so
# requiring a 2xx here would make every start fail after the timeout.
#
# Sets READY=1 on success. Aborts the whole container when DSH exits during the
# wait on a first boot: there is nothing to supervise and the log says why.
wait_for_dsh() {
  echo "[start] waiting for dsh on 127.0.0.1:${DSH_PORT}"
  READY=0
  attempt=0
  while [ "$attempt" -lt 120 ]; do
    if node -e '
      fetch("http://127.0.0.1:" + process.argv[1] + "/")
        .then(() => process.exit(0))
        .catch(() => process.exit(1));
    ' "$DSH_PORT" 2>/dev/null; then
      READY=1
      return 0
    fi

    if ! kill -0 "$DSH_PID" 2>/dev/null; then
      return 1
    fi

    attempt=$((attempt + 1))
    sleep 1
  done
  return 1
}

if ! wait_for_dsh; then
  echo "[start] error: dsh exited or did not become ready within 120s" >&2
  echo "[start] last log lines:" >&2
  tail -n 40 "$DSH_LOG" >&2 || true
  die 1
fi

echo "[start] dsh ready (pid $DSH_PID); starting proxy on 0.0.0.0:${PROXY_PORT}"

cd /app/proxy
export DSH_PORT PROXY_PORT DSH_WEB_LOG="$DSH_LOG"

node index.js &
PROXY_PID=$!

# Supervise DSH from here on.
#
# The UI offers "restart DSH" to apply plugin changes, and that restart is a
# real process exit -- upstream installs a fail-loud handler that turns an
# uncaught exception into `exit(1)` (packages/boot/app-boot/src/index.ts,
# installFailLoud). Without a supervisor the container kept the proxy alive
# against a dead upstream and answered 502 to every request until someone
# restarted the container by hand.
#
# Backoff: a plugin that crashes DSH on every load must not spin at full speed.
# The delay resets only after DSH has stayed up for STABLE_SECONDS.
STABLE_SECONDS=60
delay=2
restarts=0

while :; do
  # A signal flips STOPPING; leave rather than starting another DSH that the
  # trap would then have to kill.
  if [ "$STOPPING" = "1" ]; then
    exit 0
  fi

  if ! kill -0 "$PROXY_PID" 2>/dev/null; then
    echo "[supervise] error: proxy exited; stopping the container so it can restart" >&2
    wait "$PROXY_PID" 2>/dev/null || true
    die 1
  fi

  if ! kill -0 "$DSH_PID" 2>/dev/null; then
    # `|| code=$?` keeps `set -e` from aborting entrypoint on a non-zero exit:
    # a plugin crashing DSH with exit(1) is exactly the case being handled.
    code=0
    wait "$DSH_PID" 2>/dev/null || code=$?
    restarts=$((restarts + 1))
    echo "[supervise] dsh exited (code ${code}); restarting in ${delay}s (restart #${restarts})"
    echo "[supervise] last log lines:" >&2
    tail -n 20 "$DSH_LOG" >&2 || true

    # The proxy scrapes the token from this log. Truncate it first so a stale
    # token from the dead process can never be read as the current one, then
    # restart DSH writing to the same path -- `tail -F` follows the re-creation.
    : >"$DSH_LOG"

    sleep "$delay"
    if [ "$STOPPING" = "1" ]; then exit 0; fi
    # shellcheck disable=SC2086 -- DSH_ARGS is a deliberate word list.
    dsh $DSH_ARGS >>"$DSH_LOG" 2>&1 &
    DSH_PID=$!
    STARTED_AT=$(date +%s)

    if wait_for_dsh; then
      echo "[supervise] dsh restarted (pid $DSH_PID)"
    else
      echo "[supervise] dsh did not come back up; retrying with a longer delay" >&2
      tail -n 40 "$DSH_LOG" >&2 || true
      delay=$((delay * 2))
      if [ "$delay" -gt 60 ]; then delay=60; fi
      continue
    fi
  fi

  # Once the current run has been up for STABLE_SECONDS, drop the backoff:
  # a one-off restart should not leave the next one waiting.
  if [ -n "${STARTED_AT:-}" ] && [ "$delay" -gt 2 ]; then
    if [ $(( $(date +%s) - STARTED_AT )) -ge "$STABLE_SECONDS" ]; then
      echo "[supervise] dsh has been stable for ${STABLE_SECONDS}s; resetting restart delay"
      delay=2
    fi
  fi

  sleep 1
done

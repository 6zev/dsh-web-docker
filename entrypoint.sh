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
FIRST_TRUSTED_HOST=""
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
    [ -z "$FIRST_TRUSTED_HOST" ] && FIRST_TRUSTED_HOST="$authority"
  done
  IFS="$old_ifs"
fi

# --public-url: the advertised browser-facing root.
#
# This is the missing half of a reverse-proxy deployment, and the reason a
# UI behind Cloudflare/Traefik reconnects forever: --trusted-host only admits
# the Host, it does not tell dsh where the UI lives. Without --public-url dsh
# advertises its loopback URL (http://127.0.0.1:3079/) in the printed URL,
# DSH_WEB_URL and the agent runtime context, so the browser-side channel
# tries to reach loopback from the user's machine and never connects.
# --public-url only advertises; it grants no trust, so it must be paired
# with --trusted-host for the same authority (see below).
#
# Derivation: when the UI is reached through a real (non-loopback) hostname,
# the public root is almost always https://<that host>/. Derive it from the
# first DSH_TRUSTED_HOSTS entry so a Cloudflare deployment needs no extra
# variable, and log the derivation so it can be overridden with an explicit
# DSH_PUBLIC_URL (e.g. http, a non-standard port, or a mount prefix /ui/).
PUBLIC_URL="${DSH_PUBLIC_URL:-}"
if [ -z "$PUBLIC_URL" ] && [ -n "$FIRST_TRUSTED_HOST" ]; then
  case "$FIRST_TRUSTED_HOST" in
    127.*|localhost*|\[::1\]*|::1*|"")
      # Loopback: no public URL to advertise.
      ;;
    *)
      PUBLIC_URL="https://${FIRST_TRUSTED_HOST}/"
      echo "[start] deriving public URL from trusted host: $PUBLIC_URL (set DSH_PUBLIC_URL to override)"
      ;;
  esac
fi

if [ -n "$PUBLIC_URL" ]; then
  case "$PUBLIC_URL" in
    http://*|https://*)
      # dsh rejects a public URL with a query, fragment or credentials outright
      # and fails the whole plugin load, so validate here instead of booting
      # into that failure.
      case "$PUBLIC_URL" in
        *\?*|*#*|*@*)
          echo "[start] warning: ignoring invalid DSH_PUBLIC_URL '$PUBLIC_URL' (no query, fragment or credentials allowed)" >&2
          PUBLIC_URL=""
          ;;
        *)
          DSH_ARGS="$DSH_ARGS --public-url $PUBLIC_URL"
          echo "[start] public URL: $PUBLIC_URL"
          # The advertised authority must also be trusted, otherwise every
          # /api call from that Host answers 403. Add it when the user only
          # set DSH_PUBLIC_URL and forgot DSH_TRUSTED_HOSTS.
          public_authority="${PUBLIC_URL#*://}"
          public_authority="${public_authority%%/*}"
          case ",${DSH_TRUSTED_HOSTS:-}," in
            *",${public_authority},"*) ;;
            *)
              DSH_ARGS="$DSH_ARGS --trusted-host $public_authority"
              echo "[start] trusting authority from public URL: $public_authority"
              ;;
          esac
          ;;
      esac
      ;;
    *)
      echo "[start] warning: ignoring invalid DSH_PUBLIC_URL '$PUBLIC_URL' (must be an absolute http(s) URL)" >&2
      PUBLIC_URL=""
      ;;
  esac
fi

echo "[start] launching dsh ${DSH_ARGS}"

# --- EADDRINUSE handling -------------------------------------------------
# A plugin restart is a real process exit, but the old process is not always
# the only holder of 127.0.0.1:3079: dsh spawns child processes (plugin
# workers, helpers) that inherit the listening socket, and a child that
# outlives its parent keeps the port bound after `wait $DSH_PID` has already
# returned. The next dsh then fails with
#   listen EADDRINUSE: address already in use 127.0.0.1:3079
# and the supervisor restarts it again into the same occupied port, forever
# (restart #20, #21, ... in the log). The fix has three parts, all here:
#   1. start dsh in its own process group (setsid), so one kill reaches
#      the whole tree, not just the top process;
#   2. before every (re)start, sweep any leftover dsh processes and wait
#      until the port is actually free -- never start into a busy port;
#   3. if the port is still busy after the sweep, kill the holder and wait
#      again instead of booting into a guaranteed EADDRINUSE.
port_in_use() {
  DSH_PORT="$DSH_PORT" node -e '
    const net = require("net");
    const port = Number(process.env.DSH_PORT);
    const s = net.connect({ host: "127.0.0.1", port });
    s.on("connect", () => { s.destroy(); process.exit(0); });
    s.on("error", () => process.exit(1));
    setTimeout(() => { s.destroy(); process.exit(1); }, 500);
  ' 2>/dev/null
}

wait_for_port_free() {
  timeout_s="${1:-15}"
  waited=0
  while [ "$waited" -lt "$timeout_s" ]; do
    if ! port_in_use; then return 0; fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# Kill every dsh process still alive in this container, except this shell,
# the proxy and the log tail. TERM first, KILL after a grace period.
kill_leftover_dsh() {
  signal="${1:-TERM}"
  for proc in /proc/[0-9]*; do
    pid="${proc#/proc/}"
    [ "$pid" = "$$" ] && continue
    # Subshell form: a pid can vanish mid-scan, and a bare redirect failure
    # would otherwise print "cannot open /proc/<pid>/cmdline" noise.
    cmdline="$( (tr '\0' ' ' < "$proc/cmdline") 2>/dev/null || true)"
    case "$cmdline" in
      *entrypoint.sh*|*proxy/index.js*|*tail\ -*) continue ;;
    esac
    case "$cmdline" in
      *dsh*)
        if kill -0 "$pid" 2>/dev/null; then
          echo "[supervise] killing leftover dsh process $pid ($signal): $cmdline" >&2
          kill "-$signal" "$pid" 2>/dev/null || true
        fi
        ;;
    esac
  done
}

kill_dsh_tree() {
  # Whole process group when dsh was started via setsid (DSH_PID is the group
  # leader), plus a sweep for orphans that escaped the group.
  if [ -n "${DSH_PID:-}" ]; then
    kill -TERM -"$DSH_PID" 2>/dev/null || kill -TERM "$DSH_PID" 2>/dev/null || true
  fi
  kill_leftover_dsh TERM
  sleep 2
  if port_in_use; then
    kill_leftover_dsh KILL
    sleep 1
  fi
}

start_dsh() {
  # Free the port before starting, or the new process dies with EADDRINUSE.
  if port_in_use; then
    echo "[start] port ${DSH_PORT} still in use; sweeping leftover dsh processes" >&2
    kill_dsh_tree
    if ! wait_for_port_free 15; then
      echo "[start] error: port ${DSH_PORT} is still in use after killing leftovers; not starting dsh" >&2
      return 1
    fi
  fi
  # shellcheck disable=SC2086 -- DSH_ARGS is a deliberate word list.
  if command -v setsid >/dev/null 2>&1; then
    setsid dsh $DSH_ARGS >>"$DSH_LOG" 2>&1 &
  else
    dsh $DSH_ARGS >>"$DSH_LOG" 2>&1 &
  fi
  DSH_PID=$!
  STARTED_AT=$(date +%s)
  return 0
}

# First boot: the log was already truncated at the top of this script, so
# start_dsh's append lands on an empty file. Restarts append too, which is
# what the token reader wants (LAST match wins).
if ! start_dsh; then
  echo "[start] error: could not start dsh" >&2
  exit 1
fi

# Mirror the log to the container output. Deliberately not `dsh ... | tee`:
# in a pipeline $! is tee's PID, so cleanup would kill the wrong process.
# `-F` follows the file across truncation and re-creation, which matters because
# a restart re-creates the log (see the restart path below). tail's own stderr
# is discarded: on every restart it prints "file truncated", which is expected
# here and only noise in the container log (the dsh output itself is on stdout).
tail -n +1 -F "$DSH_LOG" 2>/dev/null &
TAIL_PID=$!

PROXY_PID=
STOPPING=0

cleanup() {
  STOPPING=1
  echo "[stop] shutting down"
  kill "$TAIL_PID" 2>/dev/null || true
  if [ -n "$PROXY_PID" ]; then kill "$PROXY_PID" 2>/dev/null || true; fi
  kill_dsh_tree
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

    # The old process exited, but a child may still hold 127.0.0.1:3079 (see
    # the EADDRINUSE note above start_dsh). Sweep it and wait for the port
    # to go free BEFORE starting, or the new process dies the same way.
    kill_dsh_tree
    if ! wait_for_port_free 15; then
      echo "[supervise] port ${DSH_PORT} still busy after sweep; retrying with a longer delay" >&2
      kill_leftover_dsh KILL
      delay=$((delay * 2))
      if [ "$delay" -gt 60 ]; then delay=60; fi
      continue
    fi

    if ! start_dsh; then
      echo "[supervise] could not start dsh (port busy); retrying with a longer delay" >&2
      delay=$((delay * 2))
      if [ "$delay" -gt 60 ]; then delay=60; fi
      continue
    fi

    if wait_for_dsh; then
      echo "[supervise] dsh restarted (pid $DSH_PID)"
    else
      echo "[supervise] dsh did not come back up; retrying with a longer delay" >&2
      tail -n 40 "$DSH_LOG" >&2 || true
      # A fast exit here is usually EADDRINUSE again: sweep before the next
      # attempt so the loop cannot spin on an occupied port.
      kill_dsh_tree
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

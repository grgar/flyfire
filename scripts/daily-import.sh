#!/usr/bin/env bash
# Daily GoCardless import for Firefly III on Fly.
#
# 1. Wake the machine (it scales to zero) by polling /health until it answers.
# 2. Keep it awake with a background /health poll: `fly ssh` does not go through
#    Fly's proxy, so it does not count as traffic and would not stop the machine
#    from being suspended mid-import.
# 3. For each feed, run `php artisan importer:import` on the machine over
#    `fly ssh console`. Unlike the HTTP autoupload endpoint this has no request
#    timeout and reports a real exit code. Feeds run one at a time.
# 4. Note each feed's newest transaction age. A quiet account is normal, so this
#    only ever warns (never fails); a lapsed GoCardless consent makes the importer
#    fail in step 3 (see the exit status handling in import_feed).
#
# This repository is public, so the importer's output (debug logs with
# transaction details) is captured and never printed. Only exit codes and
# canned messages reach the workflow log. Set DEBUG=1 to dump the raw output
# when running locally.
#
# Environment:
#   IMPORT_CONFIG_<N>     an importer JSON config, as the plain file or its base64, N = 1-4.
#                         Feeds are only ever identified by number here, so the
#                         public logs and repository do not say which banks are used.
#   FIREFLY_PAT           Firefly personal access token
#   FLY_API_TOKEN         flyctl auth (deploy token, or `fly tokens create ssh`)
#   FEEDS                 space-separated feed numbers, default: 1 2 3 4
#   FLY_APP, HEALTH_URL, FIREFLY_URL, MAX_AGE_DAYS   overridable defaults below

set -uo pipefail

FLY_APP="${FLY_APP:-whe}"
HEALTH_URL="${HEALTH_URL:-https://whe.grg.app/health}"
FIREFLY_URL="${FIREFLY_URL:-https://whe.grg.app}"
MAX_AGE_DAYS="${MAX_AGE_DAYS:-30}"
FEEDS="${FEEDS:-1 2 3 4}"
UA="Mozilla/5.0 (X11; Linux x86_64) flyfire-import"

# Runs on the Fly machine (busybox sh, as root). Receives the base64 config and
# the Firefly token as arguments; prints IMPORT_EXIT=<code> as its last line so
# we do not depend on flyctl propagating the remote exit status.
read -r -d '' REMOTE <<'EOF'
set -u
echo "REMOTE_STARTED"
cfg=$1
token=$2
d=$(mktemp -d /tmp/importer.XXXXXX) || exit 1
trap 'rm -rf "$d"' EXIT
umask 077
printf '%s' "$cfg" | base64 -d >"$d/config.json"
chown -R www-data "$d"
# Importer settings normally arrive via nginx fastcgi_param, which a CLI run
# does not get. GoCardless credentials are Fly secrets; fall back to PID 1's
# environment if the ssh session did not inherit them.
for v in NORDIGEN_ID NORDIGEN_KEY; do
  eval "val=\${$v:-}"
  if [ -z "$val" ]; then
    val=$(tr '\0' '\n' </proc/1/environ | sed -n "s/^$v=//p")
    [ -n "$val" ] && export "$v=$val"
  fi
done
export FIREFLY_III_URL="${FIREFLY_FLYCAST_URL:-http://localhost:8080}"
export FIREFLY_III_ACCESS_TOKEN="$token"
export IMPORT_DIR_ALLOWLIST="$d"
export D="$d"
cd /var/www/importer
# Run as www-data so storage/importer files stay writable by php-fpm.
su -m -s /bin/sh www-data -c 'exec php artisan importer:import "$D/config.json"' </dev/null
echo "IMPORT_EXIT=$?"
EOF
REMOTE_B64=$(printf '%s' "$REMOTE" | base64 -w0)

failures=0
fail() { echo "::error::$*"; failures=$((failures + 1)); }

wake() {
  local code
  for _ in $(seq 1 36); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -A "$UA" "$HEALTH_URL") || true
    [ "$code" = 200 ] && return 0
    sleep 5
  done
  return 1
}

keepalive() {
  while :; do
    curl -s -o /dev/null --max-time 20 -A "$UA" "$HEALTH_URL" || true
    sleep 20
  done
}

# Turn a config secret into single-line base64 of compact JSON, accepting either
# plain JSON or base64 of it. Anything else is rejected here, before it is sent
# over ssh: the config is passed on a remote command line, where plain
# multi-line JSON gets split into words and run as shell commands.
normalise_config() {
  local raw=$1 json
  if ! json=$(printf '%s' "$raw" | jq -c . 2>/dev/null); then
    json=$(printf '%s' "$raw" | base64 -d 2>/dev/null | jq -c . 2>/dev/null) || return 1
  fi
  printf '%s' "$json" | jq -e 'type == "object" and has("default_account")' >/dev/null 2>&1 || return 1
  printf '%s' "$json" | base64 -w0
}

# Print flyctl's own output (never importer output) from a failed ssh attempt.
# Over-long lines are dropped, which also drops any echoed command line that
# carries the config or token, and the output is capped.
show_flyctl_error() {
  awk 'length > 300 { print "[long line omitted]"; next } { print }' "$1" | head -n 15 | sed 's/^/  flyctl: /'
}

# Check that ssh works at all before importing anything, so a transport problem
# is one clear message instead of the same failure once per feed. The command
# carries no secrets and prints nothing sensitive, so flyctl's output is safe.
ssh_preflight() {
  local out attempt rc
  out=$(mktemp)
  for attempt in 1 2 3; do
    timeout 120 flyctl ssh console -a "$FLY_APP" -C "echo ssh-ok" >"$out" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ] && grep -q '^ssh-ok' "$out"; then
      rm -f "$out"
      return 0
    fi
    echo "ssh preflight attempt $attempt failed (flyctl exit $rc)"
    show_flyctl_error "$out"
    [ "$attempt" -lt 3 ] && sleep "${PREFLIGHT_WAIT:-15}"
  done
  rm -f "$out"
  return 1
}

import_feed() {
  local feed=$1 var="IMPORT_CONFIG_$1" log fly_rc rc started
  if ! [[ $feed =~ ^[0-9]+$ ]]; then
    fail "feed '$feed' is not a number"
    return 1
  fi
  if [ -z "${!var:-}" ]; then
    fail "feed $feed: secret $var is not set"
    return 1
  fi
  local cfg
  if ! cfg=$(normalise_config "${!var}"); then
    fail "feed $feed: $var is not an importer config (expected the JSON file, or its base64)"
    return 1
  fi
  log=$(mktemp)
  timeout 50m flyctl ssh console -a "$FLY_APP" \
    -C "sh -c 'echo $REMOTE_B64 | base64 -d | sh -s -- $cfg $FIREFLY_PAT'" >"$log" 2>&1
  fly_rc=$?
  rc=$(sed -n 's/.*IMPORT_EXIT=\([0-9][0-9]*\).*/\1/p' "$log" | tail -n1)
  # Raw importer output has transaction details, so it is only ever shown when
  # run by hand. A DEBUG secret or variable in Actions is deliberately ignored.
  if [ "${DEBUG:-}" = 1 ] && [ -z "${GITHUB_ACTIONS:-}" ]; then cat "$log"; fi
  started=0
  grep -q 'REMOTE_STARTED' "$log" && started=1

  case "$rc" in
    0)  echo "feed $feed: imported" ;;
    73) echo "feed $feed: nothing new to import" ;;
    # 74 is the documented "agreement expired" status, but `importer:import`
    # overwrites it with 1 whenever there were errors (Import.php in v2.3.5), so
    # an expired consent normally arrives as 1. Both are handled.
    74) fail "feed $feed: GoCardless consent has expired. Re-authorise the connection, then re-run." ;;
    1)  fail "feed $feed: importer failed (exit 1). An expired GoCardless consent also ends up here, so if this connection is nearly 90 days old, renew it." ;;
    64) fail "feed $feed: importer could not connect to Firefly (exit 64)" ;;
    "") if [ "$started" = 1 ]; then
          fail "feed $feed: the importer started but never reported an exit status (flyctl exit $fly_rc). The connection dropped or it timed out; the import may still have completed, so check Firefly before re-running."
        else
          fail "feed $feed: ssh failed before the importer started (flyctl exit $fly_rc)"
          show_flyctl_error "$log"
        fi ;;
    *)  fail "feed $feed: importer exited with status $rc" ;;
  esac
  rm -f "$log"
  [ "$rc" = 0 ] || [ "$rc" = 73 ]
}

# The feed's main account is the importer config's own default_account, so no
# account IDs or bank names need to live in this public repository.
check_fresh() {
  local feed=$1 var="IMPORT_CONFIG_$1" id latest ts age
  id=$(normalise_config "${!var}" | base64 -d | jq -r '.default_account // empty') || id=""
  [ -n "$id" ] || { echo "feed $feed: no default_account in config, skipping freshness check"; return 0; }
  latest=$(curl -fsS --max-time 60 -A "$UA" -H "Authorization: Bearer $FIREFLY_PAT" \
    -H 'Accept: application/json' "$FIREFLY_URL/api/v1/accounts/$id/transactions?limit=1" \
    | jq -r '.data[0].attributes.transactions[0].date // empty') || latest=""
  if [ -z "$latest" ]; then
    echo "::warning::feed $feed: could not read the newest transaction from Firefly"
    return
  fi
  ts=$(date -d "$latest" +%s) || { echo "::warning::feed $feed: unreadable transaction date"; return; }
  age=$(( ($(date +%s) - ts) / 86400 ))
  if [ "$age" -gt "$MAX_AGE_DAYS" ]; then
    echo "::warning::feed $feed: newest transaction is $age days old. Fine if the account is unused; otherwise check the connection."
  else
    echo "feed $feed: newest transaction is $age day(s) old"
  fi
}

[ -n "${FIREFLY_PAT:-}" ] || { echo "::error::FIREFLY_PAT is not set"; exit 1; }

echo "Waking $FLY_APP"
wake || { echo "::error::$HEALTH_URL did not return 200 within 3 minutes"; exit 1; }

keepalive &
KEEPALIVE_PID=$!
trap 'kill "$KEEPALIVE_PID" 2>/dev/null' EXIT

if ! ssh_preflight; then
  echo "::error::flyctl ssh to $FLY_APP failed 3 times, so no feed was attempted. The flyctl messages above say why. If they mention permissions or authorization, FLY_API_TOKEN may not be allowed to ssh: try one from \`fly tokens create ssh\`."
  exit 1
fi
echo "ssh preflight ok"

imported=()
for feed in $FEEDS; do
  import_feed "$feed" && imported+=("$feed")
done

for feed in "${imported[@]}"; do
  check_fresh "$feed"
done

[ "$failures" -eq 0 ]

#!/usr/bin/env bash
# Daily GoCardless import for Firefly III on Fly.
#
# 1. Wake the machine (it scales to zero) and keep it awake with a /health poll:
#    `fly ssh` bypasses Fly's proxy, so it does not count as traffic.
# 2. Over `fly ssh`: apply rules to anything an earlier run left unprocessed,
#    import each feed with `php artisan importer:import` (no request timeout,
#    unlike the autoupload endpoint), then apply rules to what was imported.
# 3. Note each feed's newest transaction age. A quiet account is normal, so this
#    only ever warns.
#
# Rules: left to the importer, Firefly runs every rule for the whole batch inside
# the importer's final "finish batch" HTTP request, which nginx cuts off after
# 600 seconds here; the run then ends and Fly stops the machine with the rules
# half done. So the importer runs with rules off, and scripts/apply-rules.php
# applies them over ssh instead.
#
# This repository is public, so remote output (it has transaction details) is
# captured and never printed: only exit codes, counts and canned messages reach
# the log. DEBUG=1 prints it when run by hand; it is ignored in Actions.
#
# Environment:
#   IMPORT_CONFIG_<N>  an importer JSON config, plain or base64, N = 1-4. Feeds
#                      are only identified by number, so the logs name no banks.
#   FIREFLY_PAT        Firefly personal access token
#   FLY_API_TOKEN      flyctl auth (deploy token, or `fly tokens create ssh`)
#   FEEDS              space-separated feed numbers, default: 1 2 3 4
#   RULE_GROUPS        transaction group IDs to apply rules to as well, to retry
#                      a rules step that failed before it started
#   FLY_APP, HEALTH_URL, FIREFLY_URL, MAX_AGE_DAYS   overridable defaults below

set -uo pipefail

FLY_APP="${FLY_APP:-whe}"
HEALTH_URL="${HEALTH_URL:-https://whe.grg.app/health}"
FIREFLY_URL="${FIREFLY_URL:-https://whe.grg.app}"
MAX_AGE_DAYS="${MAX_AGE_DAYS:-30}"
FEEDS="${FEEDS:-1 2 3 4}"
UA="Mozilla/5.0 (X11; Linux x86_64) flyfire-import"

# Remote scripts run on the machine in busybox sh, as root. Each receives a file
# name and the file as base64, saved in a private directory as $F, then its own
# arguments. Commands run as www-data, like php-fpm, so Firefly's storage stays
# writable by it. The last line is REMOTE_EXIT=<code>, so we do not depend on
# flyctl passing the exit status through.
read -r -d '' PRELUDE <<'EOF'
set -u
echo REMOTE_STARTED
d=$(mktemp -d /tmp/flyfire.XXXXXX) || exit 1
trap 'rm -rf "$d"' EXIT
printf '%s' "$2" | base64 -d >"$d/$1"
chown -R www-data "$d"
export F="$d/$1"
shift 2
EOF

# Arguments: the Firefly token. The importer's settings normally come from nginx
# fastcgi_params, which a CLI run does not get. FIREFLY_III_CLIENT_ID is a Fly
# secret for the importer UI's OAuth login; with it and an access token both
# set, the importer refuses to run and exits 0. Each run downloads days that are
# already imported, and by default every duplicate is an error that fails it.
read -r -d '' IMPORT <<'EOF'
umask 077
export FIREFLY_III_URL="${FIREFLY_FLYCAST_URL:-http://localhost:8080}" FIREFLY_III_ACCESS_TOKEN="$1"
export FIREFLY_III_CLIENT_ID= IGNORE_DUPLICATE_ERRORS=true IMPORT_DIR_ALLOWLIST="$d"
cd /var/www/importer && su -m -s /bin/sh www-data -c 'exec php artisan importer:import "$F"' </dev/null
echo "REMOTE_EXIT=$?"
EOF

# Arguments: transaction group IDs. su -m keeps root's HOME, where www-data
# cannot look, and Postgres's client library fails the connection when it cannot
# read ~/.postgresql/ there.
read -r -d '' RULES <<'EOF'
export IDS="$*" HOME="$d"
cd /var/www/html && su -m -s /bin/sh www-data -c 'exec php "$F" $IDS' </dev/null
echo "REMOTE_EXIT=$?"
EOF

IMPORT_B64=$(printf '%s\n%s' "$PRELUDE" "$IMPORT" | base64 -w0)
RULES_B64=$(printf '%s\n%s' "$PRELUDE" "$RULES" | base64 -w0)

failures=0
fail() { echo "::error::$*"; failures=$((failures + 1)); }

wake() {
  for _ in $(seq 1 36); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -A "$UA" "$HEALTH_URL")" = 200 ] && return 0
    sleep 5
  done
  return 1
}

keepalive() {
  while :; do
    curl -s -o /dev/null --max-time 20 -A "$UA" "$HEALTH_URL"
    sleep 20
  done
}

# Print flyctl's own output (never remote output) from a failed ssh attempt.
# Over-long lines are dropped, which also drops any echoed command line that
# carries a config or token, and the output is capped.
show_flyctl_error() {
  awk 'length > 300 { print "[long line omitted]"; next } { print }' "$1" | head -n 15 | sed 's/^/  flyctl: /'
}

# Every flyctl call reads from /dev/null. With a terminal on stdin, as when run
# by hand, `flyctl ssh console` puts it in raw mode, but `timeout` runs it in a
# background process group, so the kernel stops it and the run hangs; it does so
# again on SIGTERM, hence the kill-after.
ssh_preflight() {
  local out attempt rc
  out=$(mktemp)
  for attempt in 1 2 3; do
    timeout -k 10 120 flyctl ssh console -a "$FLY_APP" -C "echo ssh-ok" </dev/null >"$out" 2>&1
    rc=$?
    grep -q '^ssh-ok' "$out" && [ "$rc" -eq 0 ] && { rm -f "$out"; return 0; }
    echo "ssh preflight attempt $attempt failed (flyctl exit $rc)"
    show_flyctl_error "$out"
    [ "$attempt" -lt 3 ] && sleep "${PREFLIGHT_WAIT:-15}"
  done
  rm -f "$out"
  return 1
}

# remote LOG LIMIT SCRIPT_B64 ARGS...: run a remote script, its output in LOG.
# Sets the caller's rc (REMOTE_EXIT, empty if never reported), fly_rc and started.
remote() {
  local log=$1 limit=$2 script=$3
  shift 3
  timeout -k 10 "$limit" flyctl ssh console -a "$FLY_APP" \
    -C "sh -c 'echo $script | base64 -d | sh -s -- $*'" </dev/null >"$log" 2>&1
  fly_rc=$?
  rc=$(sed -n 's/.*REMOTE_EXIT=\([0-9][0-9]*\).*/\1/p' "$log" | tail -n1)
  started=0
  grep -q REMOTE_STARTED "$log" && started=1
  if [ "${DEBUG:-}" = 1 ] && [ -z "${GITHUB_ACTIONS:-}" ]; then cat "$log"; fi
}

# A config secret as compact JSON, from either the plain file or its base64.
# Anything else is rejected before it goes near ssh.
config_json() {
  local json
  json=$(jq -c . <<<"$1" 2>/dev/null) || json=$(base64 -d <<<"$1" 2>/dev/null | jq -c . 2>/dev/null) || return 1
  jq -e 'type == "object" and has("default_account")' <<<"$json" >/dev/null && printf '%s' "$json"
}

# Exit 0 does not mean anything was imported (importer v2.3.5): its settings
# check stops it with a bare `exit` before any command runs, and once running, 0
# means a message or a warning and no errors, while a GoCardless download that
# was rate limited or failed is only a warning. So the importer's report is read
# as well. The welcome line comes once it has connected to Firefly.
import_feed() {
  local feed=$1 var="IMPORT_CONFIG_$1" cfg log rc fly_rc started created ids
  [[ $feed =~ ^[0-9]+$ ]] || { fail "feed '$feed' is not a number"; return; }
  [ -n "${!var:-}" ] || { fail "feed $feed: secret $var is not set"; return; }
  cfg=$(config_json "${!var}") || { fail "feed $feed: $var is not an importer config (expected the JSON file, or its base64)"; return; }
  log=$(mktemp)
  remote "$log" 50m "$IMPORT_B64" config.json "$(jq -c '.rules = false' <<<"$cfg" | base64 -w0)" "$FIREFLY_PAT"
  created=$(grep -c 'Import index [0-9]*: Created ' "$log")
  # 'Created <type> <a href="...">#<group ID>', on the console and in the log.
  ids=$(grep -oE 'Created [a-z ]+ (<a [^>]*>)?#[0-9]+' "$log" | grep -oE '[0-9]+$' | sort -un | tr '\n' ' ')

  case "$rc" in
    0)  if ! grep -q 'Welcome to the Firefly III data importer' "$log"; then
          fail "feed $feed: the importer exited 0 without starting an import, so its configuration on the machine stopped it. Run this by hand with DEBUG=1 to see its message."
        # "You have no requests left" also follows a download that succeeded on
        # the last request of the day, so only "limit reached" is a refusal.
        elif grep -Eq 'Conversion index \(warn\) [0-9]+: .*limit reached: ' "$log"; then
          fail "feed $feed: GoCardless rate limit reached, so at least one account was not downloaded ($created transaction(s) imported). The limit resets within a day; opening the bank in the importer UI uses the same allowance."
        elif grep 'Conversion index (warn) ' "$log" | grep -Evq 'You have no requests left|has an amount of zero'; then
          fail "feed $feed: downloading transactions from GoCardless failed for at least one account ($created transaction(s) imported)"
        elif [ "$created" -gt 0 ]; then
          echo "feed $feed: imported $created transaction(s)"
        else
          echo "feed $feed: nothing new to import"
        fi ;;
    73) echo "feed $feed: nothing new to import" ;;
    # The importer overwrites 74 with 1 whenever there were errors, so an
    # expired consent normally arrives as 1.
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

  if [ "$(jq '.rules' <<<"$cfg")" != false ]; then
    rule_groups="$rule_groups $ids"
    [ "$created" -gt 0 ] && [ -z "${ids// /}" ] &&
      fail "feed $feed: could not read the IDs of the $created imported transaction(s), so their rules will not be applied"
  fi
  { [ "$rc" = 0 ] || [ "$rc" = 73 ]; } && fresh="$fresh $feed:$(jq -r '.default_account // empty' <<<"$cfg")"
}

# apply_rules leftover|new [GROUP_ID...]: apply rules on the machine (see
# scripts/apply-rules.php) to the given groups and to anything left uncompleted.
apply_rules() {
  local what=$1 log rc fly_rc started count
  shift
  log=$(mktemp)
  remote "$log" 60m "$RULES_B64" apply-rules.php "$RULES_PHP_B64" "$@"
  count=$(sed -n 's/.*RULES_JOURNALS=\([0-9][0-9]*\).*/\1/p' "$log" | tail -n1)
  rm -f "$log"
  if [ "$rc" = 0 ] && [ -n "$count" ]; then
    if [ "$what" = new ]; then
      echo "rules: applied to $count transaction(s)"
    elif [ "$count" -gt 0 ]; then
      echo "rules: applied to $count transaction(s) an earlier run left unprocessed"
    fi
    return 0
  fi
  if [ "$what" = leftover ]; then
    fail "rules: could not finish transactions an earlier run left unprocessed (exit ${rc:-none}, flyctl exit $fly_rc)"
  elif [ "$started" = 1 ]; then
    fail "rules: did not finish (exit ${rc:-none}, flyctl exit $fly_rc). Transactions not yet done stay marked unprocessed and are picked up at the start of the next run; if it failed straight away, re-run with RULE_GROUPS=\"$*\" to apply them."
  else
    fail "rules: ssh failed before the rules were applied (flyctl exit $fly_rc). Re-run with RULE_GROUPS=\"$*\" to apply them."
  fi
  return 1
}

# check_fresh FEED ACCOUNT: the feed's account is its config's default_account,
# so no account IDs or bank names live in this public repository. jq rather
# than `date -d`, which macOS lacks; fromdateiso8601 takes no UTC offset, so the
# age counts from the calendar date.
check_fresh() {
  local feed=$1 account=$2 age
  [ -n "$account" ] || { echo "feed $feed: no default_account in config, skipping freshness check"; return; }
  age=$(curl -fsS --max-time 60 -A "$UA" -H "Authorization: Bearer $FIREFLY_PAT" -H 'Accept: application/json' \
    "$FIREFLY_URL/api/v1/accounts/$account/transactions?limit=1" |
    jq -r '.data[0].attributes.transactions[0].date | (now - (.[0:10] + "T00:00:00Z" | fromdateiso8601)) / 86400 | floor' 2>/dev/null)
  if ! [[ $age =~ ^-?[0-9]+$ ]]; then
    echo "::warning::feed $feed: could not read the newest transaction from Firefly"
  elif [ "$age" -gt "$MAX_AGE_DAYS" ]; then
    echo "::warning::feed $feed: newest transaction is $age days old. Fine if the account is unused; otherwise check the connection."
  else
    echo "feed $feed: newest transaction is $age day(s) old"
  fi
}

[ -n "${FIREFLY_PAT:-}" ] || { echo "::error::FIREFLY_PAT is not set"; exit 1; }
RULES_PHP_B64=$(base64 -w0 <"$(dirname "$0")/apply-rules.php") || { echo "::error::cannot read scripts/apply-rules.php"; exit 1; }

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

# Importing marks every unprocessed transaction as done, rules or not, so
# anything an earlier run left has to have its rules applied first.
if ! apply_rules leftover; then
  echo "::error::no feed was attempted: importing now would mark those transactions done without their rules."
  exit 1
fi

# Filled in by import_feed: groups to apply rules to (feeds with rules on), and
# feed:account pairs to check for freshness (feeds that imported cleanly).
rule_groups="${RULE_GROUPS:-}" fresh=""
for feed in $FEEDS; do
  import_feed "$feed"
done
# Unquoted on purpose: one argument per group ID.
# shellcheck disable=SC2086
[ -n "${rule_groups// /}" ] && apply_rules new $rule_groups
for pair in $fresh; do
  check_fresh "${pair%%:*}" "${pair#*:}"
done

[ "$failures" -eq 0 ]

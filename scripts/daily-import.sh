#!/usr/bin/env bash
# Daily GoCardless import for Firefly III on Fly.
#
# 1. Wake the machine (it scales to zero) by polling /health until it answers.
# 2. Keep it awake with a background /health poll: `fly ssh` does not go through
#    Fly's proxy, so it does not count as traffic and would not stop the machine
#    from being suspended mid-import.
# 3. For each feed, run `php artisan importer:import` on the machine over
#    `fly ssh console`. Unlike the HTTP autoupload endpoint this has no request
#    timeout and reports a real exit code. Feeds run one at a time. Exit 0 does
#    not mean anything was downloaded, so the importer's report is read as well
#    (see import_feed).
#    The importer runs with its own rules turned off; see step 4.
# 4. Apply Firefly's "when a transaction is created" rules to what was imported,
#    over `fly ssh` with scripts/apply-rules.php. The importer would otherwise
#    have Firefly run them all inside its final "finish batch" HTTP request,
#    which nginx cuts off after 600 seconds on this machine, after which the
#    run ends and Fly stops the machine with the rules half done. The same step
#    also runs before importing, to finish anything an earlier run left.
# 5. Note each feed's newest transaction age. A quiet account is normal, so this
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
#   RULE_GROUPS           space-separated Firefly transaction group IDs to apply
#                         rules to as well, to retry after a failed rules step
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
# FIREFLY_III_CLIENT_ID is a Fly secret for the importer UI's OAuth login. With
# both it and an access token set, the importer refuses to run any command and
# exits 0 having done nothing. Empty rather than unset, so nothing can refill it.
export FIREFLY_III_CLIENT_ID=
# Every run downloads days that are already imported, and by default each of
# those transactions is a duplicate error, which fails the run with exit 1.
export IGNORE_DUPLICATE_ERRORS=true
export IMPORT_DIR_ALLOWLIST="$d"
export D="$d"
cd /var/www/importer
# Run as www-data so storage/importer files stay writable by php-fpm.
su -m -s /bin/sh www-data -c 'exec php artisan importer:import "$D/config.json"' </dev/null
echo "IMPORT_EXIT=$?"
EOF
REMOTE_B64=$(printf '%s' "$REMOTE" | base64 -w0)

# Runs on the Fly machine (busybox sh, as root). Receives scripts/apply-rules.php
# as base64, then the transaction group IDs; prints RULES_EXIT=<code> last.
read -r -d '' REMOTE_RULES <<'EOF'
set -u
echo "REMOTE_STARTED"
php=$1
shift
d=$(mktemp -d /tmp/rules.XXXXXX) || exit 1
trap 'rm -rf "$d"' EXIT
printf '%s' "$php" | base64 -d >"$d/apply-rules.php"
chown -R www-data "$d"
# su -m keeps root's HOME, where www-data cannot look, and Postgres's client
# library fails the connection when it cannot read ~/.postgresql/ there.
export RULES_PHP="$d/apply-rules.php" RULES_GROUPS="$*" HOME="$d"
cd /var/www/html
# As www-data, like php-fpm, so Firefly's storage stays writable by it.
su -m -s /bin/sh www-data -c 'exec php "$RULES_PHP" $RULES_GROUPS' </dev/null
echo "RULES_EXIT=$?"
EOF
REMOTE_RULES_B64=$(printf '%s' "$REMOTE_RULES" | base64 -w0)
RULES_PHP_B64=$(base64 -w0 <"$(dirname "$0")/apply-rules.php") || { echo "::error::cannot read scripts/apply-rules.php"; exit 1; }

# Transaction groups the imports created, for feeds whose config has rules on.
rule_groups=""

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

# Every flyctl call reads from /dev/null. With a terminal on stdin, as when run by
# hand, `flyctl ssh console` puts it in raw mode, but `timeout` runs it in a
# background process group, so the kernel stops it as soon as it touches the
# terminal and the run hangs; on SIGTERM it touches the terminal again and stops
# again, which is why there is also a kill-after.

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
    timeout -k 10 120 flyctl ssh console -a "$FLY_APP" -C "echo ssh-ok" </dev/null >"$out" 2>&1
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
  local feed=$1 var="IMPORT_CONFIG_$1" log fly_rc rc started welcomed created ratelimited dlfailed rules ids
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
  # The rules are applied afterwards by apply_rules, so the importer must not
  # ask Firefly to run them itself. The importer's default for "rules" is on.
  rules=$(printf '%s' "$cfg" | base64 -d | jq -r 'if .rules == false then "off" else "on" end')
  cfg=$(printf '%s' "$cfg" | base64 -d | jq -c '.rules = false' | base64 -w0)
  log=$(mktemp)
  timeout -k 10 50m flyctl ssh console -a "$FLY_APP" \
    -C "sh -c 'echo $REMOTE_B64 | base64 -d | sh -s -- $cfg $FIREFLY_PAT'" </dev/null >"$log" 2>&1
  fly_rc=$?
  rc=$(sed -n 's/.*IMPORT_EXIT=\([0-9][0-9]*\).*/\1/p' "$log" | tail -n1)
  # Raw importer output has transaction details, so it is only ever shown when
  # run by hand. A DEBUG secret or variable in Actions is deliberately ignored.
  if [ "${DEBUG:-}" = 1 ] && [ -z "${GITHUB_ACTIONS:-}" ]; then cat "$log"; fi
  started=0
  grep -q 'REMOTE_STARTED' "$log" && started=1

  # Exit 0 does not mean anything was imported (v2.3.5). The importer's settings
  # check (app/Console/Kernel.php) stops it with a bare `exit`, so status 0,
  # before any command runs. Past that, 0 means a message or a warning and no
  # errors, and a GoCardless transactions download that was rate limited or
  # failed is only a warning (TransactionProcessor::download). So read the
  # outcome from the importer's report lines too; only counts and canned
  # messages are printed, never the lines themselves. The welcome line is
  # printed once the importer has connected to Firefly and is about to import.
  welcomed=0
  grep -q 'Welcome to the Firefly III data importer' "$log" && welcomed=1
  created=$(grep -c 'Import index [0-9]*: Created ' "$log")
  # "limit reached:" is the refused download. "You have no requests left" is
  # also added after a download that succeeded on the last request of the day,
  # so it is not a failure on its own.
  ratelimited=0
  grep -Eq 'Conversion index \(warn\) [0-9]+: .*limit reached: ' "$log" && ratelimited=1
  # Any other conversion warning, except a skipped zero-amount transaction, is a
  # download that failed (no response, or one that was not JSON).
  dlfailed=0
  grep 'Conversion index (warn) ' "$log" | grep -Ev 'limit reached: |You have no requests left|has an amount of zero' | grep -q . && dlfailed=1
  # Each created transaction is reported as 'Created <type> <a href="...">#<group
  # ID> ...', on the console and again in the importer's log.
  ids=$(grep -oE 'Created [a-z ]+ (<a [^>]*>)?#[0-9]+' "$log" | grep -oE '[0-9]+$' | sort -un | tr '\n' ' ')
  if [ "$rules" = on ]; then
    rule_groups="$rule_groups $ids"
    if [ "$created" -gt 0 ] && [ -z "${ids// /}" ]; then
      fail "feed $feed: could not read the IDs of the $created imported transaction(s), so their rules will not be applied"
    fi
  fi

  case "$rc" in
    0)  if [ "$welcomed" = 0 ]; then
          fail "feed $feed: the importer exited 0 without starting an import, so its configuration on the machine stopped it. Run this by hand with DEBUG=1 to see its message."
        elif [ "$ratelimited" = 1 ]; then
          fail "feed $feed: GoCardless rate limit reached, so at least one account was not downloaded ($created transaction(s) imported). The limit resets within a day; opening the bank in the importer UI uses the same allowance."
        elif [ "$dlfailed" = 1 ]; then
          fail "feed $feed: downloading transactions from GoCardless failed for at least one account ($created transaction(s) imported)"
        elif [ "$created" -gt 0 ]; then
          echo "feed $feed: imported $created transaction(s)"
        else
          echo "feed $feed: nothing new to import"
        fi ;;
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

# Apply the rules on the machine (see scripts/apply-rules.php) to the given
# transaction groups and to anything Firefly left uncompleted. Prints only
# counts; Firefly's output, which has transaction details, stays in the log.
apply_rules() {
  local what=$1 log fly_rc rc count started=0
  shift
  log=$(mktemp)
  timeout -k 10 60m flyctl ssh console -a "$FLY_APP" \
    -C "sh -c 'echo $REMOTE_RULES_B64 | base64 -d | sh -s -- $RULES_PHP_B64 $*'" </dev/null >"$log" 2>&1
  fly_rc=$?
  rc=$(sed -n 's/.*RULES_EXIT=\([0-9][0-9]*\).*/\1/p' "$log" | tail -n1)
  count=$(sed -n 's/.*RULES_JOURNALS=\([0-9][0-9]*\).*/\1/p' "$log" | tail -n1)
  if [ "${DEBUG:-}" = 1 ] && [ -z "${GITHUB_ACTIONS:-}" ]; then cat "$log"; fi
  grep -q 'REMOTE_STARTED' "$log" && started=1
  rm -f "$log"

  if [ "$rc" = 0 ] && [ -n "$count" ]; then
    if [ "$what" = new ]; then
      echo "rules: applied to $count transaction(s)"
    elif [ "$count" -gt 0 ]; then
      echo "rules: applied to $count transaction(s) an earlier run left unprocessed"
    fi
    return 0
  fi
  if [ "$what" = new ]; then
    if [ "$started" = 1 ]; then
      fail "rules: did not finish (exit ${rc:-none}, flyctl exit $fly_rc). Transactions not yet done stay marked unprocessed and are picked up at the start of the next run; if it failed straight away, re-run with RULE_GROUPS=\"$*\" to apply them."
    else
      fail "rules: ssh failed before the rules were applied (flyctl exit $fly_rc). Re-run with RULE_GROUPS=\"$*\" to apply them."
    fi
  else
    fail "rules: could not finish transactions an earlier run left unprocessed (exit ${rc:-none}, flyctl exit $fly_rc)"
  fi
  return 1
}

# The feed's main account is the importer config's own default_account, so no
# account IDs or bank names need to live in this public repository.
check_fresh() {
  local feed=$1 var="IMPORT_CONFIG_$1" id latest age
  id=$(normalise_config "${!var}" | base64 -d | jq -r '.default_account // empty') || id=""
  [ -n "$id" ] || { echo "feed $feed: no default_account in config, skipping freshness check"; return 0; }
  latest=$(curl -fsS --max-time 60 -A "$UA" -H "Authorization: Bearer $FIREFLY_PAT" \
    -H 'Accept: application/json' "$FIREFLY_URL/api/v1/accounts/$id/transactions?limit=1" \
    | jq -r '.data[0].attributes.transactions[0].date // empty') || latest=""
  if [ -z "$latest" ]; then
    echo "::warning::feed $feed: could not read the newest transaction from Firefly"
    return
  fi
  # jq rather than `date -d`, which macOS does not have. fromdateiso8601 does not
  # take a UTC offset ("+01:00"), so use the transaction's calendar date alone.
  age=$(printf '%s' "$latest" | jq -Rr '(now - (.[0:10] + "T00:00:00Z" | fromdateiso8601)) / 86400 | floor' 2>/dev/null)
  [[ $age =~ ^-?[0-9]+$ ]] || { echo "::warning::feed $feed: unreadable transaction date"; return; }
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

# Importing marks every unprocessed transaction as done, rules or not, so
# anything an earlier run left has to have its rules applied first.
if ! apply_rules leftover; then
  echo "::error::no feed was attempted: importing now would mark those transactions done without their rules."
  exit 1
fi

imported=()
for feed in $FEEDS; do
  import_feed "$feed" && imported+=("$feed")
done

rule_groups="$rule_groups ${RULE_GROUPS:-}"
# Unquoted on purpose: one argument per group ID.
# shellcheck disable=SC2086
[ -n "${rule_groups// /}" ] && apply_rules new $rule_groups

# bash 3.2 (macOS's) treats an empty "${imported[@]}" as unbound under set -u.
for feed in ${imported[@]+"${imported[@]}"}; do
  check_fresh "$feed"
done

[ "$failures" -eq 0 ]

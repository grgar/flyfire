#!/bin/sh

set -ex

export FIREFLY_HOST="${FIREFLY_HOST:-firefly}"
export IMPORTER_HOST="${IMPORTER_HOST:-importer}"

export FIREFLY_APP_URL="${FIREFLY_APP_URL:-http://${FIREFLY_HOST}}"
export FIREFLY_FLYCAST_URL="${FIREFLY_FLYCAST_URL:-http://localhost:8080}"
export IMPORTER_APP_URL="${IMPORTER_APP_URL:-http://${IMPORTER_HOST}}"

# Public origin of the MCP endpoint, advertised in the OAuth metadata. Only
# meaningfully reachable over https, so don't inherit FIREFLY_APP_URL's scheme.
export MCP_PUBLIC_URL="${MCP_PUBLIC_URL:-https://${FIREFLY_HOST}}"
# Endpoint nginx replays an OAuth token against to validate it. Any Firefly API
# endpoint works; point it at one only the intended user can read to stop other
# accounts on a multi-user instance from reaching MCP.
export MCP_AUTH_PROBE="${MCP_AUTH_PROBE:-${FIREFLY_FLYCAST_URL}/api/v1/about/user}"
set +x # nginx compares against MCP_TOKEN verbatim, so keep it out of the logs
# An unset static token must never match a header a client can actually send.
export MCP_TOKEN="${MCP_TOKEN:-$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
set -x

envsubst '$FIREFLY_HOST $IMPORTER_HOST $FIREFLY_APP_URL $IMPORTER_APP_URL $FIREFLY_FLYCAST_URL $TIMEOUT $MCP_TOKEN $MCP_PUBLIC_URL $MCP_AUTH_PROBE' < /etc/nginx/default.conf > /etc/nginx/http.d/default.conf

trap 'kill $(jobs -p)' TERM INT

# The MCP server reads FIREFLY_III_PAT from the environment and acts as that
# token's owner for every request; nginx decides who is allowed to ask. Without
# a PAT there is nothing to serve, so /mcp stays dead.
start_mcp() {
	if [ -n "$FIREFLY_III_PAT" ]; then
		echo "starting mcp server"
		su -m -s /bin/sh www-data -c "cd /tmp && exec firefly-iii-mcp-server --baseUrl $FIREFLY_FLYCAST_URL --port 3000" &
		mcp_pid=$!
	fi
}

if [ -n "$FLY_IMAGE_REF" ]; then
	if [ "$(cat storage/ref)" = "$FLY_IMAGE_REF" ]; then
		echo "skipping bootstrap"

		start_mcp
		echo "starting php-fpm"
		php-fpm &
		fpm_pid=$!
		echo "starting nginx"
		nginx -g "daemon off;" -e stderr &
		nginx_pid=$!

		wait $fpm_pid $nginx_pid $mcp_pid

		exit 0
	fi
	echo "$FLY_IMAGE_REF" >storage/ref
fi

# based on https://dev.azure.com/Firefly-III/_git/MainImage?path=/entrypoint.sh
rm -rf storage/logs/*.log storage/framework/cache
rm -rf storage/importer/logs/*.log storage/importer/framework/cache
storage_dirs="
  storage/app/public
  storage/build
  storage/database
  storage/debugbar
  storage/export
  storage/framework/cache/data
  storage/framework/sessions
  storage/framework/testing
  storage/framework/views/twig
  storage/framework/views/v1
  storage/framework/views/v2
  storage/logs
  storage/upload
  storage/importer/app
  storage/importer/configurations
  storage/importer/conversion-routines
  storage/importer/debugbar
  storage/importer/framework/cache/data
  storage/importer/framework/sessions
  storage/importer/framework/views
  storage/importer/import-jobs
  storage/importer/jobs
  storage/importer/logs
  storage/importer/submission-routines
  storage/importer/uploads"
mkdir -p $storage_dirs
chown -R www-data $storage_dirs
[ -z "$SKIP_UPGRADE" ] && php artisan firefly-iii:upgrade-database
php artisan firefly-iii:laravel-passport-keys
php artisan optimize
php artisan config:cache
php artisan route:cache
php artisan view:cache
php artisan event:cache
chown -R www-data $storage_dirs || :

start_mcp
echo "starting php-fpm"
php-fpm &
fpm_pid=$!
echo "starting nginx"
nginx -g "daemon off;" -e stderr &
nginx_pid=$!

wait $fpm_pid $nginx_pid $mcp_pid

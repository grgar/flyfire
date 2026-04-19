#!/bin/sh

set -ex

export FIREFLY_HOST="${FIREFLY_HOST:-firefly}"
export IMPORTER_HOST="${IMPORTER_HOST:-importer}"

export FIREFLY_APP_URL="${FIREFLY_APP_URL:-http://${FIREFLY_HOST}}"
export FIREFLY_FLYCAST_URL="${FIREFLY_FLYCAST_URL:-http://localhost:8080}"
export IMPORTER_APP_URL="${IMPORTER_APP_URL:-http://${IMPORTER_HOST}}"

envsubst '$FIREFLY_HOST $IMPORTER_HOST $FIREFLY_APP_URL $IMPORTER_APP_URL $FIREFLY_FLYCAST_URL $TIMEOUT' < /etc/nginx/default.conf > /etc/nginx/http.d/default.conf

trap 'kill $(jobs -p)' TERM INT

if [ -n "$FLY_IMAGE_REF" ]; then
	if [ "$(cat storage/ref)" = "$FLY_IMAGE_REF" ]; then
		echo "skipping bootstrap"

		echo "starting php-fpm"
		php-fpm &
		fpm_pid=$!
		echo "starting nginx"
		nginx -g "daemon off;" -e stderr &
		nginx_pid=$!

		wait $fpm_pid $nginx_pid

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
chown www-data $storage_dirs
php artisan firefly-iii:upgrade-database
php artisan firefly-iii:laravel-passport-keys
php artisan optimize

echo "starting php-fpm"
php-fpm &
fpm_pid=$!
echo "starting nginx"
nginx -g "daemon off;" -e stderr &
nginx_pid=$!

wait $fpm_pid $nginx_pid

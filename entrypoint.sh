#!/bin/bash

: "${FIREFLY_HOST:=firefly}"
: "${IMPORTER_HOST:=importer}"

: "${FIREFLY_APP_URL:=http://${FIREFLY_HOST}}"
: "${FIREFLY_FLYCAST_URL:=http://localhost:8080}"
: "${IMPORTER_APP_URL:=http://${IMPORTER_HOST}}"

awk -v a="fastcgi_param APP_URL $FIREFLY_APP_URL;" -v h="$FIREFLY_HOST" '
	/^[[:space:]]*server_name/ { print "\tserver_name " h ";" ; next }
	/location ~ \\.php\$/ { print; inphp=1; next }
	inphp && /fastcgi_pass/ { print; print "\t\t" a; inphp=0; next }
	{ print }
' /etc/nginx/sites-available/default >/etc/nginx/sites-enabled/default

awk -v a="fastcgi_param APP_URL $IMPORTER_APP_URL;" -v f="fastcgi_param FIREFLY_III_URL $FIREFLY_FLYCAST_URL;" -v h="$IMPORTER_HOST" -v r="/var/www/importer/public" '
	/^[[:space:]]*listen/ { gsub(/default_server/,""); gsub(/[ \t]+;/,";"); sub(/[ \t]+$/,""); print; next }
	/^[[:space:]]*server_name/ { print "\tserver_name " h ";" ; next }
	/^[[:space:]]*root/ { print "\troot " r ";" ; next }
	/location ~ \\.php\$/ { print; inphp=1; next }
	inphp && /fastcgi_pass/ { print; print "\t\t" a; print "\t\t" f; inphp=0; next }
	{ print }
' /etc/nginx/sites-available/default >/etc/nginx/sites-enabled/importer

sed -i -E 's~.*open_basedir.*~php_admin_value[open_basedir] = /var/www:/dev/stdout:/tmp~' /etc/php/*/fpm/pool.d/www.conf

if [ "$(< storage/ref)" == "$FLY_IMAGE_REF" ]; then
	echo "skipping bootstrap"
	exec /entrypoint
	exit 0
fi
echo "$FLY_IMAGE_REF" >storage/ref

mkdir -p storage/{app/public,build,database,debugbar,export,framework/{cache/data,sessions,testing,views/{twig,v1,v2}},logs,upload}
chown -R www-data storage
php artisan migrate --seed
php artisan cache:clear
php artisan view:clear
php artisan firefly-iii:upgrade-database
php artisan firefly-iii:laravel-passport-keys
php artisan view:cache
chown -R www-data storage ../importer/storage

exec /entrypoint

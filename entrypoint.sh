#!/bin/bash

if [ "$(cat storage/ref)" == "$FLY_IMAGE_REF" ]; then
	echo "skipping bootstrap"
	exec /entrypoint
	exit 0
fi
echo "$FLY_IMAGE_REF" >storage/ref

composer dump-autoload --optimize
php artisan package:discover
mkdir -p storage/{app/public,build,database,debugbar,export,framework/{cache/data,sessions,testing,views/{twig,v1,v2}},logs,upload}
chown -R www-data storage
php artisan migrate --seed
php artisan cache:clear
php artisan view:clear
php artisan firefly-iii:upgrade-database
php artisan firefly-iii:laravel-passport-keys
php artisan view:cache
chown -R www-data storage

exec /entrypoint

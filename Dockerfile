# syntax=docker/dockerfile:experimental

ARG PHP_VERSION=8.4
FROM fideloper/fly-laravel:${PHP_VERSION} as base
LABEL fly_launch_runtime="laravel"

# from https://dev.azure.com/Firefly-III/_git/MainImage?path=/entrypoint.sh
ENV IS_DOCKER=true

EXPOSE 8080

ARG LANG=en
RUN apt-get update && \
	apt-get install -y language-pack-${LANG}-base && \
	apt-get clean && \
	rm -rf /var/lib/apt/lists/*

RUN chown -R www-data .
USER www-data
RUN mkdir -p \
	storage/app/public \
	storage/build \
	storage/database \
	storage/debugbar \
	storage/export \
	storage/framework/cache/data \
	storage/framework/sessions \
	storage/framework/testing \
	storage/framework/views/twig \
	storage/framework/views/v1 \
	storage/framework/views/v2 \
	storage/logs \
	storage/upload
ARG FIREFLY_VERSION=6.2.9
RUN curl -L https://github.com/firefly-iii/firefly-iii/releases/download/v${FIREFLY_VERSION}/FireflyIII-v${FIREFLY_VERSION}.tar.gz | tar xzf -
RUN composer dump-autoload -o
USER root

CMD ["sh", "-c", "php artisan package:discover && exec /entrypoint"]

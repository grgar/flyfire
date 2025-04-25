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

# install data importer
RUN mkdir -p storage
ARG FIREFLY_DATA_IMPORTER_VERSION=1.6.2
RUN curl -L https://github.com/firefly-iii/data-importer/releases/download/v${FIREFLY_DATA_IMPORTER_VERSION}/DataImporter-v${FIREFLY_DATA_IMPORTER_VERSION}.tar.gz | tar xzf -
RUN composer dump-autoload -o

USER root

CMD ["sh", "-c", "php artisan package:discover && exec /entrypoint"]

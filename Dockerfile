# syntax=docker/dockerfile:experimental

ARG PHP_VERSION=8.4
FROM fideloper/fly-laravel:${PHP_VERSION}
ARG PHP_VERSION
LABEL fly_launch_runtime="laravel"

# from https://dev.azure.com/Firefly-III/_git/MainImage?path=/entrypoint.sh
ENV IS_DOCKER=true

EXPOSE 8080

ARG LANG=en
RUN apt-get update && \
	apt-get install -y language-pack-${LANG}-base && \
	apt-get clean && \
	rm -rf /var/lib/apt/lists/*
# https://github.com/orgs/firefly-iii/discussions/5051
RUN printf "\
	opcache.jit=on\n\
	opcache.enable=1\n\
	opcache.enable_cli=1\n\
	opcache.memory_consumption=256\n\
	opcache.interned_strings_buffer=16\n\
	opcache.max_accelerated_files=10000\n\
	opcache.revalidate_freq=2\n\
	opcache.validate_timestamps=0\n\
	opcache.save_comments=1\n" >> /etc/php/${PHP_VERSION}/mods-available/opcache.ini && \
	printf "\
	realpath_cache_size=4M\n\
	realpath_cache_ttl=600\n\
	memory_limit=200M\n\
	max_execution_time=60\n" >> /etc/php/${PHP_VERSION}/fpm/php.ini && \
	cp /etc/php/${PHP_VERSION}/fpm/php.ini /etc/php/${PHP_VERSION}/cli/php.ini && \
	sed -i "s/fastcgi_buffers.*/fastcgi_buffering off;/" /etc/nginx/sites-enabled/default && \
	sed -i "/fastcgi_buffer_size/d" /etc/nginx/sites-enabled/default && \
	sed -i "s|^command=.*|command=/bin/sh -c 'while [ ! -S /var/run/php/php-fpm.sock ]; do sleep 0.1; done; exec /usr/local/bin/start-nginx'|" /etc/supervisor/conf.d/nginx.conf && \
	chown -R www-data .
USER www-data
RUN mkdir -p storage/{app/public,build,database,debugbar,export,framework/{cache/data,sessions,testing,views/{twig,v1,v2}},logs,upload}
ARG FIREFLY_VERSION=v6.4.23
RUN curl -L https://github.com/firefly-iii/firefly-iii/releases/download/${FIREFLY_VERSION}/FireflyIII-${FIREFLY_VERSION}.tar.gz | tar xzf -
COPY patches flyfire-patches
RUN git apply flyfire-patches/*.patch && composer dump-autoload --optimize

ARG FIREFLY_DATA_IMPORTER_VERSION=v2.1.1
WORKDIR /var/www/importer
RUN curl -L https://github.com/firefly-iii/data-importer/releases/download/${FIREFLY_DATA_IMPORTER_VERSION}/DataImporter-${FIREFLY_DATA_IMPORTER_VERSION%%-*}.tar.gz | tar xzf -
RUN rm -rf storage && ln -s ../html/storage/importer storage && composer dump-autoload --optimize

USER root
RUN chown -R www-data .

WORKDIR /var/www/html

COPY --chmod=0755 entrypoint.sh /
ENTRYPOINT ["/entrypoint.sh"]

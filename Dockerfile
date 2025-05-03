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
RUN echo "opcache.jit=on" >> /etc/php/${PHP_VERSION}/mods-available/opcache.ini && \
	sed -i "s/fastcgi_buffers.*/fastcgi_buffering off;/" /etc/nginx/sites-enabled/default && \
	sed -i "/fastcgi_buffer_size/d" /etc/nginx/sites-enabled/default && \
	sed -i "s|^command=.*|command=/bin/sh -c 'while [ ! -S /var/run/php/php-fpm.sock ]; do sleep 0.1; done; exec /usr/local/bin/start-nginx'|" /etc/supervisor/conf.d/nginx.conf && \
	chown -R www-data .
USER www-data
RUN mkdir -p storage/{app/public,build,database,debugbar,export,framework/{cache/data,sessions,testing,views/{twig,v1,v2}},logs,upload}
ARG FIREFLY_VERSION=6.2.12
RUN curl -L https://github.com/firefly-iii/firefly-iii/releases/download/v${FIREFLY_VERSION}/FireflyIII-v${FIREFLY_VERSION}.tar.gz | tar xzf -
COPY patches flyfire-patches
RUN git apply flyfire-patches/*.patch
RUN composer dump-autoload -o
USER root

COPY --chmod=0755 entrypoint.sh /
ENTRYPOINT ["/entrypoint.sh"]

# syntax=docker/dockerfile:experimental

FROM php:8.5.4-fpm-alpine3.23

# from https://dev.azure.com/Firefly-III/_git/MainImage?path=/entrypoint.sh
ENV IS_DOCKER=true

EXPOSE 8080
RUN apk add --no-cache nginx postgresql-dev git envsubst
RUN docker-php-ext-install bcmath intl pdo_mysql pdo_pgsql
RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" && \
	sed -i -e "s~.*max_execution_time.*~max_execution_time = 600~" "$PHP_INI_DIR/php.ini"
COPY --chown=www-data:root nginx/default.conf /etc/nginx/default.conf
COPY nginx/access-log.conf /etc/nginx/http.d/access-log.conf
COPY php/opcache.ini /usr/local/etc/php/conf.d/
RUN printf "[www]\nuser = www-data\ngroup = www-data\n" > /usr/local/etc/php-fpm.d/user.conf && \
sed -i -e "s~user nginx;~user www-data;~" /etc/nginx/nginx.conf
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer && chmod +x /usr/local/bin/composer

USER www-data
ARG FIREFLY_VERSION=v6.4.23
RUN curl -L https://github.com/firefly-iii/firefly-iii/releases/download/${FIREFLY_VERSION}/FireflyIII-${FIREFLY_VERSION}.tar.gz | tar xzf -
COPY patches .
RUN git apply *.patch && composer dump-autoload --optimize

ARG FIREFLY_DATA_IMPORTER_VERSION=v2.1.1
WORKDIR /var/www/importer
RUN curl -L https://github.com/firefly-iii/data-importer/releases/download/${FIREFLY_DATA_IMPORTER_VERSION}/DataImporter-${FIREFLY_DATA_IMPORTER_VERSION%%-*}.tar.gz | tar xzf -
RUN rm -rf storage && ln -s ../html/storage/importer storage && composer dump-autoload --optimize

USER root
RUN chown -R www-data .

WORKDIR /var/www/html

COPY --chmod=0755 entrypoint.sh /
ENTRYPOINT ["/entrypoint.sh"]

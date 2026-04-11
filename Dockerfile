# syntax=docker/dockerfile:experimental

FROM alpine:3.23

# from https://dev.azure.com/Firefly-III/_git/MainImage?path=/entrypoint.sh
ENV IS_DOCKER=true

EXPOSE 8080
RUN apk add --no-cache php85 php85-fpm php85-bcmath php85-dom php85-fileinfo php85-intl php85-iconv php85-mbstring php85-pdo_mysql php85-pdo_pgsql php85-phar php85-session php85-sodium php85-tokenizer php85-xml php85-xmlreader php85-xmlwriter nginx git envsubst curl shadow
RUN ln -s /usr/bin/php85 /usr/bin/php && ln -s /usr/sbin/php-fpm85 /usr/sbin/php-fpm
RUN sed -i -e "s/.*max_execution_time.*/max_execution_time = 600/" "/etc/php85/php.ini"
RUN sed -i -e "s/.*clear_env.*/clear_env = no/" -e "s/nobody/www-data/" "/etc/php85/php-fpm.d/www.conf"
COPY nginx/default.conf /etc/nginx/default.conf
COPY nginx/access-log.conf /etc/nginx/http.d/access-log.conf
COPY php/opcache.ini /etc/php85/conf.d/
RUN printf "[www]\nuser = www-data\ngroup = www-data\n" > /etc/php85/php-fpm.d/user.conf && \
	sed -i -e "s~user nginx;~user www-data;~" /etc/nginx/nginx.conf && \
	groupmod --gid 33 www-data && \
	adduser -u 33 -D -S -G www-data www-data
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer && chmod +x /usr/local/bin/composer

WORKDIR /var/www/html
RUN mkdir -p ../importer storage/importer && chown -R nginx:www-data /var/www /var/log/php85
USER nginx
ARG FIREFLY_VERSION=v6.5.9
RUN curl -L https://github.com/firefly-iii/firefly-iii/releases/download/${FIREFLY_VERSION}/FireflyIII-${FIREFLY_VERSION}.tar.gz | tar xzf -
COPY patches .
RUN git apply *.patch && composer dump-autoload --optimize

ARG FIREFLY_DATA_IMPORTER_VERSION=v2.2.2
WORKDIR ../importer
RUN curl -L https://github.com/firefly-iii/data-importer/releases/download/${FIREFLY_DATA_IMPORTER_VERSION}/DataImporter-${FIREFLY_DATA_IMPORTER_VERSION%%-*}.tar.gz | tar xzf -
RUN rm -rf storage && ln -s ../html/storage/importer storage && composer dump-autoload --optimize

USER root
RUN chown -R www-data /var/www/html/bootstrap /var/www/html/storage
WORKDIR /var/www/html
COPY --chmod=0755 entrypoint.sh /
ENTRYPOINT ["/entrypoint.sh"]

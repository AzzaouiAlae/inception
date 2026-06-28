FROM alpine:3.23

#install packages
RUN apk update && apk add --no-cache \
    php84 \
    php84-fpm \
    php84-mysqli \
    php84-curl \
    php84-dom \
    php84-exif \
    php84-fileinfo \
    php84-json \
    php84-mbstring \
    php84-openssl \
    php84-xml \
    php84-zip \
    php84-phar \
    mariadb-client


COPY ./conf/wp-config.php /app/wp-config.php
COPY ./tools/wp-cli /bin/wp
COPY ./tools/script.sh /app/script.sh

RUN chmod +x /app/script.sh
RUN chmod +x /bin/wp
RUN rm -f /etc/php84/php-fpm.conf


CMD ["/app/script.sh"]


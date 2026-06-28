FROM alpine:3.23

ARG ADMINER_VERSION=5.4.2

RUN apk update && apk add --no-cache \
        php84 \
        php84-session \
        php84-mysqli \
        php84-pdo_mysql \
    && ln -sf /usr/bin/php84 /usr/bin/php

RUN mkdir -p /var/www/adminer \
    && wget -O /var/www/adminer/index.php \
        "https://github.com/vrana/adminer/releases/download/v${ADMINER_VERSION}/adminer-${ADMINER_VERSION}.php"

EXPOSE 8085

CMD ["sh", "-c", "exec php -S adminer:${ADMINER_PORT} /var/www/adminer/index.php"]
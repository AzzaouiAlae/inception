FROM alpine:3.23

RUN apk update 
RUN apk add --no-cache mariadb mariadb-client 
RUN mkdir -p /run/mysqld
RUN chown -R mysql:mysql /run/mysqld

COPY ./tools/script.sh /app/script.sh

RUN chmod +x /app/script.sh

CMD ["/app/script.sh"]

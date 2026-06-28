FROM alpine:3.23

RUN apk update && \
    apk add --no-cache nginx openssl && \
    mkdir -p /var/www/html && \
    rm -f /etc/nginx/nginx.conf

COPY ./conf/nginx.sh /app/nginx.sh
RUN chmod +x /app/nginx.sh 

EXPOSE 443

CMD ["/app/nginx.sh"]

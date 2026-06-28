FROM alpine:3.23

RUN apk update && apk add --no-cache vsftpd

COPY ./tools/script.sh /script.sh
RUN chmod +x /script.sh
RUN rm -f /etc/vsftpd/vsftpd.conf

CMD ["/script.sh"]
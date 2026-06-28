FROM alpine:3.23

RUN apk update && apk add --no-cache prometheus

COPY ./conf/prometheus.sh /prometheus.sh
RUN chmod +x /prometheus.sh

RUN mkdir -p /var/lib/prometheus && \
    chown -R prometheus:prometheus /var/lib/prometheus && \
    rm -rf /etc/prometheus/prometheus.yml

EXPOSE 9090

CMD ["/prometheus.sh"]

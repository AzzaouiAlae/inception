FROM alpine:3.23

RUN apk update && apk add --no-cache  grafana && \
    mkdir -p /etc/grafana/provisioning/dashboards && \
    mkdir -p /etc/grafana/provisioning/datasources

COPY config/grafana.sh /app/grafana.sh
COPY config/docker-dashboard.json /etc/grafana/provisioning/dashboards/docker-dashboard.json
RUN chmod +x /app/grafana.sh

CMD ["/app/grafana.sh"]
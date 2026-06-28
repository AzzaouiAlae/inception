#!/bin/sh

if [ ! -f  "/etc/prometheus/prometheus.yml" ]; then
  echo "global:
  scrape_interval: 1s
  evaluation_interval: 1s
scrape_configs:
  - job_name: 'cadvisor'
    scrape_interval: 1s
    static_configs:
      - targets: ['cadvisor:$CADVISOR_PORT']" > /etc/prometheus/prometheus.yml
fi

exec prometheus \
     --config.file=/etc/prometheus/prometheus.yml \
     --storage.tsdb.path=/var/lib/prometheus \
     --storage.tsdb.retention.time=7d \
     --web.listen-address=prometheus:$PROMETHEUS_PORT
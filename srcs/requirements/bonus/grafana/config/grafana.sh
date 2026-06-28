#!/bin/sh

GF_SECURITY_ADMIN_PASSWORD=$(cat /run/secrets/grafana_password | tr -d '\n')


    echo "[server]
    http_port = 3000
    root_url = %(protocol)s://%(domain)s:443/grafana/
    serve_from_sub_path = true

    [security]
    admin_user = ${GF_SECURITY_ADMIN_USER}
    admin_password = ${GF_SECURITY_ADMIN_PASSWORD}

    [auth.anonymous]
    enabled = true
    org_role = Viewer" \
    > /etc/grafana/grafana.ini


    echo "apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    uid: prometheus_ds
    access: proxy
    url: http://prometheus:${PROMETHEUS_PORT}
    isDefault: true
    editable: false" \
    > /etc/grafana/provisioning/datasources/datasource.yml


    echo "apiVersion: 1
providers:
  - name: 'default'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    editable: true
    options:
      path: /etc/grafana/provisioning/dashboards
      foldersFromFilesStructure: false" \
    > /etc/grafana/provisioning/dashboards/dashboard.yml


exec grafana server \
     --homepath=/usr/share/grafana \
     --config=/etc/grafana/grafana.ini \
     cfg:default.paths.logs=/var/log/grafana \
     cfg:default.paths.data=/var/lib/grafana \
     cfg:default.paths.plugins=/var/lib/grafana/plugins \
     cfg:default.paths.provisioning=/etc/grafana/provisioning
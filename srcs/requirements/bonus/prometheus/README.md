# Prometheus container — build guide (Inception bonus)

**Prometheus** is the time-series database in the monitoring stack. On an
interval it **scrapes** the `/metrics` endpoint of cAdvisor, stores the samples
in its local TSDB, and serves them over PromQL so Grafana can query and graph
them. No host port — it's reachable only on `inception_network` as
`prometheus:9090`.

> Monitoring chain: **cadvisor** (collect) → **prometheus** (scrape/store) →
> **grafana** (dashboards, shown via NGINX at `/grafana/`).

---

## 0. Rules this container must respect (don't break these)

| Rule | How we satisfy it |
|------|-------------------|
| Base image = penultimate stable Alpine | `FROM alpine:3.23` |
| No `latest` tag, image name = service name | `image: prometheus:Inception` |
| No ready-made app images | `FROM alpine:3.23` + `apk add prometheus` (not the official `prom/prometheus` image) |
| Daemon in the foreground as PID 1 | `prometheus.sh` ends with `exec prometheus ...` |
| No host `ports:` | Internal `9090` only; only Grafana queries it |
| Networks declared in compose | Joins `inception_network` |
| Config not hardcoded in the image | `prometheus.yml` is written at runtime by the entrypoint (the baked default is removed) |

---

## 1. What's in `requirements/bonus/prometheus/`

```
requirements/bonus/prometheus/
├── Dockerfile          # alpine + apk add prometheus, prepare TSDB dir
└── conf/
    └── prometheus.sh   # entrypoint: generate prometheus.yml, exec the server
```

---

## 2. The Dockerfile

```dockerfile
FROM alpine:3.23

RUN apk update && apk add --no-cache prometheus

COPY ./conf/prometheus.sh /prometheus.sh
RUN chmod +x /prometheus.sh

RUN mkdir -p /var/lib/prometheus && \
    chown -R prometheus:prometheus /var/lib/prometheus && \
    rm -rf /etc/prometheus/prometheus.yml

EXPOSE 9090

CMD ["/prometheus.sh"]
```

Notes:
- **`apk add prometheus`** — the server binary on our Alpine base (the `apk`
  package also creates the `prometheus` user/group used below).
- **`mkdir + chown /var/lib/prometheus`** — the TSDB storage path; owned by the
  `prometheus` user so the server can write samples.
- **`rm -rf /etc/prometheus/prometheus.yml`** — delete the package's default
  config so the **runtime** config (written by the script) is the only one. This
  keeps the scrape config out of the image layers.
- **`EXPOSE 9090`** — documentation only; no host mapping in compose (the real
  listen address is set by the script from `$PROMETHEUS_PORT`).

---

## 3. The entrypoint — `conf/prometheus.sh`

```sh
#!/bin/sh

if [ ! -f "/etc/prometheus/prometheus.yml" ]; then
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
```

What it does, and why:
- **Generates `prometheus.yml` at runtime** (guarded by `if [ ! -f ... ]`, so
  it's written once) with `$CADVISOR_PORT` expanded — config stays out of the
  image, env-driven.
- **One scrape target: `cadvisor:$CADVISOR_PORT`** (8080) over the internal
  network — that's the only thing producing metrics here.
- **`scrape_interval: 1s`** — matches cAdvisor's `--housekeeping_interval=1s` so
  graphs are near-real-time.
- **`--storage.tsdb.path=/var/lib/prometheus`** — the dir prepared/owned in the
  Dockerfile.
- **`--storage.tsdb.retention.time=7d`** — keep 7 days of samples, then drop the
  oldest (bounds disk usage).
- **`--web.listen-address=prometheus:$PROMETHEUS_PORT`** — listen on 9090
  inside the container. Binding to the container's own name (resolved on the
  Docker network), rather than `0.0.0.0`, still lets Grafana reach it across
  the network — there's just no host port and no reason to also bind a
  loopback interface nothing else needs.
- **`exec`** — replaces the shell so `prometheus` becomes **PID 1** and receives
  signals directly (clean `docker stop`).

> Note: `/var/lib/prometheus` is backed by the `prometheus_data` named volume
> (see §4), so the TSDB survives container recreation — only `7d` retention
> bounds how much history is kept.

---

## 4. The Compose service block

```yaml
  prometheus:
    depends_on:
      - cadvisor
    build: ./requirements/bonus/prometheus
    image: prometheus:Inception
    container_name: prometheus
    restart: on-failure
    init: true
    volumes:
      - prometheus_data:/var/lib/prometheus
    networks:
      - inception_network
    env_file:
      - .env
```

and, alongside the other named volumes at the bottom of `docker-compose.yml`:

```yaml
volumes:
  prometheus_data:
    driver: local
    driver_opts:
      type: none
      device: ${HOME}/data/prometheus
      o: bind
```

Decisions, and why:
- **`depends_on: cadvisor`** — Prometheus's only scrape target; start order so
  the target exists (note: `depends_on` waits for *start*, not readiness — a
  failed first scrape just retries on the next interval).
- **No `ports:`** — nobody connects to Prometheus from the host; Grafana queries
  it on the internal network. Removing the port reduces attack surface.
- **`volumes: prometheus_data:/var/lib/prometheus`** — same bind-mount pattern
  as `mariadb_data`/`wordpress_data`: a host-backed named volume so the TSDB
  survives `docker compose down`/rebuilds instead of resetting every time.
- **`env_file`** — provides `$PROMETHEUS_PORT` and `$CADVISOR_PORT`.
- `init: true`, `restart: on-failure`, `inception_network` — standard.

---

## 5. Build and run

```bash
docker compose -f srcs/docker-compose.yml up -d --build prometheus
# or full stack:
make

docker compose -f srcs/docker-compose.yml ps prometheus    # Up, 9090/tcp (no host mapping)
docker compose -f srcs/docker-compose.yml logs prometheus
```

---

## 6. Verification

```bash
# a. Prometheus is healthy (from inside the container)
docker exec prometheus wget -qO- http://localhost:9090/-/healthy     # -> Prometheus ... Healthy

# b. The cadvisor target is UP (this is the key check)
docker exec prometheus wget -qO- 'http://localhost:9090/api/v1/targets' | grep -o '"health":"[a-z]*"'

# c. A query returns data scraped from cadvisor
docker exec prometheus wget -qO- \
  'http://localhost:9090/api/v1/query?query=container_cpu_usage_seconds_total' | head -c 300

# d. Grafana can reach Prometheus over the internal network
docker exec grafana wget -qO- http://prometheus:9090/-/healthy

# e. NOT reachable from the host (port not published)
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9090 || echo "refused (correct)"
```

Expected: (a) healthy; (b) `"health":"up"`; (c) JSON with metric series;
(d) healthy from grafana; (e) connection refused on the host.

---

## 7. Defense Q&A (likely evaluator questions)

**Q: What is Prometheus and where does it sit?**
A time-series DB and scraper. It pulls metrics from cAdvisor's `/metrics`
endpoint on an interval, stores them, and serves PromQL queries. It's the middle
of the chain: cadvisor → prometheus → grafana.

**Q: How does it know what to scrape?**
From `prometheus.yml`, generated at container start by the entrypoint, with a
single static target `cadvisor:8080` on the internal network.

**Q: Why is the config generated at runtime instead of baked in?**
To keep config out of the image and let it use env vars (`$CADVISOR_PORT`,
`$PROMETHEUS_PORT`). The Dockerfile even deletes the package's default
`prometheus.yml` so only the runtime one exists.

**Q: Why no host port?**
Only Grafana queries Prometheus, and it does so over `inception_network`. There's
no reason to expose 9090 to the host, so we don't.

**Q: Do the metrics persist?**
Yes — `/var/lib/prometheus` is backed by the `prometheus_data` named volume
(host-bound to `${HOME}/data/prometheus`, same pattern as `mariadb_data`), so
the TSDB survives container recreation. Retention is still capped at 7 days.

**Q: Is the daemon PID 1?**
Yes — the entrypoint ends with `exec prometheus ...`, so it replaces the shell
and runs as PID 1 in the foreground.

---

## 8. Troubleshooting

- **Target `cadvisor` is DOWN** — check both are on `inception_network`, that
  `CADVISOR_PORT` (8080) matches, and that cadvisor is `Up`. See targets at
  `/api/v1/targets`.
- **`prometheus` keeps restarting** — usually a TSDB permission issue; the
  Dockerfile `chown`s `/var/lib/prometheus` to the `prometheus` user — confirm
  that ran.
- **Empty query results** — give cAdvisor a moment to produce metrics, then
  re-query; confirm the target is `up` first.
- **Grafana shows "No data"** — the datasource URL must be
  `http://prometheus:9090` (the internal name/port), and the target must be up.
- **Config didn't update after an edit** — `prometheus.yml` is written only if
  absent; on a recreated container with no volume it regenerates, but a leftover
  file would be kept.

---

## 9. One-line summary of the parts

1. `bonus/prometheus/Dockerfile` — Alpine + `apk add prometheus`, prepare/own
   the TSDB dir, drop the default config.
2. `conf/prometheus.sh` — generate `prometheus.yml` (scrape `cadvisor:8080` every
   1s), then `exec prometheus` on `prometheus:9090` with 7-day retention (PID 1).
3. `docker-compose.yml` — `prometheus` service: `depends_on: cadvisor`, no host
   port, `prometheus_data` volume on `/var/lib/prometheus`, on
   `inception_network`.
4. Role — scrape/store layer between cAdvisor and Grafana.

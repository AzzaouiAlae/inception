# Grafana container — build guide (Inception bonus)

**Grafana** is the visualization layer of the monitoring stack. It queries
Prometheus as a data source and renders the container metrics (CPU, memory,
network, disk) as dashboards. It is **not** exposed on the host directly —
instead it's reached through NGINX at `https://<host>:443/grafana/`, and only
talks to Prometheus on `inception_network`.

> Monitoring chain: **cadvisor** (collect) → **prometheus** (scrape/store) →
> **grafana** (dashboards, served via NGINX `/grafana/`).

---

## 0. Rules this container must respect (don't break these)

| Rule | How we satisfy it |
|------|-------------------|
| Base image = penultimate stable Alpine | `FROM alpine:3.23` |
| No `latest` tag, image name = service name | `image: grafana:Inception` |
| No ready-made app images | `FROM alpine:3.23` + `apk add grafana` (not the official `grafana/grafana` image) |
| Daemon in the foreground as PID 1 | `grafana.sh` ends with `exec grafana server ...` |
| Credentials via Docker secrets | Admin password read from `/run/secrets/grafana_password` |
| No host `ports:` | Internal `3000` only; the host reaches it via NGINX `/grafana/` |
| Networks declared in compose | Joins `inception_network` |
| Config/provisioning not committed as plaintext secrets | `grafana.ini`, datasource and dashboard provider are written at runtime |

---

## 1. What's in `requirements/bonus/grafana/`

```
requirements/bonus/grafana/
├── Dockerfile                  # alpine + apk add grafana, make provisioning dirs
└── config/
    ├── grafana.sh              # entrypoint: write config + provisioning, exec server
    └── docker-dashboard.json   # pre-provisioned dashboard (containers overview)
```

---

## 2. The Dockerfile

```dockerfile
FROM alpine:3.23

RUN apk update && apk add --no-cache  grafana && \
    mkdir -p /etc/grafana/provisioning/dashboards && \
    mkdir -p /etc/grafana/provisioning/datasources

COPY config/grafana.sh /app/grafana.sh
COPY config/docker-dashboard.json /etc/grafana/provisioning/dashboards/docker-dashboard.json
RUN chmod +x /app/grafana.sh

CMD ["/app/grafana.sh"]
```

Notes:
- **`apk add grafana`** — the Grafana server on our Alpine base.
- **`mkdir provisioning/{dashboards,datasources}`** — the directories Grafana
  reads on startup to auto-configure itself (no clicking in the UI).
- **`COPY docker-dashboard.json`** — a ready dashboard dropped into the
  dashboards provisioning dir, so the container metrics view exists on first boot.
- **`COPY grafana.sh`** — the entrypoint that writes the rest of the config from
  env vars and the secret at runtime.

---

## 3. The entrypoint — `config/grafana.sh`

```sh
#!/bin/sh

GF_SECURITY_ADMIN_PASSWORD=$(cat /run/secrets/grafana_password | tr -d '\n')

# 1) grafana.ini  — sub-path serving + admin login + anonymous viewer
echo "[server]
http_port = 3000
root_url = %(protocol)s://%(domain)s:443/grafana/
serve_from_sub_path = true
[security]
admin_user = ${GF_SECURITY_ADMIN_USER}
admin_password = ${GF_SECURITY_ADMIN_PASSWORD}
[auth.anonymous]
enabled = true
org_role = Viewer" > /etc/grafana/grafana.ini

# 2) datasource provisioning — point Grafana at Prometheus
echo "...url: http://prometheus:${PROMETHEUS_PORT}..." \
    > /etc/grafana/provisioning/datasources/datasource.yml

# 3) dashboard provider — load JSON dashboards from the provisioning dir
echo "...path: /etc/grafana/provisioning/dashboards..." \
    > /etc/grafana/provisioning/dashboards/dashboard.yml

exec grafana server \
     --homepath=/usr/share/grafana \
     --config=/etc/grafana/grafana.ini \
     cfg:default.paths.logs=/var/log/grafana \
     cfg:default.paths.data=/var/lib/grafana \
     cfg:default.paths.plugins=/var/lib/grafana/plugins \
     cfg:default.paths.provisioning=/etc/grafana/provisioning
```

What it does, and why:
- **Reads the admin password from `/run/secrets/grafana_password`** (the Docker
  secret), `tr -d '\n'` strips the trailing newline — so the credential is never
  baked into the image or `.env`.
- **`serve_from_sub_path = true` + `root_url = .../grafana/`** — Grafana lives
  behind NGINX at the `/grafana/` path, not the domain root; this makes all its
  internal links/assets resolve under that sub-path. Matches the NGINX
  `location /grafana/ { proxy_pass http://grafana:3000; ... }` block.
- **`[auth.anonymous] org_role = Viewer`** — anyone hitting `/grafana/` can view
  dashboards without logging in; editing still needs the admin account. Handy for
  a quick demo during defense.
- **datasource.yml** — provisions Prometheus as the default data source at
  `http://prometheus:${PROMETHEUS_PORT}` (internal name/port), so no manual
  setup.
- **dashboard.yml** — tells Grafana to load any dashboard JSON (e.g.
  `docker-dashboard.json`) from the provisioning dir on startup.
- **`exec grafana server ...`** — replaces the shell so Grafana is **PID 1**;
  the `cfg:...` flags point logs/data/plugins/provisioning at the right paths.

> Note: no volume, so dashboards you create *in the UI* and the Grafana DB are
> ephemeral — but the **provisioned** datasource and dashboard are recreated on
> every start from the files above, so the demo view always comes back.

---

## 4. The Compose service block

```yaml
  grafana:
    build: ./requirements/bonus/grafana
    image: grafana:Inception
    container_name: grafana
    restart: on-failure
    init: true
    networks:
      - inception_network
    env_file:
      - .env
    secrets:
      - grafana_password
```

And NGINX depends on it and proxies it:

```yaml
  nginx:
    depends_on:
      - wordpress
      - resume
      - grafana
```

Decisions, and why:
- **`secrets: grafana_password`** — admin password injected at
  `/run/secrets/grafana_password`, never in env or image.
- **No `ports:`** — the host reaches Grafana only through NGINX `/grafana/` over
  TLS; Grafana's own `3000` stays internal.
- **No `volumes:`** — Grafana state is ephemeral; the datasource and dashboard
  are re-provisioned on every boot (see §3).
- `init: true`, `restart: on-failure`, `inception_network`, `env_file` — standard.

---

## 5. How it's reached (through NGINX)

In `nginx/conf/nginx.sh`:

```nginx
location /grafana/ {
    proxy_pass http://grafana:$GRAFANA_PORT;          # grafana:3000, internal
    proxy_set_header Host $host;
    proxy_http_version 1.1;                            # WebSocket for live updates
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
}
```

So the user hits `https://<host>:443/grafana/`, NGINX terminates TLS and proxies
to `grafana:3000`; Grafana, configured with `serve_from_sub_path`, renders
correctly under that path.

---

## 6. Build and run

```bash
docker compose -f srcs/docker-compose.yml up -d --build grafana
# or full stack:
make

docker compose -f srcs/docker-compose.yml ps grafana    # Up, 3000/tcp (no host mapping)
docker compose -f srcs/docker-compose.yml logs grafana
```

---

## 7. Verification

```bash
# a. Grafana is healthy inside the container
docker exec grafana wget -qO- http://localhost:3000/api/health     # -> {"database":"ok",...}

# b. The Prometheus datasource was provisioned
docker exec grafana wget -qO- http://localhost:3000/api/datasources | grep -o '"type":"prometheus"'

# c. Reachable through NGINX at the /grafana/ sub-path (from the host)
curl -k -s -o /dev/null -w '%{http_code}\n' https://127.0.0.1:443/grafana/login   # -> 200

# d. Grafana can query Prometheus over the internal network
docker exec grafana wget -qO- http://prometheus:9090/-/healthy

# e. NOT reachable directly on the host (3000 not published)
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3000 || echo "refused (correct)"
```

Expected: (a) `database: ok`; (b) a prometheus datasource; (c) `200` via NGINX;
(d) healthy; (e) refused on the host.

---

## 8. Defense Q&A (likely evaluator questions)

**Q: What is Grafana doing here?**
It's the dashboard layer. It queries Prometheus and visualizes the container
metrics collected by cAdvisor. End of the chain: cadvisor → prometheus → grafana.

**Q: How do you reach it? Why no host port?**
Through NGINX at `https://<host>:443/grafana/`. Grafana's `3000` stays on the
internal network; exposing it directly would bypass TLS and add attack surface.

**Q: Where does the admin password come from?**
From a Docker secret, read at startup from `/run/secrets/grafana_password` and
written into `grafana.ini`. It's not in the image, the Dockerfile, or `.env`.

**Q: Did you configure the datasource and dashboard by hand?**
No — both are provisioned automatically from files written at container start
(`datasource.yml` → Prometheus; `dashboard.yml` + `docker-dashboard.json`), so a
fresh container comes up already wired.

**Q: Why `serve_from_sub_path`?**
Because it's served under `/grafana/` by NGINX, not at the domain root. Without
it, Grafana's internal links/assets would point at `/` and break behind the
proxy.

**Q: Is the daemon PID 1?**
Yes — the entrypoint ends with `exec grafana server ...`, replacing the shell.

**Q: Do dashboards persist?**
Provisioned ones always (recreated each boot from files). UI-created ones don't —
there's no volume; that's an accepted trade-off for this project.

---

## 9. Troubleshooting

- **`/grafana/` 404s or assets break** — `serve_from_sub_path`/`root_url` wrong,
  or the NGINX `location /grafana/` block missing; both must agree on the path.
- **"No data" on the dashboard** — the Prometheus datasource URL must be
  `http://prometheus:9090`, and Prometheus's cadvisor target must be `up`.
- **Can't log in** — the secret `grafana_password` is empty/missing; check
  `srcs/secrets/grafana_password.txt` exists (regenerated by `tools/setup.sh`).
- **Live panels don't refresh** — the WebSocket proxy headers in the NGINX block
  (`Upgrade`/`Connection`) are required.
- **grafana keeps restarting** — check `logs grafana`; usually a malformed
  provisioning file or unreadable secret.

---

## 10. One-line summary of the parts

1. `bonus/grafana/Dockerfile` — Alpine + `apk add grafana`, create provisioning
   dirs, copy the dashboard JSON + entrypoint.
2. `config/grafana.sh` — at boot, read the admin password from the secret, write
   `grafana.ini` (sub-path + anon viewer), provision the Prometheus datasource
   and dashboard, then `exec grafana server` (PID 1).
3. `docker-compose.yml` — `grafana` service: `grafana_password` secret, no host
   port, no volume, on `inception_network`; NGINX `depends_on: grafana`.
4. Access — `https://<host>:443/grafana/` via NGINX; Grafana ↔ Prometheus stays
   internal.

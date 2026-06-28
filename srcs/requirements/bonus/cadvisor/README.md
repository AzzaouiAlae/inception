# cAdvisor container — build guide (Inception bonus)

**cAdvisor** (Container Advisor, by Google) collects live resource-usage metrics
— CPU, memory, network, filesystem — for the running containers and the host,
and exposes them in **Prometheus format** at `:8080/metrics`. It's the *data
source* of the monitoring stack: Prometheus scrapes it, Grafana visualizes it.
No host port — it's reachable only on `inception_network` as `cadvisor:8080`.

> Monitoring chain: **cadvisor** (collect) → **prometheus** (scrape/store) →
> **grafana** (dashboards, shown via NGINX at `/grafana/`).

---

## 0. Rules this container must respect (don't break these)

| Rule | How we satisfy it |
|------|-------------------|
| Base image = penultimate stable | `FROM debian:bookworm-slim` — **the one non-Alpine service** (see §2 for why) |
| Penultimate Debian | Trixie (13) is stable → **bookworm** is penultimate (was `bullseye`, fixed) |
| No `latest` tag, image name = service name | `image: cadvisor:Inception`; the cAdvisor binary is **pinned** to `v0.57.0` |
| No ready-made app images | We don't pull `gcr.io/cadvisor`; we download the binary onto Debian (like the prometheus binary / wp-cli) |
| Daemon in foreground as PID 1, no hacks | `exec /usr/local/bin/cadvisor ...` — no `tail -f`, no `&` |
| No host `ports:` | Internal `8080` only (host port removed); only Prometheus reaches it |
| Networks declared in compose | Joins `inception_network` |

---

## 1. What's in `requirements/bonus/cadvisor/`

```
requirements/bonus/cadvisor/
└── Dockerfile      # download the pinned cAdvisor binary, run it (no script)
```

No entrypoint script — it's a single binary with flags, like Adminer/redis.

---

## 2. The Dockerfile

```dockerfile
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y wget ca-certificates && rm -rf /var/lib/apt/lists/*

RUN wget -q -O /usr/local/bin/cadvisor \
    https://github.com/google/cadvisor/releases/download/v0.57.0/cadvisor-v0.57.0-linux-amd64 && \
    chmod +x /usr/local/bin/cadvisor

EXPOSE 8080

CMD ["sh", "-c", "exec /usr/local/bin/cadvisor --port=$CADVISOR_PORT --housekeeping_interval=1s --docker_only=true"]
```

Notes:
- **Why Debian, not Alpine?** cAdvisor is distributed as a **glibc**-linked
  binary (`...-linux-amd64`). Alpine uses **musl** libc, so the prebuilt binary
  may not run there. Debian gives us glibc. Penultimate stable Debian is
  `bookworm` (Trixie/13 is current stable) — this was changed from `bullseye`.
- **`wget ... ca-certificates`** — fetch the binary over HTTPS at build; the apt
  lists are removed afterward to keep the image smaller.
- **Pinned `v0.57.0`** — a fixed version (no `latest`), reproducible builds.
- **`EXPOSE 8080`** — hardcoded (env vars are empty at build time); the real
  port is set at runtime by `--port=$CADVISOR_PORT` (8080 from `.env`).
- **Flags**: `--housekeeping_interval=1s` (collect every second, matching
  Prometheus's 1s scrape) and `--docker_only=true` (report only Docker
  containers, not every cgroup — cleaner metrics).
- **`sh -c "exec ..."`** — `sh -c` is needed so `$CADVISOR_PORT` expands;
  `exec` makes the cAdvisor binary replace the shell and become PID 1, so it
  receives signals directly (clean, fast `docker stop`) — same pattern as
  every other service in the stack.

---

## 3. The Compose service block

```yaml
  cadvisor:
    build: ./requirements/bonus/cadvisor
    image: cadvisor:Inception
    container_name: cadvisor
    restart: on-failure
    init: true
    privileged: true
    networks:
      - inception_network
    env_file:
      - .env
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /run/containerd/containerd.sock:/run/containerd/containerd.sock:ro
      - /sys:/sys:ro
      - /var/lib/docker:/var/lib/docker:ro
      - /:/rootfs:ro
```

Decisions, and why:
- **No `ports:`** — host port removed; cAdvisor only needs to be reachable by
  Prometheus on the internal network. You view the data through Grafana (via
  NGINX `/grafana/`), so exposing 8080 to the host is unnecessary attack surface.
- **`privileged: true` + the host mounts** — cAdvisor reads metrics straight
  from the host: cgroup stats (`/sys`), the container runtime (`docker.sock`,
  `containerd.sock`, `/var/lib/docker`), and the root filesystem (`/rootfs`) for
  disk usage. Every mount is **read-only (`:ro`)**.
- `init: true`, `restart: on-failure`, `inception_network`, `env_file` — standard.

> Honest security note: `privileged: true` plus mounting `/` and the Docker
> socket is **broad host access** — a privileged container with the docker
> socket can effectively control the host. It's inherent to how cAdvisor reads
> metrics; we mitigate it by keeping every mount **read-only** and **not
> exposing the port**. Be ready to say this plainly in defense rather than
> pretend it's sandboxed.

---

## 4. Build and run

```bash
docker compose -f srcs/docker-compose.yml up -d --build cadvisor
# or full stack:
make

docker compose -f srcs/docker-compose.yml ps cadvisor    # Up, 8080/tcp (no host mapping)
docker compose -f srcs/docker-compose.yml logs cadvisor
```

---

## 5. Verification

```bash
# a. Health endpoint (from inside the container)
docker exec cadvisor wget -qO- http://localhost:8080/healthz       # -> ok

# b. Prometheus-format metrics are being produced
docker exec cadvisor sh -c 'wget -qO- http://localhost:8080/metrics | grep -m1 container_cpu_usage_seconds_total'

# c. Prometheus can reach it over the internal network (no host port needed)
docker exec prometheus wget -qO- 'http://cadvisor:8080/metrics' | head -n3

# d. NOT reachable from the host (port not published)
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080 || echo "refused (correct)"
```

Expected: (a) `ok`; (b) a `container_cpu_usage_seconds_total{...}` line;
(c) metrics lines from another container; (d) connection refused on the host.

---

## 6. Defense Q&A (likely evaluator questions)

**Q: What is cAdvisor and where does it sit?**
Google's Container Advisor. It measures CPU/memory/network/disk for the running
containers and the host and exposes them at `/metrics` in Prometheus format.
It's the collector at the bottom of the monitoring chain: cadvisor → prometheus
→ grafana.

**Q: Why is this the only service not built on Alpine?**
cAdvisor ships as a glibc-linked binary; Alpine's musl libc can't reliably run
it. So we use Debian, and per the penultimate-stable rule that's `bookworm`
(Trixie/13 is current stable).

**Q: Why `privileged: true` and all those mounts?**
To read metrics it needs cgroup data (`/sys`), the container runtime state
(`docker.sock`, `containerd.sock`, `/var/lib/docker`) and the host rootfs
(`/rootfs`). All read-only. It's broad access by necessity — mitigated by `:ro`
and by not publishing the port.

**Q: How does Prometheus get the metrics? Why no host port?**
Prometheus scrapes `http://cadvisor:8080/metrics` over `inception_network`.
cAdvisor doesn't need a host port — nobody connects to it from outside; you see
the data via Grafana. Removing the port reduces attack surface.

**Q: Is the binary version fixed?**
Yes — `v0.57.0`, pinned in the Dockerfile (no `latest`), so builds are
reproducible.

**Q: Is it PID 1?**
Yes — the `CMD` is `sh -c "exec /usr/local/bin/cadvisor ..."`, so the binary
replaces the shell and receives signals directly (foreground, no hack).

---

## 7. Troubleshooting

- **cadvisor keeps restarting** — usually a missing mount/permission. Confirm
  `/var/run/docker.sock` exists on the host and `privileged: true` is set.
- **`/run/containerd/containerd.sock` not found** — some hosts don't run
  containerd at that path; cAdvisor logs a warning but still works via the
  Docker socket.
- **Prometheus target `cadvisor` is DOWN** — check both are on
  `inception_network`, the port is `8080`, and cadvisor is `Up`.
- **Empty / permission-denied metrics** — needs `privileged: true` and the
  `/sys` mount to read cgroup stats.

---

## 8. One-line summary of the parts

1. `bonus/cadvisor/Dockerfile` — `debian:bookworm-slim` (glibc for the binary),
   download pinned cAdvisor `v0.57.0`, run via `sh -c "exec ... --docker_only
   --housekeeping_interval=1s"` (PID 1).
2. `docker-compose.yml` — `cadvisor` service: `privileged`, read-only host
   mounts (docker.sock, /sys, /var/lib/docker, /rootfs), **no host port**, on
   `inception_network`.
3. Role — collector for Prometheus; viewed through Grafana.

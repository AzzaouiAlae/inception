# Redis container — build guide (Inception bonus)

Redis is WordPress's **object cache**. The `redis-cache` plugin stores the
results of expensive operations (option lookups, repeated DB queries) in Redis
memory instead of hitting MariaDB every time, so pages render faster. It has
**no host port** and **no persistence** — it's an in-memory cache reachable only
on `inception_network` as the host `redis`, on port `1024`.

> WordPress connects with `WP_REDIS_HOST=redis`, `WP_REDIS_PORT=1024`.

---

## 0. Rules this container must respect (don't break these)

| Rule | How we satisfy it |
|------|-------------------|
| Base image = penultimate stable Alpine | `FROM alpine:3.23` |
| No `latest` tag, image name = service name | `image: redis:Inception` |
| No ready-made app images | `FROM alpine:3.23` + `apk add redis` (not the official `redis` image) |
| Daemon in foreground as PID 1, no hacks | `exec redis-server ...` — no `tail -f`, no `&` |
| No host `ports:` | Internal `1024` only; reachable as `redis` on `inception_network` |
| Networks declared in compose | Joins `inception_network` |

---

## 1. What's in `requirements/bonus/redis/`

```
requirements/bonus/redis/
└── Dockerfile      # no entrypoint script — single CMD (like Adminer)
```

Like Adminer, Redis has **no setup to do**, so there's no entrypoint script —
just a `CMD`.

---

## 2. The Dockerfile

```dockerfile
FROM alpine:3.23

RUN apk update
RUN apk add --no-cache redis
RUN echo 'vm.overcommit_memory = 1' | tee -a /etc/sysctl.conf

CMD ["sh", "-c", "exec redis-server --protected-mode no --port ${REDIS_PORT}"]
```

What each line does, honestly:
- **`apk add redis`** — the server + `redis-cli`, built on our Alpine base.
- **`--protected-mode no`** — Redis "protected mode" refuses remote connections
  when it has no bound interface/password. We disable it so the `wordpress`
  container can connect over the internal network. This is acceptable **only**
  because Redis is never exposed to the host — it lives entirely on the private
  `inception_network`.
- **`--port $REDIS_PORT`** — listens on `1024` (from `.env`), not the default
  6379. WordPress is told the same port via `WP_REDIS_PORT`.
- **`vm.overcommit_memory = 1` into `/etc/sysctl.conf`** — an attempt to silence
  Redis's startup warning about memory overcommit. ⚠️ Be honest in defense:
  writing `/etc/sysctl.conf` has **no effect inside a container** (it's a host
  kernel setting that nothing re-applies at container start). It's a harmless
  no-op. The real fix would be a host sysctl, or `sysctls:` in compose.

---

## 3. The `CMD`

```dockerfile
CMD ["sh", "-c", "exec redis-server --protected-mode no --port ${REDIS_PORT}"]
```

- JSON array (exec form) → no extra wrapping shell from Docker;
- `sh -c` is needed so `${REDIS_PORT}` expands (a pure exec-form `CMD` would
  not substitute it);
- `exec` → `redis-server` replaces the shell and becomes PID 1, receiving
  signals directly (clean, fast `docker stop`).

Same reasoning as the Adminer and cAdvisor `CMD`s.

---

## 4. The Compose service block

```yaml
  redis:
    build: ./requirements/bonus/redis
    image: redis:Inception
    container_name: redis
    restart: on-failure
    init: true
    networks:
      - inception_network
    env_file:
      - .env
```

Decisions, and why:
- **No `ports:`** — the cache is internal; only `wordpress` reaches it, by the
  DNS name `redis`.
- **No `secrets:`** — no password is configured (internal-only network). Could
  be hardened with `requirepass` via a secret, but it's not required here.
- **No `volumes:`** — an object cache is **ephemeral by design**. If the
  container restarts the cache is cold and simply rebuilds from MariaDB; there's
  nothing worth persisting.
- `init: true`, `restart: on-failure`, `inception_network`, `env_file` — standard.

---

## 5. How WordPress uses it

In `wordpress/conf/wp-config.php`:

```php
define('WP_REDIS_HOST', 'redis');             // the redis container's DNS name
define('WP_REDIS_PORT', getenv('REDIS_PORT')); // 1024, from .env
```

And in `wordpress/tools/script.sh`, on first boot:

```sh
wp plugin install redis-cache --activate --allow-root
wp redis enable --allow-root
```

`wordpress` also has `depends_on: redis` so Redis exists when `wp redis enable`
runs. Together: the plugin is installed/activated, the drop-in is enabled, and
WordPress points at `redis:1024`.

---

## 6. Build and run

```bash
docker compose -f srcs/docker-compose.yml up -d --build redis
# or full stack:
make

docker compose -f srcs/docker-compose.yml ps redis      # Up, no host port
docker compose -f srcs/docker-compose.yml logs redis
```

---

## 7. Verification

```bash
# a. Redis is alive on its port
docker exec redis redis-cli -p 1024 ping                       # -> PONG

# b. WordPress sees the cache as connected
docker exec wordpress wp redis status --allow-root --path=/var/www/html

# c. The cache is actually being used (keys present after browsing the site)
docker exec redis redis-cli -p 1024 dbsize
docker exec redis redis-cli -p 1024 info keyspace

# d. Watch live cache traffic for a moment while you hit the site
timeout 3 docker exec redis redis-cli -p 1024 monitor || true

# e. NOT reachable from the host (no port mapping)
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:1024 || echo "refused (correct)"
```

Expected: (a) `PONG`; (b) status `connected` / `Status: Connected`; (c) a
non-zero `dbsize` and a populated keyspace once the site has been browsed;
(d) `GET`/`SET` commands scrolling by; (e) connection refused on the host.

---

## 8. Defense Q&A (likely evaluator questions)

**Q: What is Redis for in this project?**
It's WordPress's object cache. The `redis-cache` plugin stores expensive
results in memory so repeated requests skip MariaDB, reducing DB load and
speeding up the site.

**Q: How does WordPress connect to it?**
By DNS name on the internal network: `WP_REDIS_HOST=redis`,
`WP_REDIS_PORT=1024` in `wp-config.php`, plus the `redis-cache` plugin enabled
via `wp redis enable`. `depends_on: redis` orders startup.

**Q: Why `--protected-mode no` and no password? Isn't that insecure?**
Redis is on the private `inception_network` only — it has no host port and is
unreachable from outside. Protected mode would otherwise block the cross-
container connection. For stricter hardening you could add `requirepass` via a
Docker secret, but it isn't required here.

**Q: Why no volume? Don't you lose data on restart?**
A cache is meant to be disposable. On restart it starts cold and rebuilds from
MariaDB, which is the source of truth. Persisting it would add no value.

**Q: Is the daemon PID 1?**
Yes — `CMD ["sh","-c","exec redis-server …"]`; `exec` makes `redis-server`
replace the shell and become PID 1 (with `init: true` reaping zombies).

**Q: What's the `vm.overcommit_memory` line doing?**
It tries to quiet Redis's overcommit warning, but editing `/etc/sysctl.conf`
does nothing inside a container (host kernel setting). It's a harmless no-op.

---

## 9. Troubleshooting

- **`wp redis status` says not connected** — Redis not `Up`, wrong port, or the
  drop-in not enabled. Check `redis-cli -p 1024 ping`, that `WP_REDIS_PORT`
  matches `.env` (1024), and re-run `wp redis enable --allow-root`.
- **`DENIED Redis is running in protected mode`** — `--protected-mode no` is
  missing from the `CMD`; the cross-container connection gets refused.
- **`dbsize` is 0** — the cache just hasn't been populated; browse the site a
  few times and re-check (and confirm the plugin is active).
- **Overcommit warning in logs** — expected and harmless (see §2); not a failure.

---

## 10. One-line summary of the parts

1. `bonus/redis/Dockerfile` — Alpine + `apk add redis`, run via
   `sh -c "exec redis-server --protected-mode no --port ${REDIS_PORT}"` (PID 1).
2. `docker-compose.yml` — `redis` service: no host port, no volume, no secret,
   on `inception_network`.
3. WordPress integration — `wp-config.php` (`WP_REDIS_HOST/PORT`) + the
   `redis-cache` plugin enabled in `script.sh`, with `depends_on: redis`.

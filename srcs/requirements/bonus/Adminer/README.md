# Adminer container — build guide (Inception bonus)

Adminer is a single-file PHP database manager (the lightweight alternative to
phpMyAdmin). For this project it gives you a web UI to inspect/manage the
**MariaDB** `wordpress` database. It must obey the same rules as every other
service in the stack, so this guide builds it the "42 way": custom Dockerfile
from `alpine:3.23`, daemon in the foreground as PID 1, reachable **only through
NGINX** (no host port), on the `inception_network`.

> Login `aazzaoui`, domain `aazzaoui.42.fr`. Final URL: `https://aazzaoui.42.fr/adminer/`.

---

## 0. Rules this container must respect (don't break these)

| Rule | How we satisfy it |
|------|-------------------|
| Base image = penultimate stable Alpine | `FROM alpine:3.23` (same as every other service) |
| No `latest` tag, image name = service name | `image: adminer:Inception` |
| No ready-made app images | We start from `alpine:3.23` and download the Adminer **PHP file** ourselves (same idea as downloading wp-cli / the prometheus binary) |
| Daemon in foreground, no hacks | `exec php -S ...` — no `tail -f`, no `sleep infinity`, no `&` |
| No host `ports:` for internal services | Adminer has **no `ports:`** — NGINX reverse-proxies `/adminer/` to it on the internal network |
| Networks declared in compose | Joins `inception_network` |
| No passwords baked into images / `.env` | Adminer login is **interactive in the browser**; the DB password is read by the user from `srcs/secrets/db_password.txt`. Nothing secret is built into the image |

---

## 1. Final layout

```
srcs/
├── .env                              # + ADMINER_PORT=8085
├── docker-compose.yml                # + adminer service block
└── requirements/
    ├── nginx/conf/nginx.sh           # + location /adminer/ { ... }
    └── bonus/Adminer/
        └── Dockerfile                # (this guide replaces the stub)
```

You currently only have `bonus/Adminer/Dockerfile` (a stub). The steps below
flesh it out. No entrypoint script is needed (see §3 for why).

---

## 2. The Dockerfile

Replace the contents of `srcs/requirements/bonus/Adminer/Dockerfile` with:

```dockerfile
FROM alpine:3.23

# Single-file Adminer version to fetch. Check the current stable at
# https://www.adminer.org/ (or the GitHub releases page) and bump as needed.
# Adminer 5.x is the current line; 4.8.1 is the older long-stable release.
ARG ADMINER_VERSION=5.4.2

# PHP runtime + the MySQL driver Adminer needs to reach MariaDB.
#
# IMPORTANT: Alpine ships PHP under a *versioned* package name (php83, php84, …)
# and the binary is /usr/bin/php84 (no bare `php`). Run this once to see what
# Alpine 3.23 actually provides, and adjust the "84" suffix below to match:
#
#     docker run --rm alpine:3.23 sh -c "apk update >/dev/null && apk search -x php8 | sort"
#
RUN apk update && apk add --no-cache \
        php84 \
        php84-session \
        php84-mysqli \
        php84-pdo_mysql \
    && ln -sf /usr/bin/php84 /usr/bin/php

# Download Adminer (one PHP file) and serve it as index.php.
RUN mkdir -p /var/www/adminer \
    && wget -O /var/www/adminer/index.php \
        "https://github.com/vrana/adminer/releases/download/v${ADMINER_VERSION}/adminer-${ADMINER_VERSION}.php"

# Hardcode the port. Do NOT write `EXPOSE ${ADMINER_PORT}` — variables from
# .env / env_file are NOT available at *build* time, so it would expand to
# empty (this is the exact bug the nginx Dockerfile had with EXPOSE 443).
EXPOSE 8085

# `sh -c` so $ADMINER_PORT (from env_file at runtime) gets expanded; `exec` so
# PHP replaces the shell and becomes the process that receives signals — a
# clean `docker stop` with no leftover shell. Foreground, no background tricks.
CMD ["sh", "-c", "exec php -S adminer:${ADMINER_PORT} /var/www/adminer/index.php"]
```

**Why `php -S` and not nginx+php-fpm inside this container?** Adminer is a
single self-contained PHP file. PHP's built-in web server (`php -S`) can serve
it directly with the file acting as the router script — one process, runs in
the foreground, That is the cleanest entrypoint and exactly the
foreground-daemon property the subject wants. We don't need a second web server
here because the real edge server is NGINX.

**Why the symlink (`ln -sf /usr/bin/php84 /usr/bin/php`)?** So the `CMD` can
just call `php`. If Alpine 3.23 ships `php85` instead, you only change the
Dockerfile (package name + symlink target) and the `CMD` line stays the same.

---

## 3. Why no entrypoint script (the `CMD` is enough)

The other services (`nginx.sh`, `prometheus.sh`, `grafana.sh`, the mariadb /
wordpress `script.sh`) each have a script because they do **real setup before
the daemon starts**: generate `nginx.conf`, write `prometheus.yml`, render
`grafana.ini` + provisioning, build `init.sql` with users/grants, wait for the
DB and run `wp core install`. The pattern is "do setup, then `exec`."

Adminer has **no setup to do** — it's one static PHP file and the only command
is the server itself. So a script here would be a one-line wrapper around
`exec php -S ...` with nothing above it; that's not the same pattern, it's an
empty file. It also doesn't need a wait-for-MariaDB loop: `php -S` only opens a
socket to the DB when someone submits the browser login form (MariaDB is up
long before then, and `depends_on` already orders startup). So we inline it.

Three things make the inline `CMD` correct:

- **`sh -c`** — you need a shell to expand `${ADMINER_PORT}`. Pure exec form,
  `CMD ["php","-S","adminer:${ADMINER_PORT}",...]`, would **not** expand it (no
  shell) and PHP would try to bind to the literal string `${ADMINER_PORT}`.
- **`exec`** — without it, `sh` stays as the parent and `php` is its child;
  `sh -c` doesn't forward `SIGTERM`, so `docker stop` would hang until timeout
  then `SIGKILL`. `exec` makes `php` replace the shell and receive signals.
- **`adminer:${ADMINER_PORT}`** — listen on the container's own address
  (resolved via the Docker network) rather than every interface (`0.0.0.0`).
  NGINX in the other container can still reach it by that name; there's no
  host-mapped port and nothing else on this container needs the socket.

If you later add real setup (you won't need to here), promote it to a
`tools/adminer.sh` then — at that point a script earns its place.

---

## 4. Add the port to `.env`

Append to `srcs/.env`:

```env
ADMINER_PORT=8085
```

This is an **internal** port (container ↔ container only). It is never mapped to
the host. 8085 just has to be free *inside the adminer container* and known to
NGINX; pick anything that isn't already used by another service if you prefer.

---

## 5. Add the service to `docker-compose.yml`

Add this block alongside the other services (e.g. after `grafana:`):

```yaml
  adminer:
    depends_on:
      - mariadb
    build: ./requirements/bonus/Adminer
    image: adminer:Inception
    container_name: adminer
    pull_policy: never
    restart: on-failure
    init: true
    networks:
      - inception_network
    env_file:
      - .env
```

Decisions, and why:
- **No `ports:`** — Adminer is reached through NGINX (rule #9 in the work
  order: internal services don't get host ports). This is the whole point.
- **No `secrets:`** — you type the DB password into Adminer's login form in the
  browser, so the container doesn't need any secret file mounted. (Mounting
  one would be a needless secret exposure.)
- **`depends_on: mariadb`** — Adminer is useless until the DB is up; this also
  makes the boot order deterministic.
- **`pull_policy: never`** — same as `nginx`; guarantees Docker never tries to
  pull an `adminer` image from a registry, it only ever uses our local build.
- `restart: on-failure`, `init: true`, `inception_network`, `env_file: .env` —
  identical to the rest of the stack for consistency.

---

## 6. Route it through NGINX — edit `nginx/conf/nginx.sh`

The whole NGINX config is generated by an `echo` where the text is **single-
quoted**, and shell variables are spliced in by *closing* the quote, inserting
`$VAR`, then *reopening* it. So:

- variables that NGINX must resolve at runtime (`$host`, `$remote_addr`,
  `$uri`, …) must stay **inside** the single quotes (NOT shell-expanded);
- variables we want the shell to substitute (our `$ADMINER_PORT`) must be
  **broken out** as `'$ADMINER_PORT'`.

Add this `location` block inside the `server { ... }`, right after the existing
`location /grafana/ { ... }`:

```sh
                location /adminer/ {
                    # Trailing slash strips the /adminer/ prefix so the
                    # PHP server sees "/". Adminer's links are relative, so
                    # the browser stays under /adminer/.
                    proxy_pass http://adminer:'$ADMINER_PORT'/;
                    proxy_set_header Host $host;
                    proxy_set_header X-Real-IP $remote_addr;
                    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                    proxy_set_header X-Forwarded-Proto $scheme;
                }
```

Double-check after editing: `$ADMINER_PORT` is the **only** thing outside the
single quotes in that block; everything starting with `$host` / `$remote_addr`
/ `$proxy_add_x_forwarded_for` / `$scheme` must remain literal.

---

## 7. Build and run

From the project root (`/home/aazzaoui/Desktop/Inception`):

```bash
# rebuild just the new service + the nginx config change, then bring all up
docker compose -f srcs/docker-compose.yml up -d --build adminer nginx

# or a full run via the Makefile
make
```

Check it's healthy:

```bash
docker compose -f srcs/docker-compose.yml ps
# adminer should be "Up", not restarting
docker compose -f srcs/docker-compose.yml logs adminer
# expect: "PHP <ver> Development Server (http://adminer:8085) started"
```

---

## 8. Log in to Adminer

Open: **`https://aazzaoui.42.fr/adminer/`**

Fill the login form:

| Field    | Value |
|----------|-------|
| System   | MySQL / MariaDB |
| Server   | `mariadb`  (the service name = its DNS host on the network; `mariadb:3306` also works) |
| Username | `wp_user`  (the `WP_DB_USER` from `.env`) |
| Password | the contents of `srcs/secrets/db_password.txt` |
| Database | `wordpress` |

Get the password to paste:

```bash
cat srcs/secrets/db_password.txt
```

> **Why not log in as `root`?** MariaDB's `script.sh` creates
> `'root'@'localhost'` only, while the WordPress user is `'wp_user'@'%'`.
> Adminer connects **from another container**, i.e. not localhost, so a remote
> `root` login is refused by design. Use `wp_user` (it has full rights on the
> `wordpress` database, which is all Adminer needs here).

---

## 9. Verification checklist (run these, don't just assume)

```bash
# a. Container is up
docker compose -f srcs/docker-compose.yml ps adminer

# b. PHP + mysqli driver are present in the image
docker exec adminer php -m | grep -E 'mysqli|pdo_mysql'

# c. Adminer answers locally inside the container (login HTML)
docker exec adminer wget -qO- http://localhost:8085/ | grep -io 'adminer' | head -n1

# d. Reachable through NGINX over TLS (this is the graded path)
curl -k --resolve aazzaoui.42.fr:443:127.0.0.1 https://aazzaoui.42.fr/adminer/ | grep -io 'adminer' | head -n1

# e. NOT reachable directly from the host (no host port mapping)
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8085 || echo "refused (correct)"

# f. Adminer can actually reach MariaDB on the network
docker exec adminer sh -c 'nc -z -w2 mariadb 3306 && echo "db reachable"'
```

Expected: (a) `Up`; (b) prints `mysqli` (and/or `pdo_mysql`); (c) and (d) print
`adminer`/`Adminer`; (e) connection refused / no route (good — port isn't
exposed); (f) `db reachable`. The real proof is logging in via the browser and
seeing the `wordpress` tables (`wp_users`, `wp_posts`, …).

---

## 10. Defense Q&A (likely evaluator questions)

**Q: Where does the Adminer image come from? Isn't that a forbidden ready-made image?**
No. We build `FROM alpine:3.23` and `wget` the single Adminer **PHP file** at
build time. We never pull `adminer` from Docker Hub. It's the same pattern as
downloading WordPress, wp-cli, or the prometheus binary — fetching application
source, not a prebuilt image.

**Q: What is PID 1 in this container? Any background process or hack?**
With `init: true`, a tiny init (`docker-init`/tini) is PID 1 to reap zombies and
forward signals; our `CMD` uses `sh -c "exec php -S ..."`, so `php` replaces the
shell and is init's single foreground child — no lingering shell, no
`tail -f` / `sleep infinity` / `&`. If PHP dies the container exits and
`restart: on-failure` handles it.

**Q: How is Adminer exposed? Which port?**
It is **not** exposed to the host. It listens on `8085` only on
`inception_network`. NGINX (the single entrypoint, port 443, TLS 1.2/1.3)
reverse-proxies `https://aazzaoui.42.fr/adminer/` to `http://adminer:8085/`.

**Q: How does Adminer find the database? Are credentials stored anywhere?**
By DNS: the Compose service name `mariadb` resolves on the shared network. No
credentials are stored in the image or `.env`; the evaluator types `wp_user` +
the password from `srcs/secrets/db_password.txt` into the browser login form.

**Q: Why `wp_user` and not `root`?**
`root` exists only as `'root'@'localhost'`; Adminer connects from a different
container (not localhost), so remote root is denied. `wp_user` (`@'%'`) has the
grants on the `wordpress` DB.

**Q: Why hardcode `EXPOSE 8085` instead of `EXPOSE ${ADMINER_PORT}`?**
`env_file` variables are runtime-only; they're empty during `docker build`, so
`EXPOSE ${ADMINER_PORT}` would expose nothing. `EXPOSE` is documentation anyway
— the real listen port is set at runtime by the `CMD` from `$ADMINER_PORT`.

---

## 11. Troubleshooting

- **`adminer` keeps restarting / logs show `php: not found`** — the Alpine PHP
  package name didn't match. Run `apk search -x php8` in `alpine:3.23`, fix the
  `php84*` package names and the `ln -sf` target in the Dockerfile, rebuild.
- **502 Bad Gateway at `/adminer/`** — NGINX can't reach the container. Check
  `adminer` is `Up`, that `proxy_pass` port equals `ADMINER_PORT`, and that the
  `$ADMINER_PORT` in `nginx.sh` is correctly broken **out** of the single quotes
  (otherwise NGINX gets a literal `$ADMINER_PORT`). Rebuild nginx after editing.
- **Login fails with "Access denied"** — wrong user/host. Use `wp_user` (not
  root), server `mariadb`, password = `cat srcs/secrets/db_password.txt` (mind
  trailing newline — type it exactly, or `tr -d '\n'` when copying).
- **Page loads but CSS/links look broken under the subpath** — make sure the
  `proxy_pass` URL ends with a trailing slash (`.../$ADMINER_PORT/;`) so the
  `/adminer/` prefix is stripped before it reaches the PHP server.
- **`nc: not found` in check (f)** — BusyBox `nc` should exist on Alpine; if
  not, test connectivity with
  `docker exec adminer php -r '$c=@fsockopen("mariadb",3306); echo $c?"ok":"no";'`.

---

## 12. One-line summary of every change

1. `bonus/Adminer/Dockerfile` — Alpine + PHP (session/mysqli/pdo_mysql),
   download Adminer file, `EXPOSE 8085`, inline
   `CMD ["sh","-c","exec php -S adminer:${ADMINER_PORT} ..."]` (no script).
2. `srcs/.env` — add `ADMINER_PORT=8085`.
3. `srcs/docker-compose.yml` — add `adminer` service (no ports, depends_on
   mariadb, on inception_network).
4. `nginx/conf/nginx.sh` — add `location /adminer/` reverse-proxy block.

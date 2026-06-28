# NGINX container — build guide (Inception, mandatory)

NGINX is the **single entry point** of the whole stack. It is the only service
exposed to the host, it terminates **TLS (1.2/1.3 only) on port 443**, serves
the WordPress site, and reverse-proxies the bonus apps (`/resume/`, `/grafana/`,
and `/adminer/` once added). Nothing else in the project is reachable from
outside except through NGINX (FTP being the one justified exception).

> Login `aazzaoui`, domain `aazzaoui.42.fr`. URL: `https://aazzaoui.42.fr/`.

---

## 0. Rules this container must respect (don't break these)

| Rule | How we satisfy it |
|------|-------------------|
| Base image = penultimate stable Alpine | `FROM alpine:3.23` |
| No `latest` tag, image name = service name | `image: nginx:Inception` |
| No ready-made app images | `FROM alpine:3.23` + `apk add nginx` (we don't pull the official `nginx` image) |
| Daemon in foreground as PID 1, no hacks | `exec nginx -g 'daemon off;'` — no `tail -f`, no `&` |
| **Only** mandatory entrypoint, port **443 only** | The single `ports:` in the stack is `443:443`; no port 80 |
| **TLS 1.2 / 1.3 only** | `ssl_protocols TLSv1.2 TLSv1.3;` |
| No password in Dockerfile; secrets via Docker secrets | Cert + key are Docker **secrets** mounted at `/run/secrets/`; nothing secret is baked in |
| Networks declared in compose | Joins `inception_network` |

---

## 1. What's in `requirements/nginx/`

```
requirements/nginx/
├── Dockerfile
└── conf/
    ├── nginx.sh      # entrypoint: generates nginx.conf from env vars, then exec
    └── index.html    # placeholder page (shadowed at runtime by the WP volume)
```

---

## 2. The Dockerfile

```dockerfile
FROM alpine:3.23

RUN apk update && \
    apk add --no-cache nginx openssl && \
    mkdir -p /var/www/html && \
    rm -f /etc/nginx/nginx.conf          # drop the distro default so our script writes its own

COPY ./conf/nginx.sh /app/nginx.sh
RUN chmod +x /app/nginx.sh

# Hardcode 443. env_file vars are empty at BUILD time.
EXPOSE 443

CMD ["/app/nginx.sh"]
```

Notes:
- `apk add nginx openssl` — `openssl` is present for cert handling/debugging;
  the actual cert is generated on the host by `setup.sh` (see §5), not here.
- `rm -f /etc/nginx/nginx.conf` — we delete the package's default config so the
  entrypoint's `if [ ! -f ... ]` guard always regenerates ours on first boot.
- at runtime the `wordpress_data` volume is mounted at `/var/www/`.

---

## 3. The entrypoint — `conf/nginx.sh`

Unlike Adminer (one static command, no script needed), NGINX **earns** its
script: it *generates* `/etc/nginx/nginx.conf` at runtime, templating values
from `.env` (`$LINUX_USER_NAME`, `$NGINX_PORT`, `$USER_HOST`, `$PHP_FPM_PORT`,
`$GRAFANA_PORT`) into the config, then execs the daemon.

```sh
#!/bin/sh

if [ ! -f "/etc/nginx/nginx.conf" ]; then
    echo 'user '$LINUX_USER_NAME';
    events { worker_connections 1024; }
    http {
        include /etc/nginx/mime.types;
        ssl_protocols TLSv1.2 TLSv1.3;
        ...
        server {
            listen '$NGINX_PORT' ssl;
            server_name '$USER_HOST';
            root /var/www/html;
            ssl_certificate     /run/secrets/nginx_crt;
            ssl_certificate_key /run/secrets/nginx_key;
            add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

            location / { try_files $uri $uri/ /index.php?$args; }       # WP permalinks
            location ~ \.php$ {
                fastcgi_pass wordpress:'$PHP_FPM_PORT';                  # php-fpm in WP container
                include fastcgi_params;
                fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
            }
            location /resume/  { proxy_pass http://resume:5000/; ... }
            location /grafana/ { proxy_pass http://grafana:'$GRAFANA_PORT'; ... }
        }
    }' > /etc/nginx/nginx.conf
fi

exec nginx -g 'daemon off;'
```

**The single-quote splicing trick (important).** The whole config is one
`echo '...'` in single quotes. Anything that must be substituted *by the shell*
(`$LINUX_USER_NAME`, `$NGINX_PORT`, `$USER_HOST`, `$PHP_FPM_PORT`,
`$GRAFANA_PORT`) is **broken out** of the quotes as `'$VAR'`. Anything that must
stay **literal for NGINX to interpret at request time** (`$uri`, `$args`,
`$host`, `$remote_addr`, `$document_root`, `$fastcgi_script_name`, `$scheme`,
`$http_upgrade`, `$proxy_add_x_forwarded_for`) stays *inside* the single quotes
so the shell never touches it. Get this wrong and either the config has empty
values or NGINX errors on undefined variables.

**`exec nginx -g 'daemon off;'`** — `daemon off;` keeps NGINX in the foreground
and `exec` makes it PID 1 (it receives signals; a clean `docker stop`). No
`tail -f`, no background process.

---

## 4. The Compose service block

```yaml
  nginx:
    build: ./requirements/nginx
    image: nginx:Inception
    container_name: nginx
    restart: on-failure
    init: true
    secrets:
      - nginx_crt
      - nginx_key
    depends_on:
      - wordpress
    ports:
      - "${NGINX_PORT}:${NGINX_PORT}"     # 443:443 — the ONLY host port (besides FTP)
    volumes:
      - wordpress_data:/var/www/          # share WP files with the wordpress container
    networks:
      - inception_network
    env_file:
      - .env
```

Decisions, and why:
- **`secrets: nginx_crt / nginx_key`** — the TLS cert and key are mounted read-
  only at `/run/secrets/`, never baked into the image.
- **`depends_on: wordpress`** — php-fpm should exist before NGINX forwards
  `.php` requests to it (ordering only; not a readiness guarantee).
- **`ports: 443:443`** — the single public port. No `80`. This is what makes
  NGINX *the* entry point.
- **`volumes: wordpress_data:/var/www/`** — NGINX and the WordPress container
  mount the **same** volume at the same path, so the `SCRIPT_FILENAME` NGINX
  computes (`/var/www/html/index.php`) resolves to the identical file php-fpm
  opens in its own container. Without the shared volume, fastcgi would point at
  a path that doesn't exist on the WordPress side.
- `restart: on-failure`, `init: true`, `inception_network`,
  `env_file` — standard across the stack.

---

## 5. TLS certificate (where the secret comes from)

The cert/key are **not** generated in this container. `srcs/requirements/tools/
setup.sh` runs on the host at `make` time and uses **mkcert**:

```sh
$MKCERT_BIN -install
$MKCERT_BIN -key-file srcs/secrets/nginx.key -cert-file srcs/secrets/nginx.crt aazzaoui.42.fr 127.0.0.1
```

Those two files are then declared as Docker secrets in `docker-compose.yml`:

```yaml
secrets:
  nginx_crt: { file: ./secrets/nginx.crt }
  nginx_key: { file: ./secrets/nginx.key }
```

and surface inside the container as `/run/secrets/nginx_crt` and
`/run/secrets/nginx_key`, which is exactly what `ssl_certificate(_key)` points
at in §3.

---

## 6. Build and run

```bash
docker compose -f srcs/docker-compose.yml up -d --build nginx
# or full stack:
make

docker compose -f srcs/docker-compose.yml ps nginx     # Up, 0.0.0.0:443->443
docker compose -f srcs/docker-compose.yml logs nginx
docker exec nginx cat /etc/nginx/nginx.conf            # inspect the generated config
docker exec nginx nginx -t                             # syntax check
```

---

## 7. Verification

```bash
# a. The site answers over HTTPS and is configured (NOT the install page)
curl -k --resolve aazzaoui.42.fr:443:127.0.0.1 https://aazzaoui.42.fr/ | grep -i '<title>'

# b. Port 80 is NOT open (only 443)
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:80 || echo "refused (correct)"

# c. TLS version is 1.2/1.3 only
curl -kv --resolve aazzaoui.42.fr:443:127.0.0.1 https://aazzaoui.42.fr/ 2>&1 | grep -i 'SSL connection\|TLSv1'
echo | openssl s_client -connect 127.0.0.1:443 -servername aazzaoui.42.fr 2>/dev/null | grep -i 'Protocol'

# d. Reverse-proxied bonuses answer through NGINX
curl -k --resolve aazzaoui.42.fr:443:127.0.0.1 https://aazzaoui.42.fr/resume/  | grep -io 'resume\|cv' | head -n1
curl -k --resolve aazzaoui.42.fr:443:127.0.0.1 https://aazzaoui.42.fr/grafana/ -I | head -n1
```

Expected: (a) prints the WordPress site `<title>` (no `wp-admin/install.php`);
(b) connection refused on 80; (c) negotiated protocol is `TLSv1.2`/`TLSv1.3`;
(d) the resume page and a Grafana redirect/login.

---

## 8. Defense Q&A (likely evaluator questions)

**Q: Why is NGINX the only container with a host port?**
The subject requires a single entry point over TLS on 443. Everything else
talks over the internal `inception_network`; users reach WordPress and the
bonuses only through NGINX. (FTP's ports are the one allowed exception.)

**Q: How is TLS configured and where's the certificate?**
`ssl_protocols TLSv1.2 TLSv1.3;` (older protocols disabled). The cert/key are
generated by `mkcert` in `setup.sh` on the host, passed in as Docker secrets,
and read from `/run/secrets/nginx_crt` / `nginx_key`. No cert material is in the
image or `.env`.

**Q: How does NGINX serve WordPress if WordPress is a different container?**
For static files it serves them from the shared `wordpress_data` volume at
`/var/www/html`. For `.php` it does FastCGI to `wordpress:9000` (php-fpm). Both
containers mount the same volume at `/var/www/`, so the `SCRIPT_FILENAME` NGINX
sends resolves to the same file php-fpm opens.

**Q: What is PID 1? Any keep-alive hack?**
`nginx -g 'daemon off;'` launched via `exec` (with `init: true` providing a
reaper). NGINX runs in the foreground as the main process — no `tail -f`, no
`sleep`, no backgrounding.

**Q: Why generate the config in a script instead of COPYing an `nginx.conf`?**
To template `.env` values (`$USER_HOST`, `$NGINX_PORT`, `$PHP_FPM_PORT`,
`$GRAFANA_PORT`, `$LINUX_USER_NAME`) into the config at runtime. This is real
setup work — which is exactly why NGINX has a script and Adminer doesn't.

**Q: What does `try_files $uri $uri/ /index.php?$args;` do?**
Makes WordPress permalinks work: if the requested file/dir doesn't exist, NGINX
hands the request to `index.php` (WordPress's front controller) instead of 404.

**Q: Why hardcode `EXPOSE 443`?**
`EXPOSE ${NGINX_PORT}` would expand to empty at build time (env_file vars are
runtime-only). `EXPOSE` is documentation; the real listen port is `listen 443
ssl;` in the generated config.

---

## 9. Troubleshooting

- **502 Bad Gateway on `/`** — php-fpm isn't reachable. Check `wordpress` is
  `Up`, `fastcgi_pass wordpress:9000` matches `$PHP_FPM_PORT`, and the
  `wordpress_data` volume is mounted in both containers.
- **`SSL_ERROR` / cert warnings** — secrets not mounted or mkcert CA not
  trusted on the host. Confirm `/run/secrets/nginx_crt` exists in the container;
  `-k` (curl) bypasses trust for testing.
- **Config didn't regenerate after an edit** — the `if [ ! -f ... ]` guard skips
  if a config already exists. Rebuild the image (the Dockerfile `rm`s the
  default so first boot always writes ours), or `docker compose up -d --build nginx`.
- **`nginx: [emerg] unknown directive "$something"`** — a shell variable that
  should have stayed literal got expanded (or vice-versa) in `nginx.sh`. Re-check
  the single-quote splicing in §3.
- **Port 80 responds** — you added a `listen 80` or a host `80:80` mapping;
  remove it, 443 only.

---

## 10. One-line summary of the parts

1. `nginx/Dockerfile` — Alpine + nginx/openssl, drop default conf, copy
   `nginx.sh` + `index.html`, `EXPOSE 443`, `CMD ["/app/nginx.sh"]`.
2. `nginx/conf/nginx.sh` — generate `nginx.conf` from env (TLS 1.2/1.3, fastcgi
   to wordpress:9000, `/resume/` + `/grafana/` proxies), then `exec nginx -g 'daemon off;'`.
3. `docker-compose.yml` — `nginx` service: `443:443`, `nginx_crt`/`nginx_key`
   secrets, `depends_on: wordpress`, shared `wordpress_data` volume.
4. Cert/key produced by `tools/setup.sh` (mkcert) → mounted as secrets.

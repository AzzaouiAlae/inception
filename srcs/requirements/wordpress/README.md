# WordPress container — build guide (Inception, mandatory)

This container runs **WordPress on PHP-FPM** (no web server inside it). NGINX
sends `.php` requests to it over FastCGI on port 9000; WordPress talks to
**MariaDB** for data and to **Redis** for object caching. On first boot it
downloads WordPress core, waits for the DB, installs the site, and creates the
**two required users**. It has **no host port** — it's reachable only on
`inception_network` as the host `wordpress`.

> Site title `Inception`. Admin `wp_owner` (no "admin" in the name). Editor
> `aazzaoui`. Domain `aazzaoui.42.fr`.

---

## 0. Rules this container must respect (don't break these)

| Rule | How we satisfy it |
|------|-------------------|
| Base image = penultimate stable Alpine | `FROM alpine:3.23` |
| No `latest` tag, image name = service name | `image: wordpress:Inception` |
| No ready-made app images | `FROM alpine:3.23` + `apk add php84-fpm`, and we `wget` WordPress core ourselves |
| Daemon in foreground, no hacks | `exec php-fpm84 -F` — no `tail -f`, no `&` (the bounded wait-for-DB loop is **not** an infinite loop), we use `init: true` |
| No host `ports:` | Internal `9000` only; NGINX reaches it via FastCGI |
| No password in Dockerfile / `.env` | DB password + salts + WP user/admin passwords are Docker **secrets** read at runtime |
| Two WP users | Admin `wp_owner` (no "admin"), editor `aazzaoui` |
| Data persists / shared | `wordpress_data` volume, shared with `nginx` and `ftp` |

---

## 1. What's in `requirements/wordpress/`

```
requirements/wordpress/
├── Dockerfile
├── conf/
│   └── wp-config.php   # reads DB settings from env + secrets (no plaintext passwords)
└── tools/
    ├── wp-cli          # the wp-cli phar, installed as /bin/wp
    └── script.sh       # entrypoint: setup → download → wait DB → install → users → exec php-fpm
```

---

## 2. The Dockerfile

```dockerfile
FROM alpine:3.23

RUN apk update && apk add --no-cache \
    php84 php84-fpm php84-mysqli php84-curl php84-dom php84-exif \
    php84-fileinfo php84-json php84-mbstring php84-openssl php84-xml \
    php84-zip php84-phar \
    mariadb-client

COPY ./conf/wp-config.php /app/wp-config.php      # OUTSIDE the volume on purpose (see §3)
COPY ./tools/wp-cli       /bin/wp                 # wp-cli phar
COPY ./tools/script.sh    /app/script.sh

RUN chmod +x /app/script.sh
RUN chmod +x /bin/wp
RUN rm -f /etc/php84/php-fpm.conf                 # drop default so the script writes its own pool

CMD ["/app/script.sh"]
```

Notes:
- **PHP extensions** — `mysqli` (DB), plus the set WordPress + wp-cli need
  (`curl`, `dom`, `mbstring`, `xml`, `zip`, `phar`, `exif`, `fileinfo`, `json`,
  `openssl`). `php84-phar` is required to run the `wp` phar.
- **`mariadb-client`** — used by the wait-for-MariaDB loop in §3.
- **`wp-config.php` is copied to `/app`, NOT `/var/www`** — `/var/www` is the
  shared volume; anything copied there in the image would be shadowed at runtime.
  We stage it in `/app` and `cp` it into place in the entrypoint. (See §3.)
- **`rm /etc/php84/php-fpm.conf`** — same pattern as nginx/mariadb: delete the
  default so the entrypoint regenerates the pool config on first boot.

---

## 3. `conf/wp-config.php` — how config flows in without plaintext

No password is written in this file. It pulls everything from the environment
and from Docker secrets:

```php
function get_docker_secret($path) {                       // read a secret file, trimmed
    return file_exists($path) ? trim(file_get_contents($path)) : '';
}

define('DB_NAME',     getenv('DB_NAME'));                 // from .env
define('DB_USER',     getenv('WP_DB_USER'));              // from .env  -> wp_user
define('DB_PASSWORD', get_docker_secret('/run/secrets/db_password'));   // secret
define('DB_HOST',     getenv('DB_HOST'));                 // from .env  -> mariadb:3306

define('WP_REDIS_HOST', 'redis');                         // redis container
define('WP_REDIS_PORT', getenv('REDIS_PORT'));            // from .env  -> 1024
define('FS_METHOD', 'direct');                            // write files directly (no FTP creds)

eval(get_docker_secret('/run/secrets/salts'));            // salts.txt contains define()s
$table_prefix = 'wp_';
```

Two details that matter:
- **`getenv(...)` only works because php-fpm is configured with `clear_env =
  no`** (see §4). By default php-fpm strips the environment and `getenv` would
  return empty → DB connection failure. This is a classic gotcha.
- **`eval(get_docker_secret('/run/secrets/salts'))`** — `salts.txt` (fetched by
  `setup.sh` from the WordPress salt API) literally contains PHP
  `define('AUTH_KEY', '...');` lines, so we `eval` the secret to inject them.

---

## 4. The entrypoint — `tools/script.sh`

WordPress has the most setup of any service, so its script does the most before
`exec`. Phases, in order:

```sh
#!/bin/sh

# 1) Create the runtime user with an EXPLICIT uid/gid so it matches the FTP
#    container (otherwise FTP, on a different uid, can't write WP files).
addgroup -g 2000 $LINUX_GROUP_NAME 2>/dev/null || true
adduser -D -u 2000 -G $LINUX_GROUP_NAME -s /bin/sh $LINUX_USER_NAME 2>/dev/null || true

# 2) Generate the php-fpm pool (listen on 9000, run as nginx, clear_env=no!).
if [ ! -f /etc/php84/php-fpm.conf ]; then
  echo '[www]
  user = '$LINUX_USER_NAME'
  group = '$LINUX_GROUP_NAME'
  listen = wordpress:'$PHP_FPM_PORT'
  pm = dynamic
  ...
  clear_env = no' > /etc/php84/php-fpm.conf      # clear_env=no => getenv() works in wp-config.php
fi

# 3) Put wp-config.php in place from the staged copy (every boot).
mkdir -p /var/www/html
cp /app/wp-config.php /var/www/html/wp-config.php

# 4) First-boot only: download core, wait for DB, install, create users.
if [ ! -f /var/www/html/index.php ]; then
  cd /var/www
  wget https://wordpress.org/latest.tar.gz && tar -xzf latest.tar.gz && rm latest.tar.gz
  cp -r wordpress/* html/ && rm -rf wordpress
  cd /var/www/html
  chown -R $LINUX_USER_NAME:$LINUX_GROUP_NAME /var/www/html && chmod -R 755 /var/www/html

  # bounded wait-for-MariaDB (max 60 tries, NOT an infinite loop)
  i=0
  until mariadb -h mariadb -P "${MARIADB_PORT}" -u "$WP_DB_USER" \
        -p"$(cat /run/secrets/db_password)" -e 'SELECT 1' "$DB_NAME" >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -ge 60 ] && { echo "MariaDB unreachable"; exit 1; }
    echo "MariaDB not ready ($i/60)..."; sleep 1
  done

  # install the site (admin = wp_owner)
  wp core install --url="${USER_HOST}" --title="Inception" \
    --admin_user="${WP_ADMIN}" --admin_password="$(cat /run/secrets/wp_admin_password)" \
    --admin_email="${WP_ADMIN}@${USER_HOST_EMAIL}" --skip-email --allow-root

  # second required user: editor 'aazzaoui'
  wp user create ${USER} ${USER}@${USER_HOST_EMAIL} --role=editor \
    --user_pass="$(cat /run/secrets/wp_user_password)" --allow-root

  # reassign the sample post to the editor (ID resolved dynamically)
  EDITOR_ID=$(wp user get ${USER} --field=ID --allow-root)
  wp post update 1 --post_author="$EDITOR_ID" --allow-root

  wp theme install twentytwentyfour --activate --allow-root   # install THEN activate
  wp plugin install redis-cache --activate --allow-root
  wp redis enable --allow-root                                # turn on object cache

  chown -R $LINUX_USER_NAME:$LINUX_GROUP_NAME /var/www/html
fi

exec php-fpm84 -F     # foreground (-F) => PID 1, no backgrounding
```

Why each tricky bit is there:
- **Explicit `-u 2000 / -g 2000`** — the FTP container creates the same `nginx`
  user; pinning the numeric uid/gid in *both* makes file ownership line up so
  FTP can actually write WordPress files.
- **`clear_env = no`** — without it `getenv()` in `wp-config.php` returns empty
  and WordPress can't find the DB. Essential.
- **`cp /app/wp-config.php` every boot** — because `/var/www` is a shared
  volume, the build-time file would be shadowed; staging in `/app` and copying
  at runtime guarantees the config is present regardless of volume seeding.
- **Bounded wait-for-DB** — `wp core install` fails if MariaDB isn't up yet.
  Max 60 attempts then abort — a finite loop, allowed by the subject (unlike
  `while true`).
- **`--allow-root` on every `wp` command** — the container runs as root and
  wp-cli refuses to run as root without it; missing it is why the second user
  silently failed before.
- **`EDITOR_ID=$(wp user get ... --field=ID)`** — resolve the editor's ID
  instead of hardcoding `2`, which is brittle.
- **`theme install ... --activate`** — install the theme first so activation
  can't fail on a theme that isn't bundled.
- **`exec php-fpm84 -F`** — `-F` keeps php-fpm in the foreground; `exec` makes
  it PID 1 (clean signals, with `init: true` reaping).

---

## 5. The Compose service block

```yaml
  wordpress:
    depends_on:
      - mariadb
      - redis
    build: ./requirements/wordpress
    image: wordpress:Inception
    init: true
    container_name: wordpress
    volumes:
      - wordpress_data:/var/www/
    secrets:
      - db_password
      - salts
      - wp_user_password
      - wp_admin_password
    networks:
      - inception_network
    restart: on-failure
    env_file:
      - .env
```

Decisions, and why:
- **`depends_on: mariadb, redis`** — order startup so the DB exists for
  `wp core install` and Redis exists for `wp redis enable` (the bounded loop
  still covers the race; `depends_on` is ordering, not readiness).
- **No `ports:`** — NGINX FastCGI-proxies to `wordpress:9000` internally.
- **`volumes: wordpress_data:/var/www/`** — the WordPress files live here and
  are shared with `nginx` (serves them / FastCGI paths) and `ftp` (uploads).
- **`secrets:`** — `db_password`, `salts`, `wp_user_password`,
  `wp_admin_password`, mounted read-only at `/run/secrets/`.

---

## 6. The shared `wordpress_data` volume + the uid story

```yaml
volumes:
  wordpress_data:
    driver: local
    driver_opts: { type: none, device: ${HOME}/data/wordpress, o: bind }
```

Three containers mount this same volume at `/var/www/`:
- **wordpress** — owns/creates the files (php-fpm writes here).
- **nginx** — serves static files and computes FastCGI `SCRIPT_FILENAME` paths
  that must match what php-fpm opens.
- **ftp** — lets you upload into the site over FTP.

Because all three touch the same files, ownership must agree. The WordPress and
FTP containers both create the `nginx` user with **uid/gid 2000** explicitly, so
a file written by one is writable by the other. The WordPress container is the
one that **seeds** the volume on first boot (downloads core into it).

---

## 7. Secrets (where the values come from)

`srcs/requirements/tools/setup.sh` on the host:

```sh
openssl rand -base64 24 > srcs/secrets/db_password.txt        # used by mariadb
openssl rand -base64 10 > srcs/secrets/wp_admin_password.txt  # wp_owner
openssl rand -base64 10 > srcs/secrets/wp_user_password.txt   # aazzaoui
curl -s https://api.wordpress.org/secret-key/1.1/salt/ > srcs/secrets/salts.txt
```

These surface as `/run/secrets/{db_password,wp_admin_password,wp_user_password,
salts}` and are read by `script.sh` / `wp-config.php`. Nothing is in the image
or in `.env`.

---

## 8. Build and run

```bash
docker compose -f srcs/docker-compose.yml up -d --build wordpress
# or full stack:
make

docker compose -f srcs/docker-compose.yml logs -f wordpress   # watch the first-boot setup
docker compose -f srcs/docker-compose.yml ps wordpress        # Up, no host port
```

---

## 9. Verification

```bash
# a. Both required users exist with correct roles
docker exec wordpress wp user list --allow-root --path=/var/www/html

# b. The site is installed (NOT the install page), via NGINX
curl -k --resolve aazzaoui.42.fr:443:127.0.0.1 https://aazzaoui.42.fr/ | grep -i '<title>'
curl -k --resolve aazzaoui.42.fr:443:127.0.0.1 https://aazzaoui.42.fr/ | grep -ci 'wp-admin/install.php'

# c. Redis object cache is connected
docker exec wordpress wp redis status --allow-root --path=/var/www/html

# d. php-fpm is listening on 9000 inside the container
docker exec wordpress sh -c 'ps aux | grep -i [p]hp-fpm'

# e. wp-config got its env (DB settings resolved)
docker exec wordpress wp config get DB_HOST --allow-root --path=/var/www/html
```

Expected: (a) `wp_owner` = administrator **and** `aazzaoui` = editor; (b) prints
the `Inception` title and `0` matches for the install page; (c) status
`connected`; (d) master + worker php-fpm processes; (e) `mariadb:3306`.

---

## 10. Defense Q&A (likely evaluator questions)

**Q: There's no web server in this container — how is WordPress served?**
WordPress runs as **PHP-FPM** listening on `9000`. NGINX terminates TLS and
forwards `.php` requests over FastCGI to `wordpress:9000`. Separation of
concerns: one web server (NGINX), one app runtime (php-fpm).

**Q: Why copy `wp-config.php` to `/app` and `cp` it at runtime instead of
straight to `/var/www`?**
`/var/www` is the shared `wordpress_data` volume; a file baked there in the
image is shadowed at runtime. Staging it in `/app` (outside the volume) and
copying it in the entrypoint guarantees it's present no matter how the volume
seeds.

**Q: Where are the passwords? Any plaintext?**
None in the image or `.env`. DB password, WP admin/editor passwords, and the
salts are Docker secrets read from `/run/secrets/`; `wp-config.php` reads them
via `get_docker_secret()` and `getenv()`.

**Q: Your script has a loop — isn't that a forbidden keep-alive?**
It's a **bounded** wait-for-MariaDB (max 60 tries, then it aborts). That's a
finite retry, not `while true` / `tail -f`. The actual long-running process is
`php-fpm84 -F` via `exec`.

**Q: What are the two users and why `wp_owner`?**
`wp_owner` (administrator) and `aazzaoui` (editor). The subject forbids an admin
name containing "admin", so we use `wp_owner`.

**Q: How does Redis caching get enabled?**
`wp plugin install redis-cache --activate` then `wp redis enable`; `wp-config.php`
sets `WP_REDIS_HOST=redis` and `WP_REDIS_PORT`. `depends_on: redis` orders it.

**Q: Why `clear_env = no` in the php-fpm pool?**
So php-fpm passes the container environment through to PHP; `wp-config.php` uses
`getenv()` for `DB_NAME`/`WP_DB_USER`/`DB_HOST`/`REDIS_PORT`. Without it those
are empty and the DB connection fails.

**Q: What is PID 1?**
`php-fpm84 -F` via `exec` (foreground, with `init: true`). No background tricks.

---

## 11. Troubleshooting

- **Browser shows `wp-admin/install.php`** — `wp core install` didn't run/finish.
  Check the first-boot logs, that MariaDB came up within 60s, and that the four
  secrets are mounted.
- **"Error establishing a database connection"** — usually `clear_env = no`
  missing, wrong `DB_HOST`, or `db_password` secret mismatch between mariadb and
  wordpress (they share `db_password.txt`).
- **Only `wp_owner` exists, no `aazzaoui`** — a `wp` command ran without
  `--allow-root` (it silently fails as root). Every `wp` call needs it.
- **FTP can't write WordPress files** — uid/gid mismatch; both wordpress and ftp
  must create `nginx` with `-u 2000 -g 2000`.
- **`wp redis status` says not connected** — Redis not up yet at enable time;
  confirm `depends_on: redis`, the `redis` container is `Up`, and `WP_REDIS_PORT`
  matches `.env` (1024).
- **Re-running setup** — the install block is guarded by `index.php` existing.
  To force a clean reinstall, clear `${HOME}/data/wordpress` (destroys data).

---

## 12. One-line summary of the parts

1. `wordpress/Dockerfile` — Alpine + php84-fpm + extensions + mariadb-client,
   stage `wp-config.php` in `/app`, install wp-cli, drop default fpm conf.
2. `wordpress/conf/wp-config.php` — DB/redis settings from `getenv()` + secrets,
   salts via `eval`, no plaintext.
3. `wordpress/tools/script.sh` — uid 2000 user, php-fpm pool (`clear_env=no`),
   copy wp-config, download core, bounded wait-for-DB, `wp core install`, create
   both users, theme + redis, then `exec php-fpm84 -F`.
4. `docker-compose.yml` — `wordpress` service: no host port, `wordpress_data`
   volume (shared with nginx/ftp), four secrets, `depends_on: mariadb, redis`.

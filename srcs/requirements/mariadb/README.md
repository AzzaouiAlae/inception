# MariaDB container — build guide (Inception, mandatory)

MariaDB is the **database** for the stack. WordPress (and Adminer, once added)
connect to it over the internal network. It has **no host port** — it is only
reachable on `inception_network` as the host `mariadb` on port 3306. Its data
lives in a named volume so it survives container restarts and recreation.

> DB name `wordpress`. App user `wp_user`. Domain `aazzaoui.42.fr`.

---

## 0. Rules this container must respect (don't break these)

| Rule | How we satisfy it |
|------|-------------------|
| Base image = penultimate stable Alpine | `FROM alpine:3.23` |
| No `latest` tag, image name = service name | `image: mariadb:Inception` |
| No ready-made app images | `FROM alpine:3.23` + `apk add mariadb` (not the official `mariadb`/`mysql` image) |
| Daemon in foreground as PID 1, no hacks | `exec mariadbd --user=mysql ...` — no `tail -f`, no `&` |
| No host `ports:` | Internal `3306` only; reachable as `mariadb` on `inception_network` |
| No password in Dockerfile; secrets via Docker secrets | Root + app passwords are Docker **secrets** read at runtime from `/run/secrets/`; nothing secret is baked in |
| Data persists | Named volume `mariadb_data` (bind to `${HOME}/data/mariadb`) |
| WP DB users | App user `wp_user` (created here); WP admin/editor users are created later by the WordPress container |

---

## 1. What's in `requirements/mariadb/`

```
requirements/mariadb/
├── Dockerfile
└── tools/
    └── script.sh     # entrypoint: write my.cnf, build init.sql from secrets, then exec mariadbd
```

---

## 2. The Dockerfile

```dockerfile
FROM alpine:3.23

RUN apk update
RUN apk add --no-cache mariadb mariadb-client
RUN mkdir -p /run/mysqld
RUN chown -R mysql:mysql /run/mysqld

COPY ./tools/script.sh /app/script.sh
RUN chmod +x /app/script.sh

CMD ["/app/script.sh"]
```

Notes:
- **`mariadb-client`** is installed so we can use `mariadb`/`mariadb-admin` from
  inside the container for checks (and so other tooling has a client available).
- **`mkdir /run/mysqld` + `chown mysql`** — the server needs a writable socket/
  PID directory owned by the `mysql` user.
- **No `mariadb-install-db` in the Dockerfile** — system tables are initialized
  at **runtime** by `script.sh` when it sees the persistent volume is empty
  (see §3 and §5).

---

## 3. The entrypoint — `tools/script.sh`

Like nginx (and unlike Adminer), MariaDB **earns** its script: it generates
`my.cnf`, then builds an `init.sql` from the **secret** files to create the
database, the app user, and the grants — then execs the daemon with that SQL.

```sh
#!/bin/sh

echo "Starting MariaDB server setup..."

# 1. ALWAYS recreate the configuration file so it's fresh
echo "Writing MariaDB configuration file..."
echo '[server]
[mysqld]
datadir = /var/lib/mysql
port = '${MARIADB_PORT}'
bind-address=mariadb
[galera]
[embedded]
[mariadb]
[mariadb-10.5]
' > /etc/my.cnf

# 2. Check the PERSISTENT VOLUME directory, not the temporary cnf file
if [ ! -d /var/lib/mysql/mysql ]; then
    echo "Volume is empty! Initializing MariaDB system tables..."
    mariadb-install-db --user=mysql --datadir=/var/lib/mysql

    echo "Creating initialization SQL script..."
    DB_PASSWORD=$(cat /run/secrets/db_password)
    DB_ROOT_PASSWORD=$(cat /run/secrets/db_root_password)

    echo "CREATE DATABASE IF NOT EXISTS ${DB_NAME};
    CREATE USER IF NOT EXISTS '${WP_DB_USER}'@'%' IDENTIFIED BY '$DB_PASSWORD';
    GRANT SELECT, INSERT, UPDATE, DELETE, ALTER, CREATE, DROP, INDEX, REFERENCES ON ${DB_NAME}.* TO '${WP_DB_USER}'@'%';
    ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
    FLUSH PRIVILEGES;" > /tmp/init.sql

    echo "Starting MariaDB with initialization setup..."
    exec mariadbd --user=mysql --datadir=/var/lib/mysql --init-file=/tmp/init.sql
else
    echo "Database data detected in named volume. Skipping initialization."
    echo "Starting MariaDB in the foreground..."
    exec mariadbd --user=mysql --datadir=/var/lib/mysql
fi
```

Why it's built this way:
- **`bind-address=mariadb`** — MariaDB must accept connections from the
  `wordpress` (and `adminer`) containers, which arrive over the network, not via
  the local socket. Binding to the container's own name (resolved on the
  `inception` Docker network) instead of `0.0.0.0` means the socket only comes
  up on that network interface — it won't also bind a loopback/host-mapped
  interface that isn't needed, since MariaDB's port is never published to the
  host.
- **Always rewrite `my.cnf`** — the config is written fresh on every start so
  port/bind settings from `.env` are always current, while the data stays in the
  persistent volume.
- **Guard keys on `/var/lib/mysql/mysql`** — that directory exists only after
  `mariadb-install-db` has run, so checking it tells us whether the *persistent*
  volume has already been initialized.
- **`--init-file=/tmp/init.sql`** — the server runs this SQL *as part of its own
  startup*. No need to start the server, wait for it, then connect with a client
  — it's atomic and runs before the server accepts connections.
- **`IF NOT EXISTS` everywhere** — the init is **idempotent**. Even if the guard
  misfires, re-running it against initialized data does no harm; nothing is
  duplicated or reset (the app user keeps its password).
- **`'root'@'localhost'` only** — root has no `@'%'` entry, so **remote root
  login is impossible by design**. Apps use `wp_user@'%'`, scoped to the
  `wordpress` database with exactly the grants WordPress needs.
- **`exec mariadbd ... --user=mysql`** — foreground, PID 1 (with `init: true`
  reaping). No `tail -f`, no background process.

---

## 4. The Compose service block

```yaml
  mariadb:
    build: ./requirements/mariadb
    image: mariadb:Inception
    init: true
    container_name: mariadb
    volumes:
      - mariadb_data:/var/lib/mysql
    secrets:
      - db_password
      - db_root_password
    networks:
      - inception_network
    restart: on-failure
    env_file:
      - .env
```

Decisions, and why:
- **No `ports:`** — the DB is never exposed to the host; only containers on
  `inception_network` reach it (as the DNS name `mariadb`).
- **No `depends_on`** — MariaDB is a base dependency; `wordpress` depends on
  *it*, not the other way around.
- **`volumes: mariadb_data:/var/lib/mysql`** — persistence (see §5).
- **`secrets:`** — root and app passwords mounted read-only at `/run/secrets/`.
- `init: true`, `restart: on-failure`, `inception_network`, `env_file` — standard.

---

## 5. Volume & persistence (the part evaluators probe)

```yaml
volumes:
  mariadb_data:
    driver: local
    driver_opts:
      type: none
      device: ${HOME}/data/mariadb
      o: bind
```

This is a **named volume** that uses the `local` driver bound to
`${HOME}/data/mariadb` — the standard accepted 42 approach (`docker volume
inspect srcs_mariadb_data` shows `device: /home/aazzaoui/data/mariadb`).

**Runtime initialization vs. build-time seeding:**
`mariadb-install-db` is run by `script.sh` only when `/var/lib/mysql/mysql` is
missing — i.e., when the named volume is empty. Because the volume is mounted at
`/var/lib/mysql`, the system tables created by `mariadb-install-db` are written
directly into the persistent directory. On subsequent starts the guard sees the
existing `mysql` system database and skips initialization, so the data survives
`docker compose down`/`up` and container recreation.

---

## 6. Secrets (where the passwords come from)

`srcs/requirements/tools/setup.sh` generates them on the host at `make` time:

```sh
openssl rand -base64 24 > srcs/secrets/db_password.txt        # wp_user password
openssl rand -base64 24 > srcs/secrets/db_root_password.txt   # root password
```

Declared as secrets in compose and surfaced inside the container as
`/run/secrets/db_password` and `/run/secrets/db_root_password`, which is exactly
what `script.sh` reads. Nothing is in the image or in `.env`.

---

## 7. Build and run

```bash
docker compose -f srcs/docker-compose.yml up -d --build mariadb
# or full stack:
make

docker compose -f srcs/docker-compose.yml ps mariadb     # Up, no host port
docker compose -f srcs/docker-compose.yml logs mariadb
```

---

## 8. Verification

```bash
# a. Databases + the wordpress DB exist
docker exec mariadb mariadb -u root -p"$(cat srcs/secrets/db_root_password.txt)" \
    -e 'SHOW DATABASES; USE wordpress; SHOW TABLES;'

# b. The app user exists with the right host scope
docker exec mariadb mariadb -u root -p"$(cat srcs/secrets/db_root_password.txt)" \
    -e "SELECT User,Host FROM mysql.user WHERE User='wp_user';"

# c. The app user can actually log in (from inside; over the socket here)
docker exec mariadb mariadb -u wp_user -p"$(cat srcs/secrets/db_password.txt)" \
    -e 'SELECT 1;' wordpress

# d. The volume is the bind under ~/data
docker volume inspect srcs_mariadb_data | grep -A4 Options

# e. Persistence: recreate and confirm data survives
docker compose -f srcs/docker-compose.yml down
docker compose -f srcs/docker-compose.yml up -d
docker exec mariadb mariadb -u root -p"$(cat srcs/secrets/db_root_password.txt)" \
    -e 'SHOW DATABASES;' | grep wordpress
```

Expected: (a) lists `wordpress` + its `wp_*` tables; (b) shows `wp_user | %`;
(c) returns `1`; (d) `device: /home/aazzaoui/data/mariadb`, `o: bind`; (e) still
prints `wordpress` after the recreate.

---

## 9. Defense Q&A (likely evaluator questions)

**Q: `mariadb-install-db` runs in the entrypoint, but a volume mounts over
`/var/lib/mysql`. Where do the system tables end up?**
They are written directly into the named volume. The script checks
`/var/lib/mysql/mysql` (inside the mounted volume) and only runs
`mariadb-install-db` when that directory is absent. The volume is the source of
truth, so the tables persist across container recreation.

**Q: Where are the passwords? Are any in the image or `.env`?**
No. They're Docker secrets generated by `setup.sh` (`openssl rand`) and read at
runtime from `/run/secrets/db_password` and `/run/secrets/db_root_password`.

**Q: Can you log in as root remotely?**
No. Only `'root'@'localhost'` exists, so remote root is refused. Applications use
`'wp_user'@'%'`, limited to the `wordpress` database with specific grants.

**Q: How does WordPress reach the DB? Why `bind-address=mariadb`?**
By the Compose DNS name `mariadb` on port 3306 over `inception_network`.
`bind-address=mariadb` lets the server accept those network connections (a
local socket wouldn't reach another container), while binding only to that
container's own address instead of every interface (`0.0.0.0`) — the port is
never published to the host, so it has no business listening anywhere else.

**Q: What is PID 1? Any keep-alive hack?**
`mariadbd --user=mysql` via `exec` (with `init: true`). Foreground daemon, no
`tail -f` / `sleep` / `&`.

**Q: Why a script here when Adminer didn't need one?**
Real setup: generate `my.cnf` and build `init.sql` from the secret files before
the daemon starts. That work can't live in a bare `CMD`. Adminer had no setup.

**Q: Why `--init-file` instead of starting the server then running SQL?**
The server executes the file during its own startup — atomic, runs before it
accepts connections, and needs no wait-for-ready loop or background client.

---

## 10. Troubleshooting

- **`ERROR 1045 Access denied for 'root'@<container>`** — that's by design;
  root is localhost-only. Connect as `wp_user` from other containers.
- **Container keeps restarting** — check both secrets are mounted
  (`docker exec mariadb ls /run/secrets`), the datadir is writable, and `my.cnf`
  is valid (`docker exec mariadb cat /etc/my.cnf`).
- **WordPress can't connect** — confirm `bind-address=mariadb`, both containers
  are on `inception_network`, and the WP `db_password` secret matches
  `db_password.txt` (same file feeds both).
- **`ls ~/data/mariadb` shows nothing / permission denied** — expected: files
  are owned by the container's `mysql` uid (100), dir mode 750. Inspect from
  inside the container.
- **Data gone after `down`** — make sure `${HOME}/data/mariadb` still exists and
  the volume still binds to it; the directory is the source of truth.

---

## 11. One-line summary of the parts

1. `mariadb/Dockerfile` — Alpine + mariadb/mariadb-client, create `/run/mysqld`,
   copy `script.sh`, `CMD ["/app/script.sh"]`.
2. `mariadb/tools/script.sh` — write fresh `my.cnf`, initialize system tables
   only when `/var/lib/mysql/mysql` is absent, build `init.sql` from secrets
   (DB + `wp_user` + grants + root password), then `exec mariadbd --init-file`.
3. `docker-compose.yml` — `mariadb` service: no host port, `mariadb_data` volume,
   `db_password`/`db_root_password` secrets.
4. Volume `mariadb_data` → `${HOME}/data/mariadb` (bind); system tables and DB
   data are initialized at runtime directly inside the volume and persist across
   recreation.

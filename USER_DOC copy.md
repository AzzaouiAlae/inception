# USER_DOC.md — User documentation

This guide explains how to run and use the Inception stack as an **end user or
administrator**. No development knowledge is required. For internals and
development, see [DEV_DOC.md](DEV_DOC.md).

---

## 1. What this stack provides

A complete, self-hosted WordPress website served securely over HTTPS, plus
supporting services. Everything runs in Docker containers.

| Service | What it's for | How you reach it |
|---------|---------------|------------------|
| **NGINX** | Secure entry point (HTTPS, TLS 1.2/1.3) | `https://aazzaoui.42.fr` (port 443) — the only public door |
| **WordPress** | The website and its admin panel | through NGINX (`/` and `/wp-admin`) |
| **MariaDB** | The database behind WordPress | internal only |
| **Redis** | Speeds up WordPress (object cache) | internal only |
| **FTP** | File access to the WordPress files | `ftp://aazzaoui.42.fr:2121` |
| **Resume** | A small static personal/showcase site | `https://aazzaoui.42.fr/resume/` |
| **Adminer** | Web UI to inspect/manage the MariaDB database | `https://aazzaoui.42.fr/adminer/` |
| **Grafana** | Monitoring dashboards | `https://aazzaoui.42.fr/grafana/` |
| **Prometheus / cAdvisor** | Collect & store metrics for Grafana | internal only |

> Only **port 443** (and the FTP ports) are exposed to your machine. All other
> services talk to each other over a private Docker network.

---

## 2. One-time setup

1. Install **Docker** and the **Docker Compose** plugin.
2. Make the domain resolve to your machine (needed for HTTPS to work):
   ```bash
   echo "127.0.0.1 aazzaoui.42.fr" | sudo tee -a /etc/hosts
   ```

That's it — credentials and certificates are generated automatically on first run.

---

## 3. Start and stop the project

All commands are run from the **repository root** (where the `Makefile` is).

| Action | Command |
|--------|---------|
| **Start everything** (build first time) | `make` |
| **Stop** the containers (keep data) | `make stop` |
| **Start** stopped containers again | `make start` |
| **Remove** containers + images | `make clean` |
| **Full reset** (also deletes data, volumes, secrets) | `make fclean` |
| **Rebuild from clean** | `make re` |

The first `make` takes a few minutes (it builds all images and installs
WordPress). After that, the site is live at **https://aazzaoui.42.fr**.

> ⚠️ `make fclean` is destructive — it deletes the database, the website files in
> `~/data`, and all generated secrets. Use `make stop` for an ordinary shutdown.

---

## 4. Access the website and the admin panel

- **Website:** https://aazzaoui.42.fr
  Your browser will trust the certificate because setup installs a local CA
  (`mkcert`). If you see a warning, it's safe to proceed for this local project.
- **Admin panel:** https://aazzaoui.42.fr/wp-admin
  Log in with the **administrator** account (see credentials below).

Other entry points:
- **Resume site:** https://aazzaoui.42.fr/resume/
- **Adminer (database UI):** https://aazzaoui.42.fr/adminer/ — log in with:
  | Field | Value |
  |-------|-------|
  | System | MySQL / MariaDB |
  | Server | `mariadb` |
  | Username | `wp_user` |
  | Password | contents of `srcs/secrets/db_password.txt` |
  | Database | `wordpress` |
- **Grafana monitoring:** https://aazzaoui.42.fr/grafana/ (dashboards are
  viewable anonymously; log in as admin to edit).

---

## 5. Locate and manage credentials

All credentials are **generated automatically** on first run and stored locally
in `srcs/secrets/` (this folder is git-ignored — credentials are never committed).

| File in `srcs/secrets/` | What it is |
|-------------------------|------------|
| `wp_admin_password.txt` | WordPress **admin** (`wp_owner`) password — for `/wp-admin` |
| `wp_user_password.txt` | WordPress **editor** (`aazzaoui`) password |
| `db_password.txt` | WordPress database user password |
| `db_root_password.txt` | MariaDB root password |
| `ftp_password.txt` | FTP user (`nginx`) password |
| `grafana_password.txt` | Grafana admin password |
| `nginx.crt` / `nginx.key` | TLS certificate and key |
| `salts.txt` | WordPress security salts |

**Accounts:**
- WordPress admin → user **`wp_owner`**, password in `wp_admin_password.txt`
- WordPress editor → user **`aazzaoui`**, password in `wp_user_password.txt`
- FTP login → user **`nginx`**, password in `ftp_password.txt`, server
  `aazzaoui.42.fr:2121`
- Grafana → user **`aazzaoui`**, password in `grafana_password.txt`

To read a password (example):
```bash
cat srcs/secrets/wp_admin_password.txt
```

To **rotate** all credentials: `make fclean` (removes secrets), then `make`
(regenerates them). Note this also wipes the site data.

---

## 6. Check that the services are running correctly

```bash
# List all containers and their status (look for "Up")
docker compose -f srcs/docker-compose.yml ps

# Watch logs (all services, follow)
docker compose -f srcs/docker-compose.yml logs -f

# Logs for one service, e.g. wordpress
docker compose -f srcs/docker-compose.yml logs wordpress
```

Quick functional checks:
```bash
# Website responds over HTTPS
curl -k -I https://aazzaoui.42.fr            # -> HTTP/1.1 200 / 301

# WordPress sees the Redis cache
docker exec wordpress wp redis status --allow-root --path=/var/www/html

# Database is alive
docker exec mariadb mariadb-admin ping -uroot -p"$(cat srcs/secrets/db_root_password.txt)"
```

Everything healthy looks like: all containers `Up`, the site returns a page over
HTTPS, and you can log in to `/wp-admin`.

---

## 7. Common issues

- **Browser certificate warning** — expected for a local domain; proceed. If it
  blocks you, re-run `make` (which runs `mkcert -install`).
- **`aazzaoui.42.fr` doesn't load** — the hosts-file line (section 2) is missing.
- **Site not ready right after `make`** — WordPress is still installing on first
  boot; wait a minute and check `logs wordpress`.
- **Forgot a password** — read the matching file in `srcs/secrets/` (section 5).

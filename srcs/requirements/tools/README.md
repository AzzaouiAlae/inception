# tools — host-side setup script (Inception)

`tools/` is **not a container**. It holds `setup.sh`, the one-time host
preparation step that runs *before* `docker compose` starts anything. It
generates the TLS certificate and every secret the stack consumes, fetches the
WordPress salts, and creates the bind-mount data directories. The `Makefile`
calls it via the `setup` target, on which `run` depends.

> Order of events: `make` → `setup` (this script) → `docker compose up --build`.
> The containers never generate their own secrets; they only **read** the files
> this script produced, mounted at `/run/secrets/...`.

---

## 0. Why this exists (the rule it satisfies)

| Rule | How `setup.sh` satisfies it |
|------|------------------------------|
| Passwords must **not** be in the Dockerfiles or committed | They're generated at setup time into `srcs/secrets/` (git-ignored) and injected as Docker **secrets** |
| Use Docker secrets for credentials | Every `*.txt` here becomes a `secrets:` entry in `docker-compose.yml`, surfaced at `/run/secrets/<name>` |
| TLS / HTTPS only | Generates `nginx.crt` + `nginx.key` for `${USER}.42.fr` so NGINX can serve TLSv1.2/1.3 |
| Volumes live under `~/data` | Creates `$HOME/data/mariadb` and `$HOME/data/wordpress`, the bind targets in compose |

---

## 1. What's in `requirements/tools/`

```
requirements/tools/
└── setup.sh      # host bootstrap: certs, secrets, salts, data dirs
```

No Dockerfile — nothing here is built into an image. It runs on the host.

---

## 2. What `setup.sh` does, step by step

The whole body is wrapped in `if [ ! -d "$SECRETS_DIR" ]` — so it is
**idempotent**: it only does work the first time, when `srcs/secrets/` doesn't
yet exist. `set -e` makes it abort on the first error.

1. **Create `srcs/secrets/`** — the directory all generated files land in.
2. **Find or fetch `mkcert`** — uses a system `mkcert` if present, else a local
   `./mkcert`, else downloads the static linux/amd64 binary from
   `dl.filippo.io`, makes it executable, and uses that.
3. **Generate TLS certificate** — `mkcert -install` adds the local CA to the
   trust store, then issues `nginx.key` + `nginx.crt` for `${USER}.42.fr` and
   `127.0.0.1`. NGINX mounts these as the `nginx_crt` / `nginx_key` secrets.
4. **Generate passwords** with `openssl rand -base64`:
   - `db_password.txt`, `db_root_password.txt` (24 bytes)
   - `wp_user_password.txt`, `wp_admin_password.txt`, `ftp_password.txt`,
     `grafana_password.txt` (10 bytes)
5. **Fetch WordPress salts** — `curl` the official
   `api.wordpress.org/secret-key/1.1/salt/` endpoint into `salts.txt`; the
   wordpress container sources these into `wp-config.php`.
6. **Create volume folders** — `$HOME/data/mariadb` and `$HOME/data/wordpress`,
   the host directories that the named volumes bind-mount.
7. **Clean up** — removes the local `./mkcert` binary if it downloaded one.

---

## 3. The files it produces (and who consumes them)

| File in `srcs/secrets/` | Compose secret | Consumed by |
|-------------------------|----------------|-------------|
| `nginx.crt` / `nginx.key` | `nginx_crt` / `nginx_key` | nginx (TLS) |
| `db_password.txt` | `db_password` | mariadb, wordpress, ftp's WP not — see compose |
| `db_root_password.txt` | `db_root_password` | mariadb (root) |
| `salts.txt` | `salts` | wordpress (`wp-config.php`) |
| `wp_user_password.txt` | `wp_user_password` | wordpress |
| `wp_admin_password.txt` | `wp_admin_password` | wordpress |
| `ftp_password.txt` | `ftp_password` | ftp |
| `grafana_password.txt` | `grafana_password` | grafana (admin login) |

Plus host dirs: `$HOME/data/mariadb`, `$HOME/data/wordpress` (volume bind targets).

---

## 4. How it's invoked

From the `Makefile`:

```make
setup:
	chmod +x srcs/requirements/tools/setup.sh
	./srcs/requirements/tools/setup.sh

run: setup
	docker compose -f srcs/docker-compose.yml up -d --build
```

So `make` (= `make run`) always runs `setup` first. You can also run it alone:

```bash
make setup
# or directly
./srcs/requirements/tools/setup.sh
```

---

## 5. Verification

```bash
# a. Secrets were generated
ls -l srcs/secrets/                        # 9 files (certs + 6 passwords + salts)

# b. The certificate is valid and matches your host
openssl x509 -in srcs/secrets/nginx.crt -noout -subject -dates

# c. Salts were actually fetched (not an error page)
head -n1 srcs/secrets/salts.txt            # -> define('AUTH_KEY', ...

# d. Data directories exist for the bind mounts
ls -d "$HOME/data/mariadb" "$HOME/data/wordpress"
```

---

## 6. Defense Q&A (likely evaluator questions)

**Q: Where do the passwords come from? Are any hardcoded?**
None are hardcoded. `setup.sh` generates them at setup time with
`openssl rand` into git-ignored files under `srcs/secrets/`, then Docker injects
them as secrets at `/run/secrets/...`. The Dockerfiles contain no credentials.

**Q: Why a separate host script instead of generating secrets in the images?**
Secrets must not live in image layers or git. Generating them on the host once,
outside the build, keeps them out of the images and lets every container read
the same values through the Docker secrets mechanism.

**Q: Why `mkcert` and not `openssl` for the TLS cert?**
`mkcert` also installs a local CA, so the browser trusts the cert without a
warning during defense. A self-signed `openssl` cert would work for TLS but
throw an untrusted-cert warning.

**Q: Is it safe to run twice?**
Yes — the whole script is guarded by `if [ ! -d srcs/secrets ]`, so a second run
is a no-op. To regenerate, `make fclean` (which removes `srcs/secrets`) first.

**Q: What domain is the cert for?**
`${USER}.42.fr` (and `127.0.0.1`) — matching `USER_HOST` in `.env`, which NGINX
uses as `server_name`.

---

## 7. Troubleshooting

- **Nothing regenerates after editing the script** — `srcs/secrets/` already
  exists, so the guard skips everything. Remove it (`make fclean`) and re-run.
- **`mkcert: command not found` / download fails** — needs network access to
  `dl.filippo.io`; or install `mkcert` via your package manager first.
- **Browser shows untrusted cert** — `mkcert -install` didn't add the CA (e.g.
  ran as a different user / no NSS tools). Re-run `mkcert -install`.
- **`salts.txt` looks like HTML** — the WordPress API call failed (offline);
  re-run with network access.
- **Containers can't read a secret** — confirm the matching `*.txt` exists in
  `srcs/secrets/` and is listed under both `secrets:` (top level) and the
  service in `docker-compose.yml`.

---

## 8. One-line summary

`tools/setup.sh` is the host bootstrap (run by `make setup` before compose):
generate the mkcert TLS pair + all passwords + WordPress salts into the
git-ignored `srcs/secrets/`, and create the `~/data` bind-mount dirs — so the
containers only ever **read** secrets, never create or embed them.

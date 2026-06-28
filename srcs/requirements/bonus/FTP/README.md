# FTP container — build guide (Inception bonus)

This container runs **vsftpd** to give FTP access to the WordPress files. It
mounts the same `wordpress_data` volume as WordPress and NGINX, so files you
upload over FTP land directly in the live site's webroot. It is the **one bonus
service that legitimately publishes host ports** — an FTP client connects to the
daemon directly, so (unlike the HTTP apps) it can't be reverse-proxied behind
NGINX.

> FTP user `nginx` (uid/gid 2000, matching WordPress). Control port `2121`,
> passive data ports `30000-30010`. Webroot `/var/www/html/`.

---

## 0. Rules this container must respect (don't break these)

| Rule | How we satisfy it |
|------|-------------------|
| Base image = penultimate stable Alpine | `FROM alpine:3.23` |
| No `latest` tag, image name = service name | `image: ftp:Inception` |
| No ready-made app images | `FROM alpine:3.23` + `apk add vsftpd` |
| Daemon in foreground as PID 1, no hacks | `exec /usr/sbin/vsftpd ...` — no `tail -f`, no `&` |
| Host `ports:` only where justified | FTP **is** the justified case: control + passive ports must be reachable from the host |
| No password in Dockerfile / `.env` | FTP user's password is a Docker **secret** read at runtime |
| Shared data / consistent ownership | Mounts `wordpress_data`; FTP user uid/gid `2000` matches the WordPress container's user |
| Networks declared in compose | Joins `inception_network` |

---

## 1. What's in `requirements/bonus/FTP/`

```
requirements/bonus/FTP/
├── Dockerfile
└── tools/
    └── script.sh     # create user from secret, register shell, write vsftpd.conf, then exec vsftpd
```

---

## 2. The Dockerfile

```dockerfile
FROM alpine:3.23

RUN apk update && apk add --no-cache vsftpd

COPY ./tools/script.sh /script.sh
RUN chmod +x /script.sh
RUN rm -f /etc/vsftpd/vsftpd.conf      # drop default so the script writes its own

CMD ["/script.sh"]
```

Same pattern as nginx/mariadb: install the daemon, delete its default config,
and let the entrypoint generate the real config from `.env` + secrets on first
boot.

---

## 3. The entrypoint — `tools/script.sh`

FTP **earns** its script (like nginx/mariadb, unlike Adminer): it creates the
login user from a secret, registers a valid shell, and templates `vsftpd.conf`
from env, then execs the daemon.

```sh
#!/bin/sh

if [ ! -f /etc/vsftpd/vsftpd.conf ]; then
    FTP_USER=$LINUX_USER_NAME                 # nginx
    FTP_PASS=$(cat /run/secrets/ftp_password) # secret

    # Create the SAME user/uid as the WordPress container (2000) so file
    # ownership lines up across the shared volume. Home = the WP webroot.
    addgroup -g 2000 $LINUX_GROUP_NAME 2>/dev/null || true
    adduser -h /var/www/html/ -G $LINUX_GROUP_NAME -s /bin/sh -D -u 2000 $LINUX_USER_NAME 2>/dev/null || true

    # vsftpd refuses a login if the user's shell isn't listed in /etc/shells.
    grep -qx /bin/sh /etc/shells 2>/dev/null || echo /bin/sh >> /etc/shells

    echo "$FTP_USER:$FTP_PASS" | chpasswd     # set the password from the secret

    echo "listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
chroot_local_user=YES
allow_writeable_chroot=YES
seccomp_sandbox=NO
listen_port=$FTP_PORT
pasv_enable=YES
pasv_min_port=$pasv_min_port
pasv_max_port=$pasv_max_port
local_root=/var/www/html/
" > /etc/vsftpd/vsftpd.conf
fi

exec /usr/sbin/vsftpd /etc/vsftpd/vsftpd.conf      # foreground => PID 1
```

The non-obvious settings, explained:
- **uid/gid `2000` + `-h /var/www/html/`** — the FTP user is the *same* `nginx`
  user (numerically) that WordPress uses, so a file uploaded over FTP is owned
  consistently and WordPress/NGINX can read it (and vice-versa). Mismatched uids
  were the bug that stopped FTP from writing WP files.
- **`/bin/sh` into `/etc/shells`** — vsftpd validates a local user's login shell
  against `/etc/shells`; without this the login is rejected.
- **`chpasswd`** — sets the local user's password from the secret (no plaintext
  anywhere in the image).
- **`chroot_local_user=YES` + `allow_writeable_chroot=YES`** — jail the user
  inside `/var/www/html` so they can't roam the filesystem, while still allowing
  writes. (vsftpd normally refuses a *writable* chroot root for security; the
  `allow_writeable_chroot` flag explicitly permits it.)
- **`seccomp_sandbox=NO`** — vsftpd's seccomp filter frequently breaks logins/
  transfers inside containers; disabling it avoids those failures.
- **`pasv_*` + `listen_port`** — passive mode (see §5 on why) on `30000-30010`,
  control channel on `2121`.
- **`exec /usr/sbin/vsftpd ...`** — foreground daemon, PID 1 (with `init: true`).

---

## 4. The Compose service block

```yaml
  ftp:
    build: ./requirements/bonus/FTP
    image: ftp:Inception
    container_name: ftp
    restart: on-failure
    init: true
    networks:
      - inception_network
    env_file:
      - .env
    ports:
      - "${FTP_PORT}:${FTP_PORT}"                              # 2121 control
      - "${pasv_min_port}-${pasv_max_port}:${pasv_min_port}-${pasv_max_port}"  # 30000-30010 data
    volumes:
      - wordpress_data:/var/www/                              # the WordPress webroot
    secrets:
      - ftp_password
```

Decisions, and why:
- **`ports:` (the justified exception)** — FTP clients connect to the daemon
  directly; there's no HTTP layer for NGINX to proxy. The control port `2121`
  *and* the passive data range `30000-30010` must both be published or transfers
  hang (see §5). This is the only bonus allowed host ports.
- **`volumes: wordpress_data:/var/www/`** — so FTP reads/writes the same files
  WordPress serves. `local_root=/var/www/html/` drops the user into the webroot.
- **`secrets: ftp_password`** — the password, mounted read-only at
  `/run/secrets/ftp_password`.
- `init: true`, `restart: on-failure`, `inception_network`, `env_file` — standard.

---

## 5. Why passive mode + a published port range

FTP uses **two** channels: a control connection (commands) and a separate data
connection (file contents / directory listings).

- **Active mode** has the *server* open the data connection back to the client —
  which doesn't survive Docker's NAT/port mapping.
- **Passive mode** has the *server* listen on a data port and the *client*
  connect to it. We pin that to a small range (`pasv_min_port`–`pasv_max_port`
  = `30000-30010`) and publish exactly that range to the host, so the client can
  reach the data ports. Without publishing them, login works but `LIST`/uploads
  hang.

`listen_port=2121` is the control channel (we avoid privileged port 21).

---

## 6. Secrets

`srcs/requirements/tools/setup.sh` on the host:

```sh
openssl rand -base64 10 > srcs/secrets/ftp_password.txt
```

Surfaces as `/run/secrets/ftp_password`, read by `script.sh` and applied with
`chpasswd`. Nothing in the image or `.env`.

---

## 7. Build and run

```bash
docker compose -f srcs/docker-compose.yml up -d --build ftp
# or full stack:
make

docker compose -f srcs/docker-compose.yml ps ftp     # Up, 2121 + 30000-30010 published
docker compose -f srcs/docker-compose.yml logs ftp
```

---

## 8. Verification

```bash
PASS=$(cat srcs/secrets/ftp_password.txt)
echo "ftp test $(date)" > /tmp/ftptest.txt

# a. Upload a file over FTP (passive mode)
curl --ftp-pasv -T /tmp/ftptest.txt "ftp://nginx:$PASS@127.0.0.1:2121/"

# b. It appears where WordPress sees it (shared volume, consistent ownership)
docker exec wordpress ls -l /var/www/html/ftptest.txt
docker exec ftp cat  /var/www/html/ftptest.txt

# c. Directory listing works (proves the passive data channel)
curl --ftp-pasv "ftp://nginx:$PASS@127.0.0.1:2121/" | head

# d. Clean up the test file from the volume
docker exec ftp rm -f /var/www/html/ftptest.txt
```

Expected: (a) upload succeeds (no hang); (b) the file is present and readable
from the WordPress container; (c) a listing of the WP webroot; (d) removed.

> Security note for defense: plain FTP sends credentials and data in clear text.
> That's acceptable for this bonus on a private setup, but it's why FTP isn't a
> good choice for the open internet (FTPS/SFTP would encrypt it).

---

## 9. Usage with `lftp`

`curl` proves the channel works; `lftp` is what you'd actually use day to day —
an interactive (or scriptable) FTP client that handles passive mode, multi-file
transfers, and a real shell-like session.

```bash
PASS=$(cat srcs/secrets/ftp_password.txt)

# Interactive session
lftp -u nginx,"$PASS" 127.0.0.1:2121
```

Inside the `lftp>` prompt:

```
lftp nginx@127.0.0.1:2121> ls                  # list the WP webroot
lftp nginx@127.0.0.1:2121> put wp-content/index.php   # upload a local file
lftp nginx@127.0.0.1:2121> get wp-config.php           # download a remote file
lftp nginx@127.0.0.1:2121> mkdir uploads               # create a directory
lftp nginx@127.0.0.1:2121> mirror -R ./uploads uploads # upload a directory tree
lftp nginx@127.0.0.1:2121> rm index.php                # delete a remote file
lftp nginx@127.0.0.1:2121> bye
```

Non-interactively (scripted, single command):

```bash
echo "ftp test $(date)" > /tmp/ftptest.txt

# Upload
lftp -u nginx,"$PASS" 127.0.0.1:2121 -e "set ftp:passive-mode true; \
  put /tmp/ftptest.txt -o ftptest.txt; bye"

# Confirm it landed in the shared volume, owned correctly
docker exec wordpress ls -l /var/www/html/ftptest.txt

# List the webroot
lftp -u nginx,"$PASS" 127.0.0.1:2121 -e "ls; bye"

# Download it back
lftp -u nginx,"$PASS" 127.0.0.1:2121 -e "get ftptest.txt -o /tmp/ftptest.dl; bye"
diff /tmp/ftptest.txt /tmp/ftptest.dl && echo "round-trip OK"

# Clean up
lftp -u nginx,"$PASS" 127.0.0.1:2121 -e "rm ftptest.txt; bye"
rm -f /tmp/ftptest.txt /tmp/ftptest.dl
```

`lftp` defaults to passive mode already, so this exercises the exact same
`pasv_min_port`–`pasv_max_port` path as §5 — if uploads here hang, it's the
same port-publishing issue, not an `lftp` quirk.

---

## 10. Defense Q&A (likely evaluator questions)

**Q: What does the FTP container give access to?**
The WordPress site files. It mounts the shared `wordpress_data` volume and the
user's root is `/var/www/html/`, so you can upload/download the live webroot.

**Q: Why is FTP the only bonus with published host ports?**
An FTP client connects straight to the daemon — it's not HTTP, so NGINX can't
reverse-proxy it like `/resume/` or `/grafana/`. The control port and the
passive data range have to be reachable from the host.

**Q: Why a port *range* (30000-30010)?**
Passive-mode data connections each use a port from that range; publishing the
range lets the client open the data channel through Docker's NAT. Active mode
wouldn't work behind port mapping.

**Q: Who is the FTP user and why uid 2000?**
The `nginx` user, created with the same uid/gid (2000) as in the WordPress
container, so files written over FTP are owned identically and remain
read/writable by WordPress and NGINX across the shared volume.

**Q: Where's the password?**
A Docker secret (`ftp_password`) generated by `setup.sh`, read at runtime and
set with `chpasswd`. Not in the image or `.env`.

**Q: What do `chroot_local_user` / `allow_writeable_chroot` do?**
Jail the user in `/var/www/html` (can't escape to the rest of the filesystem)
while still allowing writes — vsftpd normally refuses a writable chroot root, so
we explicitly allow it.

**Q: What is PID 1?**
`/usr/sbin/vsftpd` via `exec` (foreground, with `init: true`). No keep-alive
hack.

**Q: Why does this service need a script when Adminer didn't?**
Real setup: create the user from a secret, register its shell, generate
`vsftpd.conf` from env. That can't be a bare `CMD`.

---

## 11. Troubleshooting

- **`530 Login incorrect`** — shell not in `/etc/shells`, the user wasn't
  created, or the password doesn't match `ftp_password.txt`.
- **Login works but `LIST`/upload hangs** — passive ports not published or out
  of range; confirm `30000-30010` are mapped and match `pasv_min/max_port`.
- **`500 OOPS: vsftpd: refusing to run with writable root inside chroot`** —
  `allow_writeable_chroot=YES` missing.
- **seccomp / `priv_sock` errors on login** — set `seccomp_sandbox=NO`.
- **Uploaded file exists but WordPress can't edit it (or vice-versa)** — uid/gid
  mismatch; both the FTP and WordPress containers must create `nginx` with
  `-u 2000 -g 2000`.

---

## 12. One-line summary of the parts

1. `bonus/FTP/Dockerfile` — Alpine + `vsftpd`, drop default conf, copy
   `script.sh`, `CMD ["/script.sh"]`.
2. `bonus/FTP/tools/script.sh` — create `nginx` user (uid 2000) from the
   `ftp_password` secret, register `/bin/sh`, write `vsftpd.conf` (chroot +
   passive `30000-30010`, control `2121`, root `/var/www/html`), then
   `exec vsftpd`.
3. `docker-compose.yml` — `ftp` service: publishes `2121` + `30000-30010`
   (justified), mounts `wordpress_data`, uses the `ftp_password` secret.

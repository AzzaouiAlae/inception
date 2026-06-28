*This project has been created as part of the 42 curriculum by aazzaoui.*

# Inception

## Description

**Inception** is a system-administration project: build a small, self-contained
web infrastructure entirely from your own Docker images, orchestrated with Docker
Compose, running on a virtual machine.

The goal is to learn containerization properly — writing Dockerfiles from
scratch (no pre-built application images), wiring services together on a private
network, persisting data in volumes, terminating TLS, and handling secrets
correctly.

The mandatory stack is three services:

- **NGINX** — the single entry point, TLS 1.2/1.3 only, on port **443**.
- **WordPress + php-fpm** — the application (no NGINX inside it).
- **MariaDB** — the database (no NGINX inside it).

backed by two named volumes (database + website files) and one Docker network.

This repository also implements the **bonus** services: Redis (WordPress object
cache), an FTP server onto the WordPress volume, a non-PHP static **resume**
site, **Adminer**, and a monitoring stack of **cAdvisor → Prometheus →
Grafana**.

## Instructions

### Prerequisites
- A Linux host / VM with **Docker** and the **Docker Compose** plugin.
- `make`, `openssl`, `curl` (the setup script can download `mkcert` itself).
- Add the domain to your hosts file so it resolves locally:
  ```bash
  echo "127.0.0.1 aazzaoui.42.fr" | sudo tee -a /etc/hosts
  ```

### Build & run
```bash
make            # generate secrets/certs, then build & start everything (detached)
```
`make` runs `tools/setup.sh` first (TLS cert, all passwords, WordPress salts,
the `~/data` volume directories), then `docker compose up -d --build`.

Then open: **https://aazzaoui.42.fr** (accept the locally-trusted certificate).

### Other targets
```bash
make stop       # stop containers (keep them)
make start      # start stopped containers
make clean      # down + remove images
make fclean     # down + remove images, volumes, secrets and ~/data
make re         # clean + run
```

For day-to-day usage see **[USER_DOC.md](USER_DOC.md)**; for development and
internals see **[DEV_DOC.md](DEV_DOC.md)**. Each service folder under
`srcs/requirements/` also has its own `README.md`.

## Project description

### Use of Docker and the project's sources

Every service runs in its **own** container, built from a Dockerfile we wrote
ourselves on top of **`alpine:3.23`** (the penultimate stable Alpine) — except
cAdvisor, which needs glibc and so uses `debian:bookworm-slim`. No ready-made
application image is pulled; the apps (WordPress, MariaDB, Redis, vsftpd,
Prometheus, Grafana…) are installed via the package manager or pinned binaries
at build time. Image tags are fixed to `:Inception` (the `latest` tag is banned).

Sources are laid out as:

```
.
├── Makefile                     # entry point: setup + docker compose
├── README.md / USER_DOC.md / DEV_DOC.md
└── srcs/
    ├── docker-compose.yml       # services, network, volumes, secrets
    ├── .env                     # non-secret config (ports, names, domain)
    ├── secrets/                 # generated credentials + TLS (git-ignored)
    └── requirements/
        ├── nginx/  wordpress/  mariadb/   # mandatory
        ├── tools/                         # host setup.sh
        └── bonus/  redis/ FTP/ resume/ Adminer/ cadvisor/ prometheus/ grafana/
```

Main design choices:
- **One concern per container**, each a foreground process running as **PID 1**
  via `exec` in its entrypoint — no `tail -f`, `sleep infinity`, or other
  keep-alive hacks; containers `restart: on-failure`, with `init: true` (tini)
  for proper signal handling/zombie reaping.
- **NGINX is the only exposed entry point** (port 443, TLS 1.2/1.3); every other
  mandatory service is reachable only on the private `inception_network`.
- **Secrets are generated on the host** by `tools/setup.sh` into the git-ignored
  `srcs/secrets/` and injected as **Docker secrets** at `/run/secrets/...` —
  never baked into images, never committed.
- **WordPress has two users**: an admin `wp_owner` (deliberately no
  `admin`/`administrator` in the name) and an `editor`.

### Virtual Machines vs Docker
A **VM** virtualizes hardware: each guest ships a full OS kernel on top of a
hypervisor — strong isolation, but heavy (GBs, slow boot, more RAM/CPU).
**Docker containers** share the host kernel and isolate only at the process
level (namespaces + cgroups) — lightweight (MBs, near-instant start), so we can
run nine services side by side cheaply. The trade-off is weaker isolation and
kernel-coupling. Inception itself runs *inside* a VM (the assignment's isolation
boundary) and uses Docker *within* it for the services.

### Secrets vs Environment Variables
**Environment variables** (`.env`) are fine for **non-sensitive** config: ports,
domain name, database/user names. They're convenient but visible via
`docker inspect`, `/proc`, and leak easily into logs and image layers — so they
must **never** hold passwords. **Docker secrets** mount confidential values as
read-only files at `/run/secrets/<name>`, kept out of the environment, the image,
and (via `.gitignore`) the repository. In this project: `.env` for config,
secrets for every password, the TLS key/cert, and the WordPress salts.

### Docker Network vs Host Network
With `network_mode: host` a container shares the host's network stack directly —
no isolation, port conflicts, and it's **forbidden** by the subject (as are
`--link`/`links:`). Instead we declare a **user-defined bridge network**
(`inception_network`). It isolates the stack, gives containers automatic
**DNS by service name** (WordPress reaches the DB at `mariadb:3306`,
Prometheus scrapes `cadvisor:8080`), and lets us expose only port 443 to the
outside while everything else stays internal.

### Docker Volumes vs Bind Mounts
A raw **bind mount** (`- /host/path:/container/path` in a service) maps a host
directory straight in — unmanaged by Docker and disallowed here for the
persistent storages. A **named volume** is managed by Docker, referenced by name,
and survives container recreation. We use **named volumes** (`mariadb_data`,
`wordpress_data`) declared in the top-level `volumes:` block. To satisfy the rule
that their data lives in `/home/login/data`, they use the `local` driver's
`driver_opts` (`o: bind`, `device: ${HOME}/data/...`) — that option is the only
mechanism Docker provides to pin a *named* volume's backing store to a chosen
host path, so it remains a named volume, not a service-level bind mount.

## Resources

Documentation and references used:
- Docker docs — [Dockerfile reference](https://docs.docker.com/reference/dockerfile/),
  [Compose file reference](https://docs.docker.com/reference/compose-file/),
  [secrets](https://docs.docker.com/engine/swarm/secrets/),
  [volumes](https://docs.docker.com/storage/volumes/),
  [networking](https://docs.docker.com/network/).
- **Udemy — "Docker & Kubernetes: The Practical Guide" by Maximilian
  Schwarzmüller**: the main course I used to learn Docker — images vs containers,
  Dockerfile layering, volumes vs bind mounts, and Docker networking. The mental
  model for this project's volume and network choices comes from there.
- [PID 1 / init in containers](https://github.com/krallin/tini) — why `exec` and
  `init: true` matter for signals and zombie reaping.
- Official project docs: WordPress + WP-CLI, MariaDB, NGINX, Redis, vsftpd,
  Prometheus, Grafana provisioning, Google cAdvisor.

### How AI was used
AI (Claude) was used as a **research and review assistant**, not to generate the
infrastructure blind:
- **Documentation** — drafting and structuring this README, `USER_DOC.md`,
  `DEV_DOC.md`, and the per-service `README.md` files, which I then reviewed and
  corrected against my actual configs.
- **Explaining concepts** — clarifying PID 1 / `exec`, the named-volume vs
  bind-mount wording, Docker secrets, and the NGINX sub-path proxying for Grafana.
- **Debugging help** — reasoning about service start order, MariaDB readiness
  waits, and Prometheus → Grafana wiring.

Every config file, Dockerfile, and entrypoint script was written and tested by
me; AI output was checked, adapted, and only kept where I fully understand it and
can defend it.

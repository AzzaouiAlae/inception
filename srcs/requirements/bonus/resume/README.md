# Resume container — build guide (Inception bonus)

A small **ASP.NET Core (Razor Pages, .NET 10)** web app that serves a static CV
page. It's reached at `https://aazzaoui.42.fr/resume/` — NGINX reverse-proxies
the `/resume/` path to it. No host port, no DB, no secrets: it's a self-
contained informational site on `inception_network` as the host `resume`,
listening on port `5000`.

> URL: `https://aazzaoui.42.fr/resume/`. Internal: `http://resume:5000/`.

---

## 0. Rules this container must respect (don't break these)

| Rule | How we satisfy it |
|------|-------------------|
| Base image = penultimate stable Alpine | `FROM alpine:3.23` |
| No `latest` tag, image name = service name | `image: resume:Inception` |
| No ready-made app images | Both stages use `FROM alpine:3.23`; we install `dotnet10-sdk` to build and `aspnetcore10-runtime` to run |
| Daemon in the foreground | `dotnet cv.dll` runs Kestrel directly as PID 1 in the foreground |
| No host `ports:` | Internal `5000` only; NGINX proxies `/resume/` to it |
| Networks declared in compose | Joins `inception_network` |

---

## 1. What's in `requirements/bonus/resume/`

```
requirements/bonus/resume/
├── Dockerfile
└── App/
    ├── cv.csproj                 # net10.0, Razor Pages web SDK
    ├── Program.cs                # minimal host: AddRazorPages / MapRazorPages
    ├── Pages/index.cshtml        # the CV markup (sets <base href="/resume/">)
    ├── wwwroot/css/style.css     # styling
    ├── appsettings*.json
    └── Properties/launchSettings.json   # development profile (not used at runtime; see §4)
```

---

## 2. The app

`Program.cs` is the minimal ASP.NET Core host:

```csharp
var builder = WebApplication.CreateBuilder(args);
builder.Services.AddRazorPages();
var app = builder.Build();
app.MapStaticAssets();   // serve wwwroot (css, etc.)
app.MapRazorPages();     // serve Pages/*.cshtml
app.Run();
```

The CV itself is `Pages/index.cshtml`. The key line for the reverse proxy is in
its `<head>`:

```html
<base href="/resume/" />
<link rel="stylesheet" href="css/style.css" />
```

`<base href="/resume/">` makes every **relative** URL on the page resolve under
`/resume/`. So `href="css/style.css"` becomes
`https://aazzaoui.42.fr/resume/css/style.css` in the browser — which NGINX
routes back to this container. This is what makes the app work correctly under
a subpath instead of breaking its CSS (see §6).

---

## 3. The Dockerfile

```dockerfile
# Stage 1: Build
FROM alpine:3.23 AS build

RUN apk update && apk add --no-cache dotnet10-sdk

WORKDIR /src
COPY ./App /src

RUN dotnet restore
RUN dotnet publish -c Release -o /app/publish

# Stage 2: Runtime
FROM alpine:3.23

RUN apk update && apk add --no-cache aspnetcore10-runtime

WORKDIR /app
COPY --from=build /app/publish .

ENV ASPNETCORE_URLS=http://+:5000
EXPOSE 5000

CMD ["dotnet", "cv.dll"]
```

What it does:

- **Multi-stage build** — the first stage installs the full `dotnet10-sdk`,
  restores NuGet packages, and publishes a Release build to `/app/publish`.
  The second stage starts fresh from `alpine:3.23` and only installs the
  smaller `aspnetcore10-runtime` package, then copies the published artifacts.
  The SDK and build cache are left behind, so the final image is much smaller
  and contains only what is needed to run the app.
- **`CMD ["dotnet", "cv.dll"]`** uses exec form, so `dotnet` is the container's
  main process and the Kestrel app runs directly in the foreground.
  No launcher, no backgrounding, no keep-alive hack.

---

## 4. How it binds to port 5000

`ASPNETCORE_URLS=http://+:5000` is set in the Dockerfile, so Kestrel binds
`http://0.0.0.0:5000` (`0.0.0.0` so NGINX in another container can reach it,
not just loopback).

`launchSettings.json` is no longer consulted at runtime because we start the
published DLL directly with `dotnet cv.dll` rather than `dotnet run`.

---

## 5. The Compose service block

```yaml
  resume:
    build: ./requirements/bonus/resume
    image: resume:Inception
    container_name: resume
    restart: on-failure
    init: true
    networks:
      - inception_network
```

Decisions, and why:
- **No `ports:`** — reached only through NGINX at `/resume/`.
- **No `env_file` / `secrets` / `volumes`** — it's a static informational page;
  no configuration, no credentials, nothing to persist.
- `init: true`, `restart: on-failure`, `inception_network` — standard.

---

## 6. The NGINX route (in `nginx/conf/nginx.sh`)

```nginx
location /resume/ {
    # The trailing slash strips the /resume/ prefix before proxying.
    proxy_pass http://resume:5000/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

How a request flows:
1. Browser asks for `https://aazzaoui.42.fr/resume/`.
2. NGINX matches `location /resume/`, and the **trailing slash** on
   `proxy_pass http://resume:5000/` strips the prefix → the app sees `/`.
3. The page renders with `<base href="/resume/">`, so its `css/style.css`
   becomes `/resume/css/style.css` in the browser.
4. That request hits `location /resume/` again → app sees `/css/style.css` →
   Kestrel serves `wwwroot/css/style.css`. Styling works under the subpath.

(`$host`, `$remote_addr`, etc. stay literal inside the single-quoted heredoc;
the upstream port is hardcoded here, not an env var — see the nginx README for
the quoting rules.)

---

## 7. Build and run

```bash
docker compose -f srcs/docker-compose.yml up -d --build resume
# or full stack:
make

docker compose -f srcs/docker-compose.yml ps resume    # Up, no host port
docker compose -f srcs/docker-compose.yml logs resume   # expect "Now listening on:" with port 5000
```

---

## 8. Verification

```bash
# a. Served through NGINX over TLS
curl -k --resolve aazzaoui.42.fr:443:127.0.0.1 https://aazzaoui.42.fr/resume/ | grep -i '<title>'

# b. The stylesheet resolves under the subpath (proves <base href> + routing)
curl -k --resolve aazzaoui.42.fr:443:127.0.0.1 https://aazzaoui.42.fr/resume/css/style.css -I | head -n1

# c. App answers locally inside the container
docker exec resume sh -c 'wget -qO- http://localhost:5000/ | grep -i "<title>"'

# d. NOT reachable directly from the host
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:5000 || echo "refused (correct)"
```

Expected: (a) the `Resume` title; (b) `HTTP/.. 200` for the CSS; (c) the title
again from inside; (d) connection refused on the host.

---

## 9. Defense Q&A (likely evaluator questions)

**Q: What is this service?**
A small ASP.NET Core Razor Pages site that serves my CV at
`https://aazzaoui.42.fr/resume/`. It demonstrates serving a second app behind
the single NGINX entry point.

**Q: How is it reached without a host port?**
NGINX reverse-proxies `location /resume/` to `http://resume:5000/` on the
internal network — same idea as `/grafana/` and `/adminer/`.

**Q: How don't the CSS/assets break under the `/resume/` subpath?**
The page sets `<base href="/resume/">` and uses relative asset URLs, so the
browser requests them under `/resume/...`, which NGINX routes back to this
container. The proxy's trailing slash then strips the prefix for the app.

**Q: How does it listen on 5000?**
The Dockerfile sets `ASPNETCORE_URLS=http://+:5000`, so Kestrel binds
`0.0.0.0:5000` directly.

**Q: Is the app PID 1? How big is the image?**
Yes. The Dockerfile uses `dotnet publish` in a build stage, then runs the
produced `cv.dll` with `CMD ["dotnet", "cv.dll"]` in exec form. Kestrel itself
is the container's PID 1 and runs in the foreground. The final image only
contains the `aspnetcore10-runtime`, not the full SDK, so it is much smaller
than the single-stage SDK-based version.

**Q: Why no secrets/volume/env_file?**
It's a static page — no database, no credentials, nothing to persist.

---

## 10. Troubleshooting

- **502 Bad Gateway at `/resume/`** — app not up or not listening on 5000. The
  app is already built into the image, so startup should be quick; check the logs
  for "Now listening on:" with port 5000. Confirm the proxy port matches.
- **Page loads but unstyled** — `<base href="/resume/">` missing/changed, or the
  `proxy_pass` lost its trailing slash; then `css/style.css` resolves to `/` and
  hits WordPress instead.
- **Wrong/blank port** — check that `ASPNETCORE_URLS=http://+:5000` is still set
  in the Dockerfile and that the container is started with `dotnet cv.dll`, not
  `dotnet run`.
- **Very large image** — make sure the runtime stage only installs
  `aspnetcore10-runtime`, not `dotnet10-sdk`.

---

## 11. One-line summary of the parts

1. `bonus/resume/Dockerfile` — multi-stage build: `alpine:3.23` +
   `dotnet10-sdk` to restore/publish, then `alpine:3.23` +
   `aspnetcore10-runtime` to run `dotnet cv.dll` as PID 1.
2. `App/` — Razor Pages CV; `index.cshtml` uses `<base href="/resume/">` so it
   works behind the subpath; binds 5000 via `ASPNETCORE_URLS`.
3. `docker-compose.yml` — `resume` service: no host port, no secrets/volume, on
   `inception_network`.
4. `nginx/conf/nginx.sh` — `location /resume/` proxies (trailing slash) to
   `http://resume:5000/`.
